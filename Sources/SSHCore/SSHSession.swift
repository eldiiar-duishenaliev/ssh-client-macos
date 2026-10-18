import Foundation
import Darwin
import CryptoKit
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
        /// Called before authentication when the host key needs a decision.
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

        libssh2_init(0)
        emit(.connecting)

        do {
            let fd = try SSHSocket.openConnection(
                host: configuration.host,
                port: configuration.port,
                timeout: configuration.connectTimeout
            )
            lock.lock()
            socketFD = fd
            lock.unlock()

            guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
                throw SSHError.handshake("could not create session")
            }
            self.session = session
            libssh2_session_set_blocking(session, 1)

            guard libssh2_session_handshake(session, fd) == 0 else {
                throw SSHError.handshake(lastErrorMessage(session))
            }

            try verifyHostKey(session: session)

            emit(.authenticating)
            try authenticate(session: session)

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
        if fd >= 0 { close(fd) }

        for descriptor in [wakeRead, wakeWrite] where descriptor >= 0 {
            close(descriptor)
        }
        wakeRead = -1
        wakeWrite = -1
    }

    // MARK: - Host key verification

    private func verifyHostKey(session: OpaquePointer) throws {
        var keyLength = 0
        var keyType: Int32 = 0
        guard let keyPointer = libssh2_session_hostkey(session, &keyLength, &keyType) else {
            throw SSHError.handshake("server did not present a host key")
        }
        let blob = Data(bytes: keyPointer, count: keyLength)
        let keyName = Self.keyAlgorithmName(for: blob) ?? "unknown"
        let fingerprint = Self.fingerprint(for: blob)

        let status = checkKnownHosts(session: session, blob: blob)
        let info = HostKeyInfo(
            host: configuration.host,
            port: configuration.port,
            keyType: keyName,
            fingerprint: fingerprint,
            status: status
        )

        if status == .match {
            return
        }

        let decision = callbacks.verifyHostKey(info)
        switch decision {
        case .reject:
            throw SSHError.hostKeyRejected
        case .accept:
            return
        case .acceptAndSave:
            try saveKnownHost(blob: blob, keyName: keyName)
        }
    }

    private func checkKnownHosts(session: OpaquePointer, blob: Data) -> HostKeyStatus {
        guard let hosts = libssh2_knownhost_init(session) else { return .failure }
        defer { libssh2_knownhost_free(hosts) }

        if let path = knownHostsPath, !path.isEmpty {
            path.withCString { pointer in
                _ = libssh2_knownhost_readfile(hosts, pointer, LIBSSH2_KNOWNHOST_FILE_OPENSSH)
            }
        }

        var entry: UnsafeMutablePointer<libssh2_knownhost>?
        let result = configuration.host.withCString { hostPointer in
            blob.withUnsafeBytes { raw -> Int32 in
                libssh2_knownhost_checkp(
                    hosts,
                    hostPointer,
                    Int32(configuration.port),
                    raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                    raw.count,
                    LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW,
                    &entry
                )
            }
        }

        switch result {
        case LIBSSH2_KNOWNHOST_CHECK_MATCH: return .match
        case LIBSSH2_KNOWNHOST_CHECK_MISMATCH: return .mismatch
        case LIBSSH2_KNOWNHOST_CHECK_NOTFOUND: return .notFound
        default: return .failure
        }
    }

    private func saveKnownHost(blob: Data, keyName: String) throws {
        guard let path = knownHostsPath, !path.isEmpty else { return }

        let hostField = configuration.port == 22
            ? configuration.host
            : "[\(configuration.host)]:\(configuration.port)"
        let line = "\(hostField) \(keyName) \(blob.base64EncodedString())\n"

        let fileManager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: URL(fileURLWithPath: path))
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    // MARK: - Authentication

    private func authenticate(session: OpaquePointer) throws {
        let username = configuration.username

        switch configuration.auth.kind {
        case .password(let password):
            let result = username.withCString { user in
                password.withCString { pass in
                    libssh2_userauth_password_ex(
                        session,
                        user,
                        UInt32(username.utf8.count),
                        pass,
                        UInt32(password.utf8.count),
                        nil
                    )
                }
            }
            guard result == 0 else {
                throw SSHError.authentication(lastErrorMessage(session))
            }

        case .privateKey(let privateKeyPath, let publicKeyPath, let passphrase):
            let result = username.withCString { user in
                privateKeyPath.withCString { priv in
                    let work = { (pub: UnsafePointer<CChar>?) -> Int32 in
                        if let passphrase {
                            return passphrase.withCString { pass in
                                libssh2_userauth_publickey_fromfile_ex(
                                    session, user, UInt32(username.utf8.count), pub, priv, pass
                                )
                            }
                        }
                        return libssh2_userauth_publickey_fromfile_ex(
                            session, user, UInt32(username.utf8.count), pub, priv, nil
                        )
                    }
                    if let publicKeyPath {
                        return publicKeyPath.withCString { work($0) }
                    }
                    return work(nil)
                }
            }
            guard result == 0 else {
                throw SSHError.authentication(lastErrorMessage(session))
            }

        case .agent:
            try authenticateWithAgent(session: session, username: username)
        }
    }

    private func authenticateWithAgent(session: OpaquePointer, username: String) throws {
        guard let agent = libssh2_agent_init(session) else {
            throw SSHError.authentication("could not initialize the SSH agent")
        }
        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }

        guard libssh2_agent_connect(agent) == 0 else {
            throw SSHError.authentication("could not connect to the SSH agent")
        }
        guard libssh2_agent_list_identities(agent) == 0 else {
            throw SSHError.authentication("could not list agent identities")
        }

        var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?

        while libssh2_agent_get_identity(agent, &identity, previous) == 0 {
            guard let identity else { break }
            let result = username.withCString { user in
                libssh2_agent_userauth(agent, user, identity)
            }
            if result == 0 { return }
            previous = identity
        }

        throw SSHError.authentication("no agent identity was accepted")
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
            throw SSHError.channel(lastErrorMessage(session))
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
            throw SSHError.channel("could not allocate a PTY: \(lastErrorMessage(session))")
        }

        guard libssh2_channel_process_startup(channel, "shell", 5, nil, 0) == 0 else {
            throw SSHError.channel("could not start the shell: \(lastErrorMessage(session))")
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

    // MARK: - Helpers

    /// Resolved `known_hosts` path, defaulting to `~/.ssh/known_hosts`.
    private var knownHostsPath: String? {
        if let path = configuration.knownHostsPath, !path.isEmpty { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".ssh/known_hosts")
    }

    private func lastErrorMessage(_ session: OpaquePointer) -> String {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        libssh2_session_last_error(session, &message, &length, 0)
        if let message {
            return String(cString: message)
        }
        return "libssh2 error \(libssh2_session_last_errno(session))"
    }

    /// OpenSSH-style `SHA256:...` fingerprint of a public key blob.
    static func fingerprint(for blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let encoded = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    /// Reads the algorithm name (e.g. `ssh-ed25519`) from a key blob.
    static func keyAlgorithmName(for blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let length = blob.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        let end = 4 + Int(length)
        guard end <= blob.count else { return nil }
        return String(data: blob.subdata(in: 4..<end), encoding: .utf8)
    }
}
