import Testing
import Foundation
@testable import ConnectionStore

@Suite("Connection tree")
struct ConnectionTreeTests {

    private func sampleTree() -> (tree: ConnectionTree, prod: UUID, web: UUID) {
        let web = ConnectionNode(kind: .connection, name: "web-01", host: "10.0.0.5")
        let prod = ConnectionNode(
            kind: .folder,
            name: "Production",
            port: 2222,
            username: "deploy",
            children: [web]
        )
        let staging = ConnectionNode(
            kind: .connection,
            name: "staging",
            host: "10.0.1.1",
            username: "root"
        )
        return (ConnectionTree(roots: [prod, staging]), prod.id, web.id)
    }

    @Test("inherits username, port and protocol from the parent folder")
    func inheritsFromFolder() throws {
        let (tree, _, web) = sampleTree()
        let resolved = try #require(tree.resolve(id: web))

        #expect(resolved.host == "10.0.0.5")
        #expect(resolved.username == "deploy", "username should come from the folder")
        #expect(resolved.port == 2222, "port should come from the folder")
        #expect(resolved.protocolKind == .ssh)
    }

    @Test("child values override the folder")
    func childOverridesFolder() throws {
        var (tree, _, web) = sampleTree()
        tree.update(id: web) { node in
            node.username = "webuser"
            node.port = 22
        }
        let resolved = try #require(tree.resolve(id: web))
        #expect(resolved.username == "webuser")
        #expect(resolved.port == 22)
    }

    @Test("port falls back to the protocol default")
    func defaultPort() throws {
        let node = ConnectionNode(kind: .connection, name: "rdp-box", host: "10.0.0.9", protocolKind: .rdp)
        let tree = ConnectionTree(roots: [node])
        let resolved = try #require(tree.resolve(id: node.id))
        #expect(resolved.port == 3389)
    }

    @Test("a connection without a host does not resolve")
    func missingHost() {
        let node = ConnectionNode(kind: .connection, name: "incomplete")
        let tree = ConnectionTree(roots: [node])
        #expect(tree.resolve(id: node.id) == nil)
    }

    @Test("folders are skipped by resolution")
    func folderDoesNotResolve() {
        let (tree, prod, _) = sampleTree()
        #expect(tree.resolve(id: prod) == nil)
    }

    @Test("insert and move restructure the tree")
    func insertAndMove() throws {
        var (tree, prod, web) = sampleTree()
        let grouped = ConnectionNode(kind: .folder, name: "Grouped")

        let insertedGroup = tree.insert(grouped, intoFolder: nil)
        let insertedChild = tree.insert(
            ConnectionNode(kind: .connection, name: "a", host: "h"),
            intoFolder: grouped.id
        )
        #expect(insertedGroup)
        #expect(insertedChild)

        // Move web-01 out of Production into Grouped.
        let moved = tree.move(id: web, toFolder: grouped.id)
        #expect(moved)
        #expect(tree.path(to: web)?.count == 2)
        #expect(tree.node(id: prod)?.children.isEmpty == true)
    }

    @Test("a node cannot be moved into its own subtree")
    func rejectsCyclicMove() {
        var (tree, prod, _) = sampleTree()
        let child = ConnectionNode(kind: .folder, name: "Nested")

        let inserted = tree.insert(child, intoFolder: prod)
        let moved = tree.move(id: prod, toFolder: child.id)

        #expect(inserted)
        #expect(moved == false)
        #expect(tree.path(to: prod)?.count == 1, "Production should still be a root")
    }

    @Test("removing a folder removes its contents")
    func removeFolder() {
        var (tree, prod, web) = sampleTree()
        let removed = tree.remove(id: prod)
        #expect(removed)
        #expect(tree.node(id: web) == nil)
        #expect(tree.roots.count == 1)
    }

    @Test("allConnections lists only connections")
    func listsConnections() {
        let (tree, _, _) = sampleTree()
        #expect(tree.allConnections().map(\.name).sorted() == ["staging", "web-01"])
    }
}

@Suite("Connection document store")
struct ConnectionDocumentStoreTests {
    @Test("saves and loads a tree")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("connstore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConnectionDocumentStore(url: directory.appendingPathComponent("connections.json"))
        let tree = ConnectionTree(roots: [
            ConnectionNode(kind: .folder, name: "Prod", children: [
                ConnectionNode(kind: .connection, name: "db", host: "10.0.0.2", port: 5432)
            ])
        ])

        try store.save(tree)
        let loaded = try store.load()

        #expect(loaded == tree)
        #expect(loaded.version == ConnectionTree.currentVersion)
    }

    @Test("a missing file loads as an empty tree")
    func missingFile() throws {
        let store = ConnectionDocumentStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        )
        let loaded = try store.load()
        #expect(loaded.isEmpty)
    }
}
