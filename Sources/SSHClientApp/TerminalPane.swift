import SwiftUI
import AppKit
import SSHCore
import TerminalKit

/// The terminal surface for one session, with a status banner while the
/// connection is being established or has failed.
struct TerminalPane: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ZStack(alignment: .bottom) {
            TerminalViewRepresentable(bridge: controller.bridge)

            if let banner {
                StatusBanner(text: banner.text, color: banner.color, detail: controller.lastError)
            }
        }
        .onAppear { controller.bridge.focus() }
    }

    private var banner: (text: String, color: Color)? {
        switch controller.state {
        case .connected:
            return nil
        case .idle, .connecting:
            return ("Connecting…", .orange)
        case .authenticating:
            return ("Authenticating…", .orange)
        case .closed:
            return ("Session closed", .secondary)
        case .failed:
            return ("Connection failed", .red)
        }
    }
}

private struct StatusBanner: View {
    let text: String
    let color: Color
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.callout).bold()
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.5)))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
