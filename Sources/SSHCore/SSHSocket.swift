import Foundation
import Darwin

/// Minimal blocking TCP client used for the SSH transport.
enum SSHSocket {
    /// Connects to `host:port` and returns a connected, blocking file
    /// descriptor. Tries each resolved address in turn.
    static func openConnection(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            let message = String(cString: gai_strerror(status))
            throw SSHError.socket("could not resolve \(host): \(message)")
        }
        defer { freeaddrinfo(first) }

        var lastMessage = "no usable address"
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            defer { candidate = address.pointee.ai_next }

            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            guard fd >= 0 else {
                lastMessage = String(cString: strerror(errno))
                continue
            }

            if let message = attemptConnect(fd: fd, address: address.pointee, timeout: timeout) {
                lastMessage = message
                close(fd)
                continue
            }

            // Restore blocking mode and disable Nagle for interactive use.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags)
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            return fd
        }

        throw SSHError.socket("could not connect to \(host):\(port): \(lastMessage)")
    }

    /// Returns `nil` on success, or a human-readable failure reason.
    private static func attemptConnect(fd: Int32, address: addrinfo, timeout: TimeInterval) -> String? {
        let original = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, original | O_NONBLOCK)

        if Darwin.connect(fd, address.ai_addr, address.ai_addrlen) == 0 {
            return nil
        }
        if errno != EINPROGRESS {
            return String(cString: strerror(errno))
        }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(1, timeout * 1000))
        let ready = poll(&descriptor, 1, milliseconds)
        if ready == 0 { return "timed out after \(Int(timeout))s" }
        if ready < 0 { return String(cString: strerror(errno)) }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
        if socketError != 0 { return String(cString: strerror(socketError)) }

        return nil
    }
}
