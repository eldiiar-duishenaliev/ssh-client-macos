import Testing
import Foundation
@testable import ConnectionStore

@Suite("Key passphrase references")
struct KeyPassphraseTests {

    @Test("a connection's passphrase reference resolves")
    func connectionPassphrase() throws {
        let passphraseID = UUID()
        let node = ConnectionNode(
            kind: .connection,
            name: "app",
            host: "10.0.0.11",
            privateKeyPath: "~/.ssh/id_ed25519",
            keyPassphraseID: passphraseID
        )
        let tree = ConnectionTree(roots: [node])
        let resolved = try #require(tree.resolve(id: node.id))

        #expect(resolved.keyPassphraseID == passphraseID)
        #expect(resolved.privateKeyPath == "~/.ssh/id_ed25519")
    }

    @Test("a jump key passphrase is inherited from the folder")
    func jumpPassphraseInherited() throws {
        let passphraseID = UUID()
        let app = ConnectionNode(kind: .connection, name: "app", host: "10.0.0.11")
        let folder = ConnectionNode(
            kind: .folder,
            name: "via bastion",
            username: "root",
            jumpHost: "203.0.113.10",
            jumpPrivateKeyPath: "~/.ssh/bastion_key",
            jumpKeyPassphraseID: passphraseID,
            children: [app]
        )

        let tree = ConnectionTree(roots: [folder])
        let resolved = try #require(tree.resolve(id: app.id))
        let jump = try #require(resolved.jump)

        #expect(jump.keyPassphraseID == passphraseID)
        #expect(jump.privateKeyPath == "~/.ssh/bastion_key")
    }

    @Test("the nearest passphrase reference wins")
    func nearestPassphraseWins() throws {
        let outer = UUID()
        let inner = UUID()

        let app = ConnectionNode(
            kind: .connection,
            name: "app",
            host: "10.0.0.11",
            keyPassphraseID: inner
        )
        let folder = ConnectionNode(
            kind: .folder,
            name: "prod",
            keyPassphraseID: outer,
            children: [app]
        )

        let tree = ConnectionTree(roots: [folder])
        let resolved = try #require(tree.resolve(id: app.id))
        #expect(resolved.keyPassphraseID == inner)
    }

    @Test("passphrase references survive a save and load, but carry no secret")
    func referenceRoundTrips() throws {
        let passphraseID = UUID()
        let node = ConnectionNode(
            kind: .connection,
            name: "app",
            host: "10.0.0.11",
            keyPassphraseID: passphraseID
        )
        let tree = ConnectionTree(roots: [node])

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(ConnectionTree.self, from: data)

        #expect(decoded == tree)

        // The file holds only a reference: no passphrase text anywhere.
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(passphraseID.uuidString))
        #expect(!text.lowercased().contains("passphrase\""))
    }
}
