import Foundation
import Security

/// Somewhere to keep connection secrets.
///
/// Implemented by the Keychain in the app, and by an in-memory double in
/// tests. Secrets are addressed by the `credentialID` stored on a connection,
/// so the connection tree itself never holds a password.
public protocol SecretStoring {
    func setSecret(_ secret: String, for id: UUID) throws
    func secret(for id: UUID) -> String?
    func removeSecret(for id: UUID) throws
}

public enum CredentialError: Error, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)\(message.map { ": \($0)" } ?? "")"
        }
    }
}

/// Stores secrets as generic password items in the login Keychain.
public final class KeychainSecretStore: SecretStoring {
    public static let defaultService = "com.eldiiar.sshclientmac.credentials"

    private let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func setSecret(_ secret: String, for id: UUID) throws {
        let query = baseQuery(for: id)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychain(status)
        }
    }

    public func secret(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func removeSecret(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }
}

/// In-memory store, used by tests and previews.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    public init() {}

    public func setSecret(_ secret: String, for id: UUID) throws {
        lock.lock(); storage[id] = secret; lock.unlock()
    }

    public func secret(for id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    public func removeSecret(for id: UUID) throws {
        lock.lock(); storage[id] = nil; lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }
}
