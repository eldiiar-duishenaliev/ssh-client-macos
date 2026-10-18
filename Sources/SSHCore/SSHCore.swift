import Foundation
import Darwin
import Clibssh2

/// Entry point for the SSH transport layer.
///
/// `initialize()` performs the one-time process setup and must be called
/// before any session starts. `SSHSession` does this for you.
public enum SSHCore {
    /// Version string of the linked libssh2, e.g. `1.11.1`.
    public static var libssh2Version: String {
        guard let cString = libssh2_version(0) else { return "unknown" }
        return String(cString: cString)
    }

    /// One-time process setup. SIGPIPE is ignored because writing to a socket
    /// whose peer has already closed raises it, and its default action is to
    /// terminate the process — a user closing a session at the wrong moment
    /// would otherwise take the app down. Sockets additionally set
    /// `SO_NOSIGPIPE`; this backstop also covers pipes.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Initializes libssh2 and process signal handling.
    ///
    /// libssh2's initialization is reference counted, so calling this per
    /// session is correct and pairs with `shutdown()`.
    @discardableResult
    public static func initialize() -> Int32 {
        _ = ignoreSIGPIPE
        return libssh2_init(0)
    }

    /// Releases libssh2 global state.
    public static func shutdown() {
        libssh2_exit()
    }
}
