import Foundation
import Darwin
import Clibssh2

/// Tunnels an SSH connection through a bastion host ("ProxyJump").
///
/// A first session connects to the bastion, verifies its key, authenticates,
/// and opens a `direct-tcpip` channel to the target. That channel is bridged
/// to one end of a socket pair, and the caller runs the real SSH session over
/// the other end — so the target session itself needs no knowledge of the
/// tunnel, and libssh2 never has to run two sessions on one thread.
///
/// `start()` returns the file descriptor for the target session. The caller
/// owns that descriptor and closes it when done, which ends the pump.
final class JumpTunnel {
    private let configuration: SSHJumpConfiguration
    private let targetHost: String
    private let targetPort: UInt16
    private let decide: (HostKeyInfo) -> HostKeyDecision

    private var bastionFD: Int32 = -1
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var localFD: Int32 = -1
    private var remoteFD: Int32 = -1
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false

    init(
        configuration: SSHJumpConfiguration,
        targetHost: String,
        targetPort: UInt16,
        decide: @escaping (HostKeyInfo) -> HostKeyDecision
    ) {
        self.configuration = configuration
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.decide = decide
    }

    // MARK: - Setup

    /// Connects through the bastion and returns the transport descriptor for
    /// the target session.
    func start() throws -> Int32 {
        bastionFD = try SSHSocket.openConnection(
            host: configuration.host,
            port: configuration.port,
            timeout: configuration.connectTimeout
        )

        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            closeBastion()
            throw SSHError.handshake("could not create the jump session")
        }
        self.session = session
        libssh2_session_set_blocking(session, 1)

        guard libssh2_session_handshake(session, bastionFD) == 0 else {
            let message = Libssh2.message(session)
            cleanup()
            throw SSHError.handshake("jump host \(configuration.host): \(message)")
        }

        do {
            try HostKeyVerifier.verify(
                session: session,
                host: configuration.host,
                port: configuration.port,
                knownHostsPath: configuration.knownHostsPath,
                decide: decide
            )
            try SSHAuthenticator.authenticate(
                session: session,
                username: configuration.username,
                auth: configuration.auth
            )
        } catch {
            cleanup()
            throw error
        }

        guard let channel = targetHost.withCString({ hostPointer in
            libssh2_channel_direct_tcpip_ex(session, hostPointer, Int32(targetPort), "127.0.0.1", 22)
        }) else {
            let message = Libssh2.message(session)
            cleanup()
            throw SSHError.channel("jump host refused the tunnel to \(targetHost):\(targetPort): \(message)")
        }
        self.channel = channel

        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            cleanup()
            throw SSHError.socket("could not create the tunnel socket pair")
        }
        localFD = descriptors[0]
        remoteFD = descriptors[1]

        // The pump may write to its end after the caller closes theirs.
        var noSignal: Int32 = 1
        for descriptor in [localFD, remoteFD] {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        }

        var wake: [Int32] = [-1, -1]
        if pipe(&wake) == 0 {
            wakeRead = wake[0]
            wakeWrite = wake[1]
        }

        // The pump is the only user of this session, so non-blocking is safe
        // and lets us interleave both directions.
        libssh2_session_set_blocking(session, 0)

        let thread = Thread { [weak self] in self?.pump() }
        thread.name = "SSHJumpTunnel"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()

        return localFD
    }

    /// Stops the pump and releases the bastion session.
    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()

        wake()
        _ = finished.wait(timeout: .now() + 3)
    }

    // MARK: - Pump

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func wake() {
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
    }

    private func pump() {
        defer { finished.signal() }
        guard let session, let channel else { return }

        var buffer = [UInt8](repeating: 0, count: 32768)

        while !isStopped() {
            var descriptors = [
                pollfd(fd: remoteFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&descriptors, 2, 20)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }

            if ready > 0, descriptors[1].revents != 0 {
                var byte: UInt8 = 0
                _ = Darwin.read(wakeRead, &byte, 1)
            }

            // Target session -> bastion.
            if ready > 0, descriptors[0].revents & Int16(POLLIN) != 0 {
                let count: Int = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(remoteFD, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    if !writeToChannel(channel: channel, session: session, bytes: buffer[0..<count]) { break }
                } else if count == 0 {
                    break // the target session closed its end
                } else if errno != EAGAIN && errno != EINTR {
                    break
                }
            }

            // Bastion -> target session.
            let received: Int = buffer.withUnsafeMutableBytes { raw in
                libssh2_channel_read_ex(
                    channel, 0,
                    raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                    raw.count
                )
            }
            if received > 0 {
                if !writeToSocket(bytes: buffer[0..<received]) { break }
            } else if received < 0, libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN {
                break
            }

            if libssh2_channel_eof(channel) != 0 { break }
        }

        cleanup()
    }

    private func writeToChannel(channel: OpaquePointer, session: OpaquePointer, bytes: ArraySlice<UInt8>) -> Bool {
        let array = Array(bytes)
        return array.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            var stalls = 0
            while offset < raw.count {
                let written = libssh2_channel_write_ex(
                    channel, 0,
                    base.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                    raw.count - offset
                )
                if written > 0 {
                    offset += written
                    stalls = 0
                } else if written < 0 {
                    guard libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN else { return false }
                    // Wait for the bastion socket to accept more.
                    stalls += 1
                    if stalls > 5000 { return false }
                    var descriptor = pollfd(fd: bastionFD, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 10)
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func writeToSocket(bytes: ArraySlice<UInt8>) -> Bool {
        let array = Array(bytes)
        return array.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(remoteFD, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 {
                    if errno == EINTR { continue }
                    return false
                } else {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Teardown

    private func closeBastion() {
        if bastionFD >= 0 {
            shutdown(bastionFD, SHUT_RDWR)
            close(bastionFD)
            bastionFD = -1
        }
    }

    /// Frees the bastion session and its sockets. `localFD` belongs to the
    /// caller and is left alone.
    private func cleanup() {
        if let channel, let session {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
            libssh2_session_disconnect_ex(session, 11, "bye", "")
            libssh2_session_free(session)
        }
        channel = nil
        session = nil

        closeBastion()

        if remoteFD >= 0 {
            close(remoteFD)
            remoteFD = -1
        }
        for descriptor in [wakeRead, wakeWrite] where descriptor >= 0 {
            close(descriptor)
        }
        wakeRead = -1
        wakeWrite = -1
    }
}
