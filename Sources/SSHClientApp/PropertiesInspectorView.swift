import SwiftUI
import AppKit
import ConnectionStore

/// Editable copy of a node's properties, so edits can be reviewed before they
/// are written back to the library.
///
/// Passphrases are deliberately absent: they are secrets, stored in the
/// Keychain and managed with the Set/Clear controls rather than text fields.
@MainActor
final class NodeEditor: ObservableObject {
    @Published var name = ""
    @Published var host = ""
    @Published var port = ""
    @Published var username = ""
    @Published var privateKeyPath = ""
    @Published var protocolKind: ProtocolKind = .ssh
    @Published var notes = ""
    @Published var isFolder = false

    // Jump host ("ProxyJump"). Empty values clear the override so the value is
    // inherited from a parent folder again.
    @Published var jumpHost = ""
    @Published var jumpPort = ""
    @Published var jumpUsername = ""
    @Published var jumpPrivateKeyPath = ""

    private(set) var nodeID: UUID?

    func load(_ node: ConnectionNode?) {
        guard let node else {
            nodeID = nil
            return
        }
        nodeID = node.id
        name = node.name
        host = node.host ?? ""
        port = node.port.map(String.init) ?? ""
        username = node.username ?? ""
        privateKeyPath = node.privateKeyPath ?? ""
        protocolKind = node.protocolKind ?? .ssh
        notes = node.notes ?? ""
        isFolder = node.isFolder
        jumpHost = node.jumpHost ?? ""
        jumpPort = node.jumpPort.map(String.init) ?? ""
        jumpUsername = node.jumpUsername ?? ""
        jumpPrivateKeyPath = node.jumpPrivateKeyPath ?? ""
    }

    /// Writes the edited values back. Empty text clears an override so the
    /// value is inherited from the parent folder again.
    func apply(to library: ConnectionLibrary) {
        guard let nodeID else { return }
        library.update(id: nodeID) { node in
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            if !trimmedName.isEmpty { node.name = trimmedName }

            node.host = Self.cleared(host)
            node.port = UInt16(port)
            node.username = Self.cleared(username)
            node.privateKeyPath = Self.cleared(privateKeyPath)
            node.protocolKind = protocolKind
            node.notes = Self.cleared(notes)

            node.jumpHost = Self.cleared(jumpHost)
            node.jumpPort = UInt16(jumpPort)
            node.jumpUsername = Self.cleared(jumpUsername)
            node.jumpPrivateKeyPath = Self.cleared(jumpPrivateKeyPath)
        }
    }

    private static func cleared(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Right-hand inspector for the selected node.
struct PropertiesInspectorView: View {
    @ObservedObject var library: ConnectionLibrary
    @StateObject private var editor = NodeEditor()

    var body: some View {
        Group {
            if let node = selectedNode {
                form(for: node)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 300)
        .onAppear { editor.load(selectedNode) }
        .onChange(of: library.selectedID) { _, _ in editor.load(selectedNode) }
    }

    private var selectedNode: ConnectionNode? {
        guard let id = library.selectedID else { return nil }
        return library.tree.node(id: id)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No selection")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func form(for node: ConnectionNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(editor.isFolder ? "Folder" : "Connection") {
                    TextField("Name", text: $editor.name)

                    if !editor.isFolder {
                        TextField("Host", text: $editor.host)
                        TextField("Port", text: $editor.port)
                        TextField("Username", text: $editor.username)

                        Picker("Protocol", selection: $editor.protocolKind) {
                            ForEach(ProtocolKind.allCases, id: \.self) { kind in
                                Text(kind.rawValue.uppercased()).tag(kind)
                            }
                        }

                        TextField("Private key", text: $editor.privateKeyPath)
                        keyPassphraseRow(for: node, jump: false)
                    }
                }

                Section("Jump host (ProxyJump)") {
                    TextField("Jump host", text: $editor.jumpHost)
                    TextField("Jump port", text: $editor.jumpPort)
                    TextField("Jump user", text: $editor.jumpUsername)
                    TextField("Jump key", text: $editor.jumpPrivateKeyPath)
                    keyPassphraseRow(for: node, jump: true)

                    Text(jumpHint(for: node))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notes") {
                    TextField("Notes", text: $editor.notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                if !editor.isFolder {
                    Section("Effective") {
                        Text(effectiveDescription(for: node))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Revert") { editor.load(selectedNode) }
                Spacer()
                Button("Apply") { editor.apply(to: library) }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(12)
        }
    }

    // MARK: - Passphrase controls

    /// The key passphrase is a secret, so it is set and cleared rather than
    /// typed into the tree.
    @ViewBuilder
    private func keyPassphraseRow(for node: ConnectionNode, jump: Bool) -> some View {
        let info = passphraseInfo(for: node, jump: jump)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Passphrase")
                Spacer()
                Text(info.state)
                    .foregroundStyle(info.isSet ? Color.secondary : Color.secondary)
                Button("Set…") { setPassphrase(for: node, jump: jump) }
                    .controlSize(.small)
                if library.definesPassphrase(for: node.id, jump: jump) {
                    Button("Clear") { library.clearPassphrase(for: node.id, jump: jump) }
                        .controlSize(.small)
                }
            }
            Text(info.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func passphraseInfo(for node: ConnectionNode, jump: Bool) -> (state: String, hint: String, isSet: Bool) {
        if library.definesPassphrase(for: node.id, jump: jump) {
            return ("Set", "Stored in the macOS Keychain for this item.", true)
        }
        if library.hasEffectivePassphrase(for: node.id, jump: jump) {
            return ("Inherited", "Set on a parent folder; edit it there to change it.", true)
        }
        return ("Not set", "Only needed when the key file is encrypted.", false)
    }

    private func setPassphrase(for node: ConnectionNode, jump: Bool) {
        guard let passphrase = promptForPassphrase(isJump: jump) else { return }
        library.setPassphrase(passphrase, for: node.id, jump: jump)
    }

    private func promptForPassphrase(isJump: Bool) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isJump ? "Jump key passphrase" : "Private key passphrase"
        alert.informativeText = "The passphrase is stored in the macOS Keychain, not in the connections file."

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Passphrase"
        alert.accessoryView = field

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    // MARK: - Hints

    private func jumpHint(for node: ConnectionNode) -> String {
        if node.definesJumpHost {
            return "Defined on this item."
        }
        if let resolved = library.resolve(node.id), resolved.jump != nil {
            return "Inherited from a parent folder."
        }
        return "Empty: connects directly, with no bastion."
    }

    private func effectiveDescription(for node: ConnectionNode) -> String {
        guard let resolved = library.resolve(node.id) else {
            return "Set a host to make this connection usable."
        }
        var parts = ["Route: \(resolved.routeDescription)"]
        if node.host == nil {
            parts.append("Host is empty, so this item is not connectable on its own.")
        } else if node.port == nil {
            parts.append("Port is inherited from the parent folder.")
        }
        return parts.joined(separator: "\n")
    }
}
