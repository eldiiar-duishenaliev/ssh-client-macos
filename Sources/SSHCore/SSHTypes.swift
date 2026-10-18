import Foundation

/// Errors surfaced by the SSH transport layer.
public enum SSHError: Error, LocalizedError, Equatable {
    case socket(String)
    case handshake(String)
    case authentication(String)
    case channel(String)
    case hostKeyRejected
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .socket(let message): return "Network error: \(message)"
        case .handshake(let message): return "SSH handshake failed: \(message)"
        case .authentication(let message): return "Authentication failed: \(message)"
        case .channel(let message): return "Channel error: \(message)"
        case .hostKeyRejected: return "Host key was rejected"
        case .disconnected: return "Connection closed"
        }
    }
}

/// How to authenticate against the remote host.
public struct SSHAuthMethod: Equatable {
    public enum Kind: Equatable {
        /// Password authentication.
        case password(String)
        /// Public key authentication. `publicKeyPath` is optional; libssh2 can
        /// derive it from the private key when omitted.
        case privateKey(privateKeyPath: String, publicKeyPath: String?, passphrase: String?)
        /// Use the identities offered by `SSH_AUTH_SOCK`.
        case agent
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// A bastion host that a connection is tunnelled through.
public struct SSHJumpConfiguration {
    public var host: String
    public var port: UInt16
    public var username: String
    public var auth: SSHAuthMethod
    public var knownHostsPath: String?
    public var connectTimeout: TimeInterval

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        auth: SSHAuthMethod,
        knownHostsPath: String? = nil,
        connectTimeout: TimeInterval = 15
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.knownHostsPath = knownHostsPath
        self.connectTimeout = connectTimeout
    }
}

/// Everything needed to open a session.
public struct SSHConfiguration {
    public var host: String
    public var port: UInt16
    public var username: String
    public var auth: SSHAuthMethod
    public var terminalType: String
    public var columns: Int
    public var rows: Int
    public var connectTimeout: TimeInterval
    /// Path to an OpenSSH `known_hosts` file. Defaults to `~/.ssh/known_hosts`.
    public var knownHostsPath: String?
    /// When set, the connection is tunnelled through this bastion.
    public var jump: SSHJumpConfiguration?

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        auth: SSHAuthMethod,
        terminalType: String = "xterm-256color",
        columns: Int = 80,
        rows: Int = 24,
        connectTimeout: TimeInterval = 15,
        knownHostsPath: String? = nil,
        jump: SSHJumpConfiguration? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.terminalType = terminalType
        self.columns = columns
        self.rows = rows
        self.connectTimeout = connectTimeout
        self.knownHostsPath = knownHostsPath
        self.jump = jump
    }
}

/// How the presented host key relates to `known_hosts`.
public enum HostKeyStatus: Equatable {
    /// Matches an existing `known_hosts` entry.
    case match
    /// Host is not present in `known_hosts`.
    case notFound
    /// Host is present but the key differs — a potential MITM.
    case mismatch
    /// `known_hosts` could not be read or checked.
    case failure
}

/// Details of the host key, handed to the verification callback.
public struct HostKeyInfo: Equatable {
    public let host: String
    public let port: UInt16
    /// Key algorithm, e.g. `ssh-ed25519`.
    public let keyType: String
    /// OpenSSH-style fingerprint, e.g. `SHA256:AbC...`.
    public let fingerprint: String
    public let status: HostKeyStatus
}

/// The user's answer to a host key prompt.
public enum HostKeyDecision: Equatable {
    case accept
    /// Accept and append the key to `known_hosts`.
    case acceptAndSave
    case reject
}
