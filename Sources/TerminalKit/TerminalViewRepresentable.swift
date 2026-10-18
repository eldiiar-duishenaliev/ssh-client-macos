import SwiftUI
import AppKit
import SwiftTerm

/// Hosts a SwiftTerm `TerminalView` inside SwiftUI.
public struct TerminalViewRepresentable: NSViewRepresentable {
    private let bridge: TerminalBridge
    private let fontSize: CGFloat

    public init(bridge: TerminalBridge, fontSize: CGFloat = 12) {
        self.bridge = bridge
        self.fontSize = fontSize
    }

    public func makeNSView(context: Context) -> TerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let view = TerminalView(frame: .zero, font: font)
        bridge.attach(view)

        // SwiftUI does not focus the view automatically; do it once attached.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    public func updateNSView(_ nsView: TerminalView, context: Context) {}
}
