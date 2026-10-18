import SwiftUI
import SSHCore

/// Phase 0 shell: verifies the toolchain (libssh2 linked, SwiftTerm available)
/// and lays out the sidebar + session area that later phases fill in.
struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            SidebarPlaceholder()
        } detail: {
            DetailPlaceholder()
        }
    }
}

private struct SidebarPlaceholder: View {
    var body: some View {
        List {
            Section("Connections") {
                Label("No connections yet", systemImage: "server.rack")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Connections")
        .frame(minWidth: 220)
    }
}

private struct DetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("SSH client scaffold")
                .font(.title2)
            Text("libssh2 \(SSHCore.libssh2Version) linked")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Terminal sessions arrive in phase 1.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
