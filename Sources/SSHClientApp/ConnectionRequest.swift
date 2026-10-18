import Foundation
import SSHCore

/// A request to open a new session, as captured by the connect sheet or
/// resolved from a stored connection.
struct ConnectionRequest: Identifiable {
    let id = UUID()
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var auth: SSHAuthMethod
    /// When set, the session is tunnelled through this bastion.
    var jump: SSHJumpConfiguration?

    /// Display name for tabs, falling back to `user@host`.
    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "\(username)@\(host)"
    }

    /// Human-readable route, showing the bastion when there is one.
    var routeDescription: String {
        guard let jump else { return "\(username)@\(host):\(port)" }
        return "\(jump.username)@\(jump.host) → \(username)@\(host):\(port)"
    }
}
