import SwiftUI
import AppKit
import ConnectionStore

/// The connection tree.
struct SidebarView: View {
    @ObservedObject var library: ConnectionLibrary
    let open: (UUID) -> Void

    var body: some View {
        List(selection: $library.selectedID) {
            OutlineGroup(library.tree.roots, children: \.outlineChildren) { node in
                NodeRow(node: node)
                    .tag(node.id)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded { open(node.id) })
                    .contextMenu { menu(for: node) }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Folder") { library.addFolder() }
            Button("New Connection") { library.addConnection() }
        }
        .overlay {
            if library.tree.isEmpty {
                VStack(spacing: 6) {
                    Text("No connections")
                        .foregroundStyle(.secondary)
                    Text("Right-click to add one, or import an mRemoteNG file.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func menu(for node: ConnectionNode) -> some View {
        if !node.isFolder {
            Button("Connect") { open(node.id) }
            Divider()
        }
        if node.isFolder {
            Button("New Connection") { library.addConnection(parent: node.id) }
            Button("New Folder") { library.addFolder(parent: node.id) }
            Divider()
        }
        Button("Show Properties") {
            library.selectedID = node.id
            library.isInspectorPresented = true
        }
        Divider()
        Button("Delete", role: .destructive) { library.remove(id: node.id) }
    }
}

private struct NodeRow: View {
    let node: ConnectionNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(node.isFolder ? Color.accentColor : Color.secondary)

            Text(node.name)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !node.isFolder, let host = node.host, !host.isEmpty {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var symbol: String {
        guard !node.isFolder else { return "folder" }
        switch node.protocolKind ?? .ssh {
        case .ssh, .sftp: return "terminal"
        case .rdp: return "desktopcomputer"
        case .vnc: return "display"
        case .telnet: return "network"
        case .http: return "globe"
        case .raw: return "cable.connector"
        }
    }
}

extension ConnectionNode {
    /// Children for `OutlineGroup`. Empty folders become leaves so they do not
    /// show a disclosure triangle with nothing inside.
    var outlineChildren: [ConnectionNode]? {
        isFolder && !children.isEmpty ? children : nil
    }
}
