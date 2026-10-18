import Testing
import Foundation
@testable import ConnectionStore

@Suite("Jump host inheritance")
struct JumpHostTests {

    /// Mirrors the usual layout: one bastion carried by a folder, with the
    /// direct connection deliberately outside it.
    private func bastionTree() -> (tree: ConnectionTree, direct: UUID, app: UUID, data: UUID) {
        let direct = ConnectionNode(
            kind: .connection,
            name: "bastion",
            host: "203.0.113.10",
            username: "root"
        )

        let app = ConnectionNode(kind: .connection, name: "app", host: "10.0.0.11")
        let data = ConnectionNode(kind: .connection, name: "data", host: "10.0.0.12")
        let internalFolder = ConnectionNode(
            kind: .folder,
            name: "via bastion",
            username: "root",
            jumpHost: "203.0.113.10",
            jumpUsername: "root",
            jumpPrivateKeyPath: "~/.ssh/bastion_key",
            children: [app, data]
        )

        return (ConnectionTree(roots: [direct, internalFolder]), direct.id, app.id, data.id)
    }

    @Test("a folder's jump host is inherited by its connections")
    func jumpIsInherited() throws {
        let (tree, _, app, _) = bastionTree()
        let resolved = try #require(tree.resolve(id: app))
        let jump = try #require(resolved.jump)

        #expect(jump.host == "203.0.113.10")
        #expect(jump.username == "root")
        #expect(jump.port == 22, "jump port defaults to 22")
        #expect(jump.privateKeyPath == "~/.ssh/bastion_key")
        #expect(resolved.host == "10.0.0.11")
        #expect(resolved.username == "root", "username also inherited from the folder")
    }

    @Test("a connection outside the folder has no jump")
    func directConnectionHasNoJump() throws {
        let (tree, direct, _, _) = bastionTree()
        let resolved = try #require(tree.resolve(id: direct))
        #expect(resolved.jump == nil)
        #expect(resolved.host == "203.0.113.10")
    }

    @Test("a jump user defaults to the connection's user")
    func jumpUserDefaultsToConnectionUser() throws {
        let node = ConnectionNode(
            kind: .connection,
            name: "target",
            host: "10.0.0.1",
            username: "deploy",
            jumpHost: "bastion.example.com"
        )
        let tree = ConnectionTree(roots: [node])
        let resolved = try #require(tree.resolve(id: node.id))
        let jump = try #require(resolved.jump)

        #expect(jump.username == "deploy")
        #expect(jump.host == "bastion.example.com")
    }

    @Test("a connection can override the inherited jump host")
    func connectionOverridesJump() throws {
        let (tree, _, app, _) = bastionTree()
        var mutable = tree
        mutable.update(id: app) { node in
            node.jumpHost = "other-bastion.example.com"
            node.jumpPort = 2200
        }

        let resolved = try #require(mutable.resolve(id: app))
        let jump = try #require(resolved.jump)
        #expect(jump.host == "other-bastion.example.com")
        #expect(jump.port == 2200)
    }

    @Test("route description reads as a hop")
    func routeDescription() throws {
        let (tree, _, app, _) = bastionTree()
        let resolved = try #require(tree.resolve(id: app))
        #expect(resolved.routeDescription == "root@203.0.113.10 → root@10.0.0.11:22")
    }

    @Test("a direct connection's route description contains no hop")
    func directConnectionRouteDescription() throws {
        let (tree, direct, _, _) = bastionTree()
        let resolved = try #require(tree.resolve(id: direct))
        #expect(resolved.username == "root")
        #expect(resolved.routeDescription == "root@203.0.113.10:22")
    }

    @Test("jump settings survive a save and load")
    func jumpRoundTrips() throws {
        let (tree, _, _, _) = bastionTree()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(ConnectionTree.self, from: data)
        #expect(decoded == tree)
    }
}
