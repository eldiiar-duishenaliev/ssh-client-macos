import Foundation
import AppKit
import UniformTypeIdentifiers
import SSHCore
import ConnectionStore
import CredentialKit

/// Owns the connection tree, its persistence, and imported passwords.
@MainActor
final class ConnectionLibrary: ObservableObject {
    @Published private(set) var tree: ConnectionTree
    @Published var selectedID: UUID?
    @Published var isInspectorPresented = false

    private let store: ConnectionDocumentStore
    private let secrets: KeychainSecretStore
    private let importer: MRemoteNGImporter

    init(
        store: ConnectionDocumentStore = ConnectionDocumentStore(url: ConnectionDocumentStore.defaultURL()),
        secrets: KeychainSecretStore = KeychainSecretStore()
    ) {
        self.store = store
        self.secrets = secrets
        self.importer = MRemoteNGImporter(secrets: secrets)
        self.tree = (try? store.load()) ?? ConnectionTree()
    }

    // MARK: - Persistence

    func save() {
        do {
            try store.save(tree)
        } catch {
            NSLog("Failed to save connections: \(error.localizedDescription)")
        }
    }

    // MARK: - Mutation

    @discardableResult
    func addFolder(named name: String = "New Folder", parent: UUID? = nil) -> UUID {
        let node = ConnectionNode(kind: .folder, name: name)
        tree.insert(node, intoFolder: parent)
        selectedID = node.id
        save()
        return node.id
    }

    @discardableResult
    func addConnection(parent: UUID? = nil) -> UUID {
        let node = ConnectionNode(kind: .connection, name: "New Connection", protocolKind: .ssh)
        tree.insert(node, intoFolder: parent)
        selectedID = node.id
        isInspectorPresented = true
        save()
        return node.id
    }

    func rename(id: UUID, to name: String) {
        update(id: id) { $0.name = name }
    }

    func remove(id: UUID) {
        guard tree.remove(id: id) else { return }
        if selectedID == id { selectedID = nil }
        save()
    }

    func update(id: UUID, _ transform: (inout ConnectionNode) -> Void) {
        guard tree.update(id: id, transform) else { return }
        save()
    }

    func move(id: UUID, to parent: UUID?) {
        guard tree.move(id: id, toFolder: parent) else { return }
        save()
    }

    func resolve(_ id: UUID) -> ResolvedConnection? {
        tree.resolve(id: id)
    }

    /// Parent folder of a node, used to place new siblings.
    func parentID(of id: UUID) -> UUID? {
        let path = tree.path(to: id)
        return path?.dropLast().last?.id
    }

    /// Builds a session request from a stored connection, preferring a
    /// Keychain password, then a private key, then ssh-agent.
    func makeRequest(for id: UUID) -> ConnectionRequest? {
        guard let resolved = tree.resolve(id: id) else { return nil }

        let auth: SSHAuthMethod
        if let credentialID = resolved.credentialID,
           let secret = secrets.secret(for: credentialID),
           !secret.isEmpty {
            auth = SSHAuthMethod(kind: .password(secret))
        } else if let keyPath = resolved.privateKeyPath, !keyPath.isEmpty {
            auth = SSHAuthMethod(kind: .privateKey(
                privateKeyPath: NSString(string: keyPath).expandingTildeInPath,
                publicKeyPath: nil,
                passphrase: nil
            ))
        } else {
            auth = SSHAuthMethod(kind: .agent)
        }

        return ConnectionRequest(
            name: resolved.name,
            host: resolved.host,
            port: resolved.port,
            username: resolved.username,
            auth: auth
        )
    }

    // MARK: - Import

    /// Presents an open panel and imports the chosen mRemoteNG file.
    /// Returns the result, or `nil` if the user cancelled.
    @discardableResult
    func importFromPanel() -> MRemoteNGImportResult? {
        let panel = NSOpenPanel()
        panel.title = "Import mRemoteNG connections"
        panel.message = "Choose a confCons.xml file."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let xml = UTType(filenameExtension: "xml") {
            panel.allowedContentTypes = [xml]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importConnections(from: url)
    }

    @discardableResult
    func importConnections(from url: URL) -> MRemoteNGImportResult? {
        var password: String?
        var message: String?

        for _ in 0..<5 {
            do {
                let result = try importer.importTree(at: url, masterPassword: password)
                merge(result.tree)
                save()
                if !result.warnings.isEmpty {
                    Self.showInfo(
                        title: "Import finished with warnings",
                        message: result.warnings.joined(separator: "\n")
                    )
                }
                return result
            } catch MRemoteNGImportError.passwordRequired {
                message = "“\(url.lastPathComponent)” is protected by a master password."
            } catch MRemoteNGImportError.wrongPassword {
                message = "That master password is incorrect. Try again."
            } catch {
                Self.showError("Import failed", error.localizedDescription)
                return nil
            }

            guard let entered = Self.promptForPassword(message: message ?? "") else { return nil }
            password = entered
        }
        return nil
    }

    private func merge(_ imported: ConnectionTree) {
        guard !imported.roots.isEmpty else { return }
        var merged = tree
        merged.roots.append(contentsOf: imported.roots)
        tree = merged
    }

    // MARK: - Prompts

    private static func promptForPassword(message: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Master password required"
        alert.informativeText = message

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Master password"
        alert.accessoryView = field

        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private static func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
