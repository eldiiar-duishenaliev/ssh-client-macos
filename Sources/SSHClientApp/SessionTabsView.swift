import SwiftUI
import AppKit
import SSHCore

/// Tab strip plus the stack of terminal panes.
struct SessionTabsView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(store.sessions) { controller in
                        TabButton(
                            controller: controller,
                            isSelected: controller.id == store.selectedID,
                            select: { store.selectedID = controller.id },
                            close: { store.close(controller) }
                        )
                    }
                }
            }
            .frame(height: 30)
            .background(.bar)

            Divider()

            ZStack {
                ForEach(store.sessions) { controller in
                    TerminalPane(controller: controller)
                        .opacity(controller.id == store.selectedID ? 1 : 0)
                        .allowsHitTesting(controller.id == store.selectedID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TabButton: View {
    @ObservedObject var controller: SessionController
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(controller.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 0.7 : 0.4)
            .help("Close session")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    private var statusColor: Color {
        switch controller.state {
        case .connected: return .green
        case .failed: return .red
        case .closed: return .gray
        default: return .orange
        }
    }
}
