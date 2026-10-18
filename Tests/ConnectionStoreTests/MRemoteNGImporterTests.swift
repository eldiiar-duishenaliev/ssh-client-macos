import Testing
import Foundation
import CredentialKit
@testable import ConnectionStore

@Suite("mRemoteNG importer")
struct MRemoteNGImporterTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures")
        return try #require(url, "missing fixture \(name).xml")
    }

    private func connection(named name: String, in tree: ConnectionTree) -> ConnectionNode? {
        tree.allConnections().first { $0.name == name }
    }

    @Test("imports a modern (GCM) file with the default password")
    func importsGCM() throws {
        let secrets = InMemorySecretStore()
        let importer = MRemoteNGImporter(secrets: secrets)
        let result = try importer.importTree(at: try fixture("confCons-gcm"))

        #expect(result.warnings.isEmpty)
        #expect(result.importedCredentialCount == 3, "three nodes carry passwords")

        // Folder structure survives.
        let folder = result.tree.roots.first { $0.name == "Production" }
        #expect(folder?.isFolder == true)
        #expect(folder?.children.count == 2)

        // A connection inherits the folder's port.
        let db = try #require(connection(named: "db-01", in: result.tree))
        let resolvedDB = try #require(result.tree.resolve(id: db.id))
        #expect(resolvedDB.port == 2222, "port should be inherited from the folder")
        #expect(resolvedDB.username == "dbadmin", "own username wins")
        #expect(resolvedDB.host == "10.0.0.6")

        // Passwords moved into the secret store and are decryptable.
        let web = try #require(connection(named: "web-01", in: result.tree))
        let webCredential = try #require(web.credentialID)
        #expect(secrets.secret(for: webCredential) == "s3cr3t")

        let dbCredential = try #require(db.credentialID)
        #expect(secrets.secret(for: dbCredential) == "pässwörd", "UTF-8 passwords round-trip")

        // Protocol mapping and the protocol default port.
        let rdp = try #require(connection(named: "legacy-box", in: result.tree))
        let resolvedRDP = try #require(result.tree.resolve(id: rdp.id))
        #expect(resolvedRDP.protocolKind == .rdp)
        #expect(resolvedRDP.port == 3389)
    }

    @Test("a protected file requires its master password")
    func protectedFile() throws {
        let url = try fixture("confCons-gcm-protected")

        let withoutPassword = MRemoteNGImporter(secrets: InMemorySecretStore())
        #expect(throws: MRemoteNGImportError.passwordRequired) {
            _ = try withoutPassword.importTree(at: url)
        }

        let wrongPassword = MRemoteNGImporter(secrets: InMemorySecretStore())
        #expect(throws: MRemoteNGImportError.wrongPassword) {
            _ = try wrongPassword.importTree(at: url, masterPassword: "not-the-password")
        }

        let secrets = InMemorySecretStore()
        let importer = MRemoteNGImporter(secrets: secrets)
        let result = try importer.importTree(at: url, masterPassword: "CorpMaster2026")

        let web = try #require(connection(named: "web-01", in: result.tree))
        let credential = try #require(web.credentialID)
        #expect(secrets.secret(for: credential) == "s3cr3t")
    }

    @Test("imports a legacy (CBC) file")
    func importsLegacy() throws {
        let secrets = InMemorySecretStore()
        let importer = MRemoteNGImporter(secrets: secrets)
        let result = try importer.importTree(at: try fixture("confCons-legacy-cbc"))

        #expect(result.importedCredentialCount == 1)
        let web = try #require(connection(named: "web-01", in: result.tree))
        let credential = try #require(web.credentialID)
        #expect(secrets.secret(for: credential) == "legacy-secret")
    }

    @Test("imports a fully encrypted file")
    func importsFullFileEncryption() throws {
        let secrets = InMemorySecretStore()
        let importer = MRemoteNGImporter(secrets: secrets)
        let result = try importer.importTree(at: try fixture("confCons-fullfile"))

        #expect(result.tree.roots.count == 2)
        let web = try #require(connection(named: "web-01", in: result.tree))
        let credential = try #require(web.credentialID)
        #expect(secrets.secret(for: credential) == "s3cr3t")
    }

    @Test("without a secret store, passwords are skipped with a warning")
    func noSecretStore() throws {
        let importer = MRemoteNGImporter(secrets: nil)
        let result = try importer.importTree(at: try fixture("confCons-gcm"))

        #expect(result.importedCredentialCount == 0)
        #expect(result.warnings.contains { $0.hasPrefix("Passwords were not imported") })
        // Structure still imports.
        #expect(result.tree.allConnections().count == 3)
    }

    @Test("rejects unsupported ciphers")
    func unsupportedCipher() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <Connections Name="Connections" EncryptionEngine="Serpent" BlockCipherMode="GCM" ConfVersion="2.6" />
        """
        let importer = MRemoteNGImporter(secrets: nil)
        #expect(throws: MRemoteNGImportError.self) {
            _ = try importer.importTree(data: Data(xml.utf8))
        }
    }

    @Test("rejects files that are not mRemoteNG connections")
    func rejectsForeignXML() {
        let importer = MRemoteNGImporter(secrets: nil)
        #expect(throws: MRemoteNGImportError.notMRemoteNGFile) {
            _ = try importer.importTree(data: Data("<other/>".utf8))
        }
        #expect(throws: MRemoteNGImportError.notXML) {
            _ = try importer.importTree(data: Data("not xml at all".utf8))
        }
    }
}
