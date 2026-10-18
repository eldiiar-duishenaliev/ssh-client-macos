import Foundation

/// The whole connection tree, with lookup and mutation helpers.
public struct ConnectionTree: Codable, Equatable, Sendable {
    /// Storage format version, so future migrations can be detected.
    public static let currentVersion = 1

    public var version: Int
    public var roots: [ConnectionNode]

    public init(version: Int = ConnectionTree.currentVersion, roots: [ConnectionNode] = []) {
        self.version = version
        self.roots = roots
    }

    public var isEmpty: Bool { roots.isEmpty }

    // MARK: - Lookup

    /// The node with the given id, if present.
    public func node(id: UUID) -> ConnectionNode? {
        Self.find(id, in: roots)
    }

    /// Ancestor chain from a root down to the node, inclusive.
    public func path(to id: UUID) -> [ConnectionNode]? {
        Self.path(id, in: roots, trail: [])
    }

    /// All connections (not folders) in the tree, depth first.
    public func allConnections() -> [ConnectionNode] {
        var result: [ConnectionNode] = []
        func walk(_ nodes: [ConnectionNode]) {
            for node in nodes {
                if node.kind == .connection { result.append(node) }
                walk(node.children)
            }
        }
        walk(roots)
        return result
    }

    // MARK: - Inheritance

    /// Applies folder inheritance to produce a ready-to-connect value.
    public func resolve(id: UUID) -> ResolvedConnection? {
        guard let path = path(to: id), let leaf = path.last, leaf.kind == .connection else {
            return nil
        }

        var host: String?
        var port: UInt16?
        var username: String?
        var protocolKind: ProtocolKind?
        var privateKeyPath: String?
        var credentialID: UUID?
        var keyPassphraseID: UUID?
        var jumpHost: String?
        var jumpPort: UInt16?
        var jumpUsername: String?
        var jumpPrivateKeyPath: String?
        var jumpCredentialID: UUID?
        var jumpKeyPassphraseID: UUID?

        for node in path {
            if let value = node.host, !value.isEmpty { host = value }
            if let value = node.port { port = value }
            if let value = node.username, !value.isEmpty { username = value }
            if let value = node.protocolKind { protocolKind = value }
            if let value = node.privateKeyPath, !value.isEmpty { privateKeyPath = value }
            if let value = node.credentialID { credentialID = value }
            if let value = node.keyPassphraseID { keyPassphraseID = value }
            if let value = node.jumpHost, !value.isEmpty { jumpHost = value }
            if let value = node.jumpPort { jumpPort = value }
            if let value = node.jumpUsername, !value.isEmpty { jumpUsername = value }
            if let value = node.jumpPrivateKeyPath, !value.isEmpty { jumpPrivateKeyPath = value }
            if let value = node.jumpCredentialID { jumpCredentialID = value }
            if let value = node.jumpKeyPassphraseID { jumpKeyPassphraseID = value }
        }

        guard let host, !host.isEmpty else { return nil }
        let resolvedProtocol = protocolKind ?? .ssh
        let resolvedUsername = username ?? NSUserName()

        // A jump host defaults its user to the connection's user and its port
        // to 22, which matches the common `-J user@bastion` case.
        var jump: ResolvedJump?
        if let jumpHost, !jumpHost.isEmpty {
            jump = ResolvedJump(
                host: jumpHost,
                port: jumpPort ?? 22,
                username: jumpUsername ?? resolvedUsername,
                privateKeyPath: jumpPrivateKeyPath,
                credentialID: jumpCredentialID,
                keyPassphraseID: jumpKeyPassphraseID
            )
        }

        return ResolvedConnection(
            name: leaf.name,
            host: host,
            port: port ?? resolvedProtocol.defaultPort,
            username: resolvedUsername,
            protocolKind: resolvedProtocol,
            privateKeyPath: privateKeyPath,
            credentialID: credentialID,
            keyPassphraseID: keyPassphraseID,
            jump: jump
        )
    }

    // MARK: - Mutation

    @discardableResult
    public mutating func insert(_ node: ConnectionNode, intoFolder parentID: UUID?) -> Bool {
        guard let parentID else {
            roots.append(node)
            return true
        }
        return Self.withNode(parentID, in: &roots) { parent in
            guard parent.kind == .folder else { return false }
            parent.children.append(node)
            return true
        } ?? false
    }

    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        if Self.removeFrom(&roots, id: id) { return true }
        return false
    }

    /// Replaces a node in place, keeping its position and children.
    @discardableResult
    public mutating func update(id: UUID, _ transform: (inout ConnectionNode) -> Void) -> Bool {
        Self.withNode(id, in: &roots) { node in
            transform(&node)
            return true
        } ?? false
    }

    /// Moves a node under a new parent (`nil` = root). Refuses to move a node
    /// into itself or one of its descendants.
    @discardableResult
    public mutating func move(id: UUID, toFolder parentID: UUID?) -> Bool {
        guard let node = node(id: id) else { return false }
        if let parentID {
            guard parentID != id else { return false }
            // Reject moving a node into its own subtree.
            if Self.find(parentID, in: node.children) != nil { return false }
        }
        guard remove(id: id) else { return false }
        return insert(node, intoFolder: parentID)
    }

    // MARK: - Recursive helpers

    /// Returns a copy of the tree with fresh node identifiers.
    ///
    /// Used when merging an imported tree so its ids cannot collide with
    /// existing nodes. `credentialID` values are deliberately preserved, since
    /// they point at Keychain items.
    public func regeneratedIDs() -> ConnectionTree {
        func convert(_ node: ConnectionNode) -> ConnectionNode {
            var copy = node
            copy.id = UUID()
            copy.children = node.children.map(convert)
            return copy
        }
        return ConnectionTree(version: version, roots: roots.map(convert))
    }

    private static func find(_ id: UUID, in nodes: [ConnectionNode]) -> ConnectionNode? {
        for node in nodes {
            if node.id == id { return node }
            if let match = find(id, in: node.children) { return match }
        }
        return nil
    }

    private static func path(_ id: UUID, in nodes: [ConnectionNode], trail: [ConnectionNode]) -> [ConnectionNode]? {
        for node in nodes {
            let next = trail + [node]
            if node.id == id { return next }
            if let match = path(id, in: node.children, trail: next) { return match }
        }
        return nil
    }

    private static func withNode(
        _ id: UUID,
        in nodes: inout [ConnectionNode],
        _ transform: (inout ConnectionNode) -> Bool
    ) -> Bool? {
        for index in nodes.indices {
            if nodes[index].id == id {
                return transform(&nodes[index])
            }
            if let result = withNode(id, in: &nodes[index].children, transform) {
                return result
            }
        }
        return nil
    }

    private static func removeFrom(_ nodes: inout [ConnectionNode], id: UUID) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                nodes.remove(at: index)
                return true
            }
            if removeFrom(&nodes[index].children, id: id) { return true }
        }
        return false
    }
}
