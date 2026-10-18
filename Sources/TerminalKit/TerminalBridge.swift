import AppKit
import SwiftTerm

/// Adapts a SwiftTerm terminal to the SSH session.
///
/// Input flows out through `onSend`, layout changes through `onResize`, and
/// remote title changes through `onTitleChange`. Output is pushed in with
/// `feed(_:)`.
@MainActor
public final class TerminalBridge: NSObject, TerminalViewDelegate {
    public weak var terminalView: TerminalView?

    public var onSend: ((Data) -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var onTitleChange: ((String) -> Void)?

    public override init() {
        super.init()
    }

    /// Associates the bridge with a terminal view and takes over its delegate.
    public func attach(_ view: TerminalView) {
        terminalView = view
        view.terminalDelegate = self
    }

    /// Feeds remote output into the terminal.
    public func feed(_ data: Data) {
        guard let terminalView, !data.isEmpty else { return }
        terminalView.feed(byteArray: ArraySlice(data))
    }

    /// Gives the terminal keyboard focus.
    public func focus() {
        guard let terminalView, let window = terminalView.window else { return }
        window.makeFirstResponder(terminalView)
    }

    /// Dimensions currently known to the terminal.
    public var dimensions: (columns: Int, rows: Int)? {
        guard let terminalView else { return nil }
        let value = terminalView.terminalDimensions
        return (value.cols, value.rows)
    }

    // MARK: - TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onSend?(Data(data))
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChange?(title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func scrolled(source: TerminalView, position: Double) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
