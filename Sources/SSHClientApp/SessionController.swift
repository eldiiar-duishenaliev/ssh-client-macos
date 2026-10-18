import Foundation
import AppKit
import SSHCore
import TerminalKit

/// Owns one SSH session and its terminal, and exposes the pieces SwiftUI needs.
@MainActor
final class SessionController: ObservableObject, Identifiable {
    let id = UUID()
    let request: ConnectionRequest

    @Published private(set) var title: String
    @Published private(set) var state: SSHSession.State = .idle
    @Published private(set) var lastError: String?

    let bridge = TerminalBridge()

    private var session: SSHSession?

    init(request: ConnectionRequest) {
        self.request = request
        self.title = request.displayName

        bridge.onSend = { [weak self] data in
            self?.session?.write(data)
        }
        bridge.onResize = { [weak self] columns, rows in
            self?.session?.resize(columns: columns, rows: rows)
        }
        bridge.onTitleChange = { [weak self] title in
            self?.applyRemoteTitle(title)
        }
    }

    /// Starts the connection. Idempotent.
    func connect() {
        guard session == nil else { return }

        let configuration = SSHConfiguration(
            host: request.host,
            port: request.port,
            username: request.username,
            auth: request.auth,
            terminalType: "xterm-256color",
            columns: 80,
            rows: 24,
            connectTimeout: 15,
            knownHostsPath: nil
        )

        let session = SSHSession(
            configuration: configuration,
            callbacks: .init(
                onData: { [weak self] data in
                    Task { @MainActor in self?.bridge.feed(data) }
                },
                onState: { [weak self] state in
                    Task { @MainActor in self?.handle(state) }
                },
                onError: { [weak self] error in
                    Task { @MainActor in self?.lastError = error.localizedDescription }
                },
                verifyHostKey: { info in
                    SessionController.promptForHostKey(info)
                }
            )
        )
        self.session = session
        session.start()
    }

    /// Closes the connection and releases the session.
    func disconnect() {
        session?.disconnect()
        session = nil
        if !state.isTerminal {
            state = .closed
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Private

    private func handle(_ newState: SSHSession.State) {
        state = newState
        if case .failed(let message) = newState {
            lastError = message
        }
    }

    private func applyRemoteTitle(_ remoteTitle: String) {
        // Terminals often report a generic or empty title; only adopt
        // something that carries information.
        let trimmed = remoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Terminal", trimmed != title else { return }
        title = trimmed
    }

    /// Shows a host key prompt and blocks the session thread until answered.
    ///
    /// Callable from any thread: it hops to the main actor for the alert and
    /// waits on a semaphore.
    nonisolated static func promptForHostKey(_ info: HostKeyInfo) -> HostKeyDecision {
        let box = LockedDecision()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.set(present(info))
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()
    }

    private nonisolated static func present(_ info: HostKeyInfo) -> HostKeyDecision {
        let alert = NSAlert()
        switch info.status {
        case .mismatch:
            alert.alertStyle = .critical
            alert.messageText = "Host key has changed"
            alert.informativeText = """
            The key for \(info.host):\(info.port) does not match the one in known_hosts. \
            This can mean the host was reinstalled, or that the connection is being \
            intercepted.

            \(info.keyType) \(info.fingerprint)
            """
        case .notFound:
            alert.alertStyle = .warning
            alert.messageText = "Unknown host"
            alert.informativeText = """
            The authenticity of \(info.host):\(info.port) cannot be established.

            \(info.keyType) \(info.fingerprint)
            """
        case .failure:
            alert.alertStyle = .warning
            alert.messageText = "Could not verify host key"
            alert.informativeText = """
            known_hosts could not be read or checked for \(info.host):\(info.port).

            \(info.keyType) \(info.fingerprint)
            """
        case .match:
            return .accept
        }

        alert.addButton(withTitle: "Accept and Save")
        alert.addButton(withTitle: "Accept Once")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .acceptAndSave
        case .alertSecondButtonReturn: return .accept
        default: return .reject
        }
    }
}

/// Tiny lock-protected box used to hand the modal result back to the waiting
/// session thread.
private final class LockedDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HostKeyDecision = .reject

    func get() -> HostKeyDecision {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: HostKeyDecision) {
        lock.lock(); value = newValue; lock.unlock()
    }
}
