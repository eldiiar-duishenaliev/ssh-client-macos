import Foundation

/// Remote access protocol for a connection.
///
/// Only `ssh` is implemented; the rest exist so imported data round-trips and
/// the model does not need to change when they are added.
public enum ProtocolKind: String, Codable, CaseIterable, Sendable {
    case ssh
    case sftp
    case rdp
    case vnc
    case telnet
    case http
    case raw

    /// Conventional port for the protocol.
    public var defaultPort: UInt16 {
        switch self {
        case .ssh, .sftp: return 22
        case .rdp: return 3389
        case .vnc: return 5900
        case .telnet: return 23
        case .http: return 80
        case .raw: return 0
        }
    }
}

/// A node in the connection tree: either a folder or a connection.
///
/// Inheritable properties are optional; `nil` means "take the value from the
/// nearest ancestor that sets one".
public struct ConnectionNode: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case folder
        case connection
    }

    public var id: UUID
    public var kind: Kind
    public var name: String

    // Inheritable properties.
    public var host: String?
    public var port: UInt16?
    public var username: String?
    public var protocolKind: ProtocolKind?
    public var privateKeyPath: String?
    /// Reference to a Keychain-stored password. Added in phase 3.
    public var credentialID: UUID?
    /// Reference to the Keychain-stored passphrase for `privateKeyPath`.
    /// Passphrases are secrets, so they are never written to the JSON tree.
    public var keyPassphraseID: UUID?

    // Jump host ("ProxyJump"), also inheritable so a folder can carry a
    // shared bastion for everything beneath it.
    public var jumpHost: String?
    public var jumpPort: UInt16?
    public var jumpUsername: String?
    public var jumpPrivateKeyPath: String?
    public var jumpCredentialID: UUID?
    /// Keychain reference to the passphrase for `jumpPrivateKeyPath`.
    public var jumpKeyPassphraseID: UUID?

    // Presentation.
    public var notes: String?
    public var colorHex: String?
    public var isExpanded: Bool

    public var children: [ConnectionNode]

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        host: String? = nil,
        port: UInt16? = nil,
        username: String? = nil,
        protocolKind: ProtocolKind? = nil,
        privateKeyPath: String? = nil,
        credentialID: UUID? = nil,
        keyPassphraseID: UUID? = nil,
        jumpHost: String? = nil,
        jumpPort: UInt16? = nil,
        jumpUsername: String? = nil,
        jumpPrivateKeyPath: String? = nil,
        jumpCredentialID: UUID? = nil,
        jumpKeyPassphraseID: UUID? = nil,
        notes: String? = nil,
        colorHex: String? = nil,
        isExpanded: Bool = true,
        children: [ConnectionNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.protocolKind = protocolKind
        self.privateKeyPath = privateKeyPath
        self.credentialID = credentialID
        self.keyPassphraseID = keyPassphraseID
        self.jumpHost = jumpHost
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.jumpPrivateKeyPath = jumpPrivateKeyPath
        self.jumpCredentialID = jumpCredentialID
        self.jumpKeyPassphraseID = jumpKeyPassphraseID
        self.notes = notes
        self.colorHex = colorHex
        self.isExpanded = isExpanded
        self.children = children
    }

    public var isFolder: Bool { kind == .folder }

    /// Whether this node (ignoring inheritance) defines a jump host.
    public var definesJumpHost: Bool {
        if let jumpHost, !jumpHost.isEmpty { return true }
        return false
    }
}

/// The bastion a connection is tunnelled through.
public struct ResolvedJump: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var privateKeyPath: String?
    public var credentialID: UUID?
    /// Keychain reference to the passphrase for `privateKeyPath`.
    public var keyPassphraseID: UUID?

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        privateKeyPath: String? = nil,
        credentialID: UUID? = nil,
        keyPassphraseID: UUID? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyPath = privateKeyPath
        self.credentialID = credentialID
        self.keyPassphraseID = keyPassphraseID
    }
}

/// A connection with all inherited values resolved.
public struct ResolvedConnection: Equatable, Sendable {
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var protocolKind: ProtocolKind
    public var privateKeyPath: String?
    public var credentialID: UUID?
    /// Keychain reference to the passphrase for `privateKeyPath`.
    public var keyPassphraseID: UUID?
    /// Present when the connection should be tunnelled through a bastion.
    public var jump: ResolvedJump?

    public init(
        name: String,
        host: String,
        port: UInt16,
        username: String,
        protocolKind: ProtocolKind,
        privateKeyPath: String? = nil,
        credentialID: UUID? = nil,
        keyPassphraseID: UUID? = nil,
        jump: ResolvedJump? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.protocolKind = protocolKind
        self.privateKeyPath = privateKeyPath
        self.credentialID = credentialID
        self.keyPassphraseID = keyPassphraseID
        self.jump = jump
    }

    /// Short description of the route, e.g. `root@bastion → app`.
    public var routeDescription: String {
        guard let jump else { return "\(username)@\(host):\(port)" }
        return "\(jump.username)@\(jump.host) → \(username)@\(host):\(port)"
    }
}
