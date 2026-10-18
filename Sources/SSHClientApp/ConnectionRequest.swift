import Foundation
import SSHCore

/// A request to open a new session, as captured by the connect sheet.
struct ConnectionRequest: Identifiable {
    let id = UUID()
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var auth: SSHAuthMethod

    /// Display name for tabs, falling back to `user@host`.
    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "\(username)@\(host)"
    }
}
