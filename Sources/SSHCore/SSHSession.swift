import Foundation
import Darwin
import Clibssh2

/// A single SSH session running one interactive shell on its own thread.
///
/// libssh2 is not thread-safe, so every libssh2 call happens on the session
/// thread. Callers interact through `write(_:)` and `resize(columns:rows:)`,
/// which enqueue work that the session thread drains between reads.
///
/// Callbacks fire on the session thread; the UI layer is responsible for
/// hopping to the main queue. The exception is `verifyHostKey`, which blocks
/// the session thread until the caller returns a decision, so it must not be
/// dispatched asynchronously.
public final class SSHSession {
    public enum State: Equatable {
        case idle
        case connecting
        case authenticating
        case connected
        case closed
        case failed(String)

        public var isTerminal: Bool {
            switch self {
            case .closed, .failed: return true
            default: return false
            }
        }
    }

    public struct Callbacks {
        /// Terminal output received from the remote host.
        public var onData: (Data) -> Void
        /// Session state changes.
        public var onState: (State) -> Void
        /// A fatal error. Terminal state is reported separately via `onState`.
        public var onError: (SSHError) -> Void
        /// Called before authentication when a host key needs a decision.
        /// Also used for the jump host's key.
        public var verifyHostKey: (HostKeyInfo) -> HostKeyDecision

        public init(
            onData: @escaping (Data) -> Void = { _ in },
            onState: @escaping (State) -> Void = { _ in },
            onError: @escaping (SSHError) -> Void = { _ in },
            verifyHostKey: @escaping (HostKeyInfo) -> HostKeyDecision = { _ in .reject }
        ) {
            self.onData = onData
            self.onState = onState
            self.onError = onError
            self.verifyHostKey = verifyHostKey
        }
    }

    public let configuration: SSHConfiguration
    private let callbacks: Callbacks

    // Session-thread owned state.
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var tunnel: JumpTunnel?

    // Cross-thread state, guarded by `lock`.
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var outgoing: [PendingWrite] = []
    private var stopped = false

    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    private enum PendingWrite {
        case data(Data)
        case resize(columns: Int, rows: Int)
    }

    public init(configuration: SSHConfiguration, callbacks: Callbacks) {
        self.configuration = configuration
        self.callbacks = callbacks
    }

    deinit {
        // Best effort: the caller should have called disconnect().
        if thread != nil { disconnect() }
    }

    // MARK: - Public API

    /// Starts the session on a background thread. Returns immediately.
    public func start() {
        var descriptors: [Int32] = [-1, -1]
        if pipe(&descriptors) == 0 {
            wakeRead = descriptors[0]
            wakeWrite = descriptors[1]
        }

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "SSHSession"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    /// Queues terminal input for the remote shell.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        outgoing.append(.data(data))
        lock.unlock()
        wake()
    }

