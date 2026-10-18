import Foundation
import Clibssh2

/// Small helpers shared by the session and the tunnel.
enum Libssh2 {
    /// The last error reported by a session, including its message.
    static func message(_ session: OpaquePointer) -> String {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        libssh2_session_last_error(session, &message, &length, 0)
        if let message {
            return String(cString: message)
        }
        return "libssh2 error \(libssh2_session_last_errno(session))"
    }
}
