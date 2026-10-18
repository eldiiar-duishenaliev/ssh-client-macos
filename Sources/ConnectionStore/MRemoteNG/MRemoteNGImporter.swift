import Foundation
import CredentialKit

/// Errors raised while reading an mRemoteNG `confCons.xml`.
public enum MRemoteNGImportError: Error, LocalizedError, Equatable {
    case notXML
    case notMRemoteNGFile
    case malformed
    case passwordRequired
    case wrongPassword
    case unsupportedConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .notXML:
            return "The file is not valid XML."
        case .notMRemoteNGFile:
            return "The file is not an mRemoteNG connections file."
        case .malformed:
            return "The connections file is malformed."
        case .passwordRequired:
            return "This file is protected by a master password."
        case .wrongPassword:
            return "The master password is incorrect."
        case .unsupportedConfiguration(let detail):
            return "Unsupported mRemoteNG configuration: \(detail)"
        }
    }
}

/// Outcome of an import.
public struct MRemoteNGImportResult {
    public let tree: ConnectionTree
    /// Non-fatal problems encountered while reading the file.
    public let warnings: [String]
    /// How many passwords were moved into the secret store.
    public let importedCredentialCount: Int

    public init(tree: ConnectionTree, warnings: [String], importedCredentialCount: Int) {
        self.tree = tree
        self.warnings = warnings
        self.importedCredentialCount = importedCredentialCount
    }
}

/// Encryption settings declared on the root element.
struct MRemoteNGSettings {
    var engine: String = "AES"
    var mode: String? = "GCM"
    var iterations: Int = 1000
    var fullFileEncryption: Bool = false

    /// Files from 1.74 and earlier carry no `BlockCipherMode`.
    var isLegacyCBC: Bool { mode == nil }

    var isSupported: Bool {
        guard engine.uppercased() == "AES" else { return false }
        guard let mode else { return true } // legacy CBC
        return mode.uppercased() == "GCM"
    }

    var description: String {
        "engine=\(engine) mode=\(mode ?? "CBC") iterations=\(iterations)"
    }

    init() {}

    init(root: XMLElement) {
        if let engine = root.attribute(forName: "EncryptionEngine")?.stringValue, !engine.isEmpty {
            self.engine = engine
        }
        if let mode = root.attribute(forName: "BlockCipherMode")?.stringValue, !mode.isEmpty {
            self.mode = mode
        } else {
            self.mode = nil
        }
        if let value = root.attribute(forName: "KdfIterations")?.stringValue, let parsed = Int(value) {
            self.iterations = parsed
        }
        if let value = root.attribute(forName: "FullFileEncryption")?.stringValue {
            self.fullFileEncryption = value.caseInsensitiveCompare("true") == .orderedSame
        }
    }
}

/// Decrypts individual password blobs using the file's settings.
struct MRemoteNGPasswordCipher {
    let settings: MRemoteNGSettings
    let password: String

    func decrypt(base64: String) throws -> String {
        guard let blob = Data(base64Encoded: base64) else {
            throw MRemoteNGImportError.malformed
        }
        let plaintext = settings.isLegacyCBC ? try decryptLegacy(blob) : try decryptGCM(blob)
        guard let plaintext, let text = String(data: plaintext, encoding: .utf8) else {
            throw MRemoteNGImportError.wrongPassword
        }
        return text
    }

    /// `salt(16) || nonce(16) || ciphertext || tag(16)`, salt also as AAD.
    private func decryptGCM(_ blob: Data) throws -> Data? {
        guard blob.count >= 48 else { throw MRemoteNGImportError.malformed }
        let salt = blob.subdata(in: 0..<16)
        let nonce = blob.subdata(in: 16..<32)
        let tag = blob.subdata(in: (blob.count - 16)..<blob.count)
        let ciphertext = blob.subdata(in: 32..<(blob.count - 16))

        guard let key = MRemoteNGCrypto.pbkdf2SHA1(
            password: password,
            salt: salt,
            iterations: settings.iterations,
            keyLength: 32
        ) else {
            throw MRemoteNGImportError.malformed
        }

        return MRemoteNGCrypto.aesGCMDecrypt(key: key, iv: nonce, aad: salt, ciphertext: ciphertext, tag: tag)
    }

    /// Legacy: `iv(16) || ciphertext`, key is a single MD5 round of the password.
    private func decryptLegacy(_ blob: Data) throws -> Data? {
        guard blob.count > 16 else { throw MRemoteNGImportError.malformed }
        let iv = blob.subdata(in: 0..<16)
        let ciphertext = blob.subdata(in: 16..<blob.count)
        guard let key = MRemoteNGCrypto.md5(Data(password.utf8)) else {
            throw MRemoteNGImportError.malformed
        }
        return MRemoteNGCrypto.aesCBCDecrypt(key: key, iv: iv, ciphertext: ciphertext)
    }
}

/// Imports an mRemoteNG `confCons.xml` connection file into a `ConnectionTree`.
public final class MRemoteNGImporter {
    /// Default master password used when the file is not protected.
    public static let defaultPassword = "mR3m"

    private let secrets: SecretStoring?

    /// - Parameter secrets: where decrypted passwords are stored. When `nil`,
    ///   passwords are dropped and reported as a warning.
    public init(secrets: SecretStoring? = nil) {
        self.secrets = secrets
    }

