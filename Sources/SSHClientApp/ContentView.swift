import SwiftUI

struct ContentView: View {
    @StateObject private var store = SessionStore()
    @StateObject private var library = ConnectionLibrary()

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library, open: open)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            Group {
                if store.sessions.isEmpty {
                    EmptyStateView { store.isConnectSheetPresented = true }
                } else {
                    SessionTabsView(store: store)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 540)
        .toolbar { toolbarContent }
        .inspector(isPresented: $library.isInspectorPresented) {
            PropertiesInspectorView(library: library)
        }
        .sheet(isPresented: $store.isConnectSheetPresented) {
            ConnectSheet { store.open($0) }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.isConnectSheetPresented = true
            } label: {
                Label("Quick Connect", systemImage: "bolt.horizontal")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Quick connect without saving (⌘N)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                library.addFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("Add a folder to the connection tree")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                library.importFromPanel()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import an mRemoteNG confCons.xml file")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                library.isInspectorPresented.toggle()
            } label: {
                Label("Properties", systemImage: "sidebar.right")
            }
            .help("Show or hide connection properties")
        }
    }

    /// Opens a saved connection, or reveals the inspector when it is incomplete.
    private func open(_ id: UUID) {
        guard let request = library.makeRequest(for: id) else {
            library.selectedID = id
            library.isInspectorPresented = true
            return
        }
        store.open(request)
    }
}

private struct EmptyStateView: View {
    let newConnection: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No open sessions")
                .font(.title2)
            Text("Double-click a connection, or start a quick connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Quick Connect…", action: newConnection)
                .keyboardShortcut("n", modifiers: .command)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
