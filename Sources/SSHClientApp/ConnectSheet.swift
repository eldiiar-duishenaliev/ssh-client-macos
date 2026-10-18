import SwiftUI
import Combine
import SSHCore

/// Form state for the connect sheet.
///
/// Held in a view model rather than `@State` closures so the sheet stays
/// testable and the fields can be validated together.
@MainActor
final class ConnectFormModel: ObservableObject {
    enum AuthKind: String, CaseIterable, Identifiable {
        case password = "Password"
        case privateKey = "Private key"
        case agent = "SSH agent"

        var id: String { rawValue }
    }

    @Published var name = ""
    @Published var host = ""
    @Published var port = "22"
    @Published var username = NSUserName()
    @Published var authKind: AuthKind = .password
    @Published var password = ""
    @Published var privateKeyPath = "~/.ssh/id_ed25519"
    @Published var passphrase = ""

    var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Builds a request, or `nil` when the form is incomplete.
    func makeRequest() -> ConnectionRequest? {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else { return nil }

        let auth: SSHAuthMethod
        switch authKind {
        case .password:
            auth = SSHAuthMethod(kind: .password(password))
        case .privateKey:
            let expanded = NSString(string: privateKeyPath).expandingTildeInPath
            auth = SSHAuthMethod(kind: .privateKey(
                privateKeyPath: expanded,
                publicKeyPath: nil,
                passphrase: passphrase.isEmpty ? nil : passphrase
            ))
        case .agent:
            auth = SSHAuthMethod(kind: .agent)
        }

        return ConnectionRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            host: trimmedHost,
            port: UInt16(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces),
            auth: auth
        )
    }
}

/// Collects connection details and produces a `ConnectionRequest`.
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ConnectFormModel()
    let onConnect: (ConnectionRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New SSH Connection")
                .font(.headline)

            Form {
                TextField("Name (optional)", text: $form.name)
                TextField("Host", text: $form.host)
                TextField("Port", text: $form.port)
                TextField("Username", text: $form.username)

                Picker("Authentication", selection: $form.authKind) {
                    ForEach(ConnectFormModel.AuthKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }

                switch form.authKind {
                case .password:
                    SecureField("Password", text: $form.password)
                case .privateKey:
                    TextField("Private key", text: $form.privateKeyPath)
                    SecureField("Passphrase (optional)", text: $form.passphrase)
                case .agent:
                    Text("Identities are read from ssh-agent via SSH_AUTH_SOCK.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canConnect)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        guard let request = form.makeRequest() else { return }
        onConnect(request)
        dismiss()
    }
}
