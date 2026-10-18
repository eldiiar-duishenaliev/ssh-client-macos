import SwiftUI
import ConnectionStore

/// Editable copy of a node's properties, so edits can be reviewed before they
/// are written back to the library.
@MainActor
final class NodeEditor: ObservableObject {
    @Published var name = ""
    @Published var host = ""
    @Published var port = ""
    @Published var username = ""
    @Published var protocolKind: ProtocolKind = .ssh
    @Published var notes = ""
    @Published var isFolder = false

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
        protocolKind = node.protocolKind ?? .ssh
        notes = node.notes ?? ""
        isFolder = node.isFolder
    }

    /// Writes the edited values back. Empty text clears an override so the
    /// value is inherited from the parent folder again.
    func apply(to library: ConnectionLibrary) {
        guard let nodeID else { return }
        library.update(id: nodeID) { node in
            node.name = name.trimmingCharacters(in: .whitespaces).isEmpty
                ? node.name
                : name.trimmingCharacters(in: .whitespaces)
            node.host = Self.cleared(host)
            node.port = UInt16(port)
            node.username = Self.cleared(username)
            node.protocolKind = protocolKind
            node.notes = Self.cleared(notes)
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
        .frame(minWidth: 280)
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
                    }
                }

                Section {
                    TextField("Notes", text: $editor.notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Inheritance") {
                    Text(explanation(for: node))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private func explanation(for node: ConnectionNode) -> String {
        guard let id = library.selectedID, let resolved = library.resolve(id) else {
            return "Set a host to make this connection usable."
        }
        var parts = ["Effective: \(resolved.username)@\(resolved.host):\(resolved.port)"]
        if node.host == nil { parts.append("Host is empty, so this node is not connectable on its own.") }
        else if node.port == nil { parts.append("Port is inherited from the parent folder.") }
        return parts.joined(separator: "\n")
    }
}
