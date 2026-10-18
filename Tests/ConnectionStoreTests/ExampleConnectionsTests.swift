import Testing
import Foundation
@testable import ConnectionStore

/// Guards the shipped example file, which describes a jump-host setup.
@Suite("Example connections file")
struct ExampleConnectionsTests {

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/ConnectionStoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
    }

    @Test("Examples/jump-host.json decodes and resolves as documented")
    func jumpHostExample() throws {
        let url = packageRoot.appendingPathComponent("Examples/jump-host.json")
        let tree = try JSONDecoder().decode(ConnectionTree.self, from: Data(contentsOf: url))
        let connections = tree.allConnections()

        #expect(connections.count == 4, "four saved connections")

        // The bastion itself is reached directly.
        let bastion = try #require(connections.first { $0.name == "bastion" })
        let resolvedBastion = try #require(tree.resolve(id: bastion.id))
        #expect(resolvedBastion.host == "203.0.113.10")
        #expect(resolvedBastion.username == "root")
        #expect(resolvedBastion.jump == nil, "the bastion must not be tunnelled")
        #expect(resolvedBastion.privateKeyPath == "~/.ssh/bastion_key")

        // The internal hosts are tunnelled through the bastion.
        let expected = [
            "app": "10.0.0.11",
            "data": "10.0.0.12",
            "identity": "10.0.0.13"
        ]

        for (name, host) in expected {
            let node = try #require(connections.first { $0.name == name })
            let resolved = try #require(tree.resolve(id: node.id))

            #expect(resolved.host == host)
            #expect(resolved.username == "root")
            #expect(resolved.privateKeyPath == "~/.ssh/bastion_key")

            let jump = try #require(resolved.jump, "\(name) should be tunnelled")
            #expect(jump.host == "203.0.113.10")
            #expect(jump.username == "root")
            #expect(jump.privateKeyPath == "~/.ssh/bastion_key")

            #expect(resolved.routeDescription.contains("→"), "route should show the hop")
        }
    }

    @Test("regenerating ids preserves structure but changes identifiers")
    func regeneratedIDs() throws {
        let url = packageRoot.appendingPathComponent("Examples/jump-host.json")
        let tree = try JSONDecoder().decode(ConnectionTree.self, from: Data(contentsOf: url))

        let copy = tree.regeneratedIDs()

        #expect(copy.allConnections().count == tree.allConnections().count)
        #expect(copy.roots.first?.name == tree.roots.first?.name)
        #expect(copy.roots.first?.id != tree.roots.first?.id, "ids should be fresh")
        #expect(copy.allConnections().allSatisfy { node in
            tree.allConnections().allSatisfy { $0.id != node.id }
        }, "no id should be reused")
    }
}