    public func importTree(at url: URL, masterPassword: String? = nil) throws -> MRemoteNGImportResult {
        try importTree(data: try Data(contentsOf: url), masterPassword: masterPassword)
    }

    public func importTree(data: Data, masterPassword: String? = nil) throws -> MRemoteNGImportResult {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw MRemoteNGImportError.notXML
        }

        guard let root = document.rootElement(), root.name == "Connections" else {
            throw MRemoteNGImportError.notMRemoteNGFile
        }

        let settings = MRemoteNGSettings(root: root)
        guard settings.isSupported else {
            throw MRemoteNGImportError.unsupportedConfiguration(settings.description)
        }

        let password = try resolvePassword(root: root, settings: settings, masterPassword: masterPassword)
        let cipher = MRemoteNGPasswordCipher(settings: settings, password: password)

        // With full-file encryption the node tree lives inside the root text.
        var nodeParent = root
        if settings.fullFileEncryption {
            guard let payload = root.stringValue, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MRemoteNGImportError.malformed
            }
            let xml = try cipher.decrypt(base64: payload.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let innerData = xml.data(using: .utf8),
                  let innerDocument = try? XMLDocument(data: innerData, options: [.nodeLoadExternalEntitiesNever]),
                  let innerRoot = innerDocument.rootElement() else {
                throw MRemoteNGImportError.malformed
            }
            nodeParent = innerRoot
        }

        var warnings: [String] = []
        var credentials = 0
        var roots: [ConnectionNode] = []
        for element in nodeParent.elements(forName: "Node") {
            if let node = convert(element, cipher: cipher, warnings: &warnings, credentials: &credentials) {
                roots.append(node)
            }
        }

        return MRemoteNGImportResult(
            tree: ConnectionTree(roots: roots),
            warnings: warnings,
            importedCredentialCount: credentials
        )
    }

    // MARK: - Password discovery

    private func resolvePassword(
        root: XMLElement,
        settings: MRemoteNGSettings,
        masterPassword: String?
    ) throws -> String {
        var candidates: [String] = []
        if let masterPassword, !masterPassword.isEmpty { candidates.append(masterPassword) }
        if !candidates.contains(Self.defaultPassword) { candidates.append(Self.defaultPassword) }

        // The `Protected` attribute is a known plaintext, so it tells us which
        // password the file was encrypted with.
        guard let protected = root.attribute(forName: "Protected")?.stringValue, !protected.isEmpty else {
            return candidates.first ?? Self.defaultPassword
        }

        for candidate in candidates {
            let cipher = MRemoteNGPasswordCipher(settings: settings, password: candidate)
            if (try? cipher.decrypt(base64: protected)) != nil {
                return candidate
            }
        }

        throw masterPassword == nil ? MRemoteNGImportError.passwordRequired : MRemoteNGImportError.wrongPassword
    }

    // MARK: - Node conversion

    private func convert(
        _ element: XMLElement,
        cipher: MRemoteNGPasswordCipher,
        warnings: inout [String],
        credentials: inout Int
    ) -> ConnectionNode? {
        guard let name = element.attribute(forName: "Name")?.stringValue, !name.isEmpty else {
            return nil
        }

        let type = element.attribute(forName: "Type")?.stringValue ?? "Connection"
        let isFolder = type.caseInsensitiveCompare("Container") == .orderedSame

        let host = nonEmpty(element.attribute(forName: "Hostname")?.stringValue)
        let username = nonEmpty(element.attribute(forName: "Username")?.stringValue)
        let port = element.attribute(forName: "Port")?.stringValue.flatMap { UInt16($0) }
        let protocolKind = Self.mapProtocol(element.attribute(forName: "Protocol")?.stringValue)
        let notes = nonEmpty(element.attribute(forName: "Description")?.stringValue)

        var credentialID: UUID?
        if !isFolder, let encrypted = nonEmpty(element.attribute(forName: "Password")?.stringValue) {
            if let secrets {
                do {
                    let secret = try cipher.decrypt(base64: encrypted)
                    if !secret.isEmpty {
                        let id = UUID()
                        try secrets.setSecret(secret, for: id)
                        credentialID = id
                        credentials += 1
                    }
                } catch {
                    warnings.append("Could not decrypt the password for “\(name)”.")
                }
            } else if !warnings.contains(where: { $0.hasPrefix("Passwords were not imported") }) {
                warnings.append("Passwords were not imported because no secret store was provided.")
            }
        }

        var children: [ConnectionNode] = []
        for child in element.elements(forName: "Node") {
            if let node = convert(child, cipher: cipher, warnings: &warnings, credentials: &credentials) {
                children.append(node)
            }
        }

        return ConnectionNode(
            kind: isFolder ? .folder : .connection,
            name: name,
            host: host,
            port: port,
            username: username,
            protocolKind: protocolKind,
            credentialID: credentialID,
            notes: notes,
            children: children
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    private static func mapProtocol(_ value: String?) -> ProtocolKind? {
        guard let value else { return nil }
        switch value.uppercased() {
        case "SSH2", "SSH1", "SSH": return .ssh
        case "SFTP": return .sftp
        case "RDP": return .rdp
        case "VNC": return .vnc
        case "TELNET": return .telnet
        case "HTTP", "HTTPS": return .http
        case "RAW", "RAWSOCKET": return .raw
        default: return nil
        }
    }
}
