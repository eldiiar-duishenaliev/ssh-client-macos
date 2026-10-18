import SwiftUI

struct ContentView: View {
    @StateObject private var store = SessionStore()

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                EmptyStateView { store.isConnectSheetPresented = true }
            } else {
                SessionTabsView(store: store)
            }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.isConnectSheetPresented = true
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New SSH connection (⌘N)")
            }
        }
        .sheet(isPresented: $store.isConnectSheetPresented) {
            ConnectSheet { request in
                store.open(request)
            }
        }
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
            Text("Open an SSH connection to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("New Connection…", action: newConnection)
                .keyboardShortcut("n", modifiers: .command)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
