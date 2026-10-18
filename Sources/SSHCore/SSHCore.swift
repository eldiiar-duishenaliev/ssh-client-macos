import Foundation
import Clibssh2

/// Entry point for the SSH transport layer.
///
/// Phase 0 only reports the linked libssh2 version, which doubles as a smoke
/// test that the C interop and linking are wired up correctly. Session,
/// authentication, known_hosts and PTY handling land in later phases.
public enum SSHCore {
    /// Version string of the linked libssh2, e.g. `1.11.1`.
    public static var libssh2Version: String {
        guard let cString = libssh2_version(0) else { return "unknown" }
        return String(cString: cString)
    }

    /// Initializes libssh2. Must be called once before any other SSH call.
    @discardableResult
    public static func initialize() -> Int32 {
        libssh2_init(0)
    }

    /// Releases libssh2 global state.
    public static func shutdown() {
        libssh2_exit()
    }
}