    /// Queues a PTY resize.
    public func resize(columns: Int, rows: Int) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        outgoing.append(.resize(columns: columns, rows: rows))
        lock.unlock()
        wake()
    }

    /// Stops the session and releases resources. Safe to call more than once.
    public func disconnect() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        outgoing.removeAll()
        let fd = socketFD
        lock.unlock()

        // `shutdown` unblocks the session thread's blocking reads.
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        wake()
        _ = finished.wait(timeout: .now() + 5)
    }

    // MARK: - Thread plumbing

    private func wake() {
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func emit(_ state: State) {
        callbacks.onState(state)
    }

    // MARK: - Session lifecycle

    private func run() {
        defer { finished.signal() }

        SSHCore.initialize()
        emit(.connecting)

        do {
            let fd = try connectTransport()
            lock.lock()
            socketFD = fd
            lock.unlock()

            guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
                throw SSHError.handshake("could not create session")
            }
            self.session = session
            libssh2_session_set_blocking(session, 1)

            guard libssh2_session_handshake(session, fd) == 0 else {
                throw SSHError.handshake(Libssh2.message(session))
            }

            try HostKeyVerifier.verify(
                session: session,
                host: configuration.host,
                port: configuration.port,
                knownHostsPath: configuration.knownHostsPath,
                decide: callbacks.verifyHostKey
            )

            emit(.authenticating)
            try SSHAuthenticator.authenticate(
                session: session,
                username: configuration.username,
                auth: configuration.auth
            )

            try openShell(session: session)
            emit(.connected)
            ioLoop(session: session)
        } catch let error as SSHError {
            if !isStopped() {
                emit(.failed(error.localizedDescription))
                callbacks.onError(error)
            }
        } catch {
            if !isStopped() {
                emit(.failed(error.localizedDescription))
                callbacks.onError(.socket(error.localizedDescription))
            }
        }

        teardown()
        if !isStopped() {
            emit(.closed)
        }
    }

    /// Opens the transport, tunnelling through the jump host when configured.
    private func connectTransport() throws -> Int32 {
        guard let jump = configuration.jump else {
            return try SSHSocket.openConnection(
                host: configuration.host,
                port: configuration.port,
                timeout: configuration.connectTimeout
            )
        }

        let tunnel = JumpTunnel(
            configuration: jump,
            targetHost: configuration.host,
            targetPort: configuration.port,
            decide: callbacks.verifyHostKey
        )
        let fd = try tunnel.start()
        self.tunnel = tunnel
        return fd
    }

    private func teardown() {
        if let channel, let session {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
            libssh2_session_disconnect_ex(session, 11, "bye", "")
            libssh2_session_free(session)
        }
        self.channel = nil
        self.session = nil

        lock.lock()
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        // Closing the tunnel's local end also ends its pump.
        if fd >= 0 { close(fd) }

        tunnel?.stop()
        tunnel = nil

        for descriptor in [wakeRead, wakeWrite] where descriptor >= 0 {
            close(descriptor)
        }
        wakeRead = -1
        wakeWrite = -1
    }

    // MARK: - Shell channel

    private func openShell(session: OpaquePointer) throws {
        guard let channel = libssh2_channel_open_ex(
            session,
            "session",
            7,
            2 * 1024 * 1024,
            32768,
            nil,
            0
        ) else {
            throw SSHError.channel(Libssh2.message(session))
        }
        self.channel = channel

        let terminal = configuration.terminalType
        let ptyResult = terminal.withCString { term in
            libssh2_channel_request_pty_ex(
                channel,
                term,
                UInt32(terminal.utf8.count),
                nil,
                0,
                Int32(configuration.columns),
                Int32(configuration.rows),
                0,
                0
            )
        }
        guard ptyResult == 0 else {
            throw SSHError.channel("could not allocate a PTY: \(Libssh2.message(session))")
        }

        guard libssh2_channel_process_startup(channel, "shell", 5, nil, 0) == 0 else {
            throw SSHError.channel("could not start the shell: \(Libssh2.message(session))")
        }
    }

    // MARK: - I/O loop

    private func ioLoop(session: OpaquePointer) {
        guard let channel else { return }
        var buffer = [UInt8](repeating: 0, count: 32768)

        while !isStopped() {
            drainOutgoing(session: session, channel: channel)
            if isStopped() { break }

            lock.lock()
            let fd = socketFD
            lock.unlock()

            var descriptors = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&descriptors, 2, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            if descriptors[1].revents != 0 {
                var byte: UInt8 = 0
                _ = Darwin.read(wakeRead, &byte, 1)
            }

            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let count: Int = buffer.withUnsafeMutableBytes { raw in
                    libssh2_channel_read_ex(
                        channel,
                        0,
                        raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                        raw.count
                    )
                }
                if count > 0 {
                    callbacks.onData(Data(buffer[0..<count]))
                } else if count < 0 {
                    let code = libssh2_session_last_errno(session)
                    if code != LIBSSH2_ERROR_EAGAIN { break }
                }
            }

            if libssh2_channel_eof(channel) != 0 { break }
        }
    }

    private func drainOutgoing(session: OpaquePointer, channel: OpaquePointer) {
        lock.lock()
        let items = outgoing
        outgoing.removeAll()
        lock.unlock()

        for item in items {
            switch item {
            case .data(let data):
                writeAll(session: session, channel: channel, data: data)
            case .resize(let columns, let rows):
                _ = libssh2_channel_request_pty_size_ex(
                    channel, Int32(columns), Int32(rows), 0, 0
                )
            }
        }
    }

    private func writeAll(session: OpaquePointer, channel: OpaquePointer, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = libssh2_channel_write_ex(
                    channel,
                    0,
                    base.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                    raw.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0 {
                    if libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN { continue }
                    return
                } else {
                    return
                }
            }
        }
    }
}
