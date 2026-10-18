import Foundation
import CryptoKit
import Clibssh2

/// Verifies a server's host key against an OpenSSH `known_hosts` file.
enum HostKeyVerifier {
    /// Resolves the `known_hosts` path, defaulting to `~/.ssh/known_hosts`.
    static func resolvedKnownHostsPath(_ explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".ssh/known_hosts")
    }

    /// Checks the host key, asking `decide` when it is not a known match.
    ///
    /// Throws `SSHError.hostKeyRejected` when the caller rejects the key.
    static func verify(
        session: OpaquePointer,
        host: String,
        port: UInt16,
        knownHostsPath: String?,
        decide: (HostKeyInfo) -> HostKeyDecision
    ) throws {
        var keyLength = 0
        var keyType: Int32 = 0
        guard let keyPointer = libssh2_session_hostkey(session, &keyLength, &keyType) else {
            throw SSHError.handshake("the server did not present a host key")
        }

        let blob = Data(bytes: keyPointer, count: keyLength)
        let keyName = keyAlgorithmName(for: blob) ?? "unknown"
        let fingerprint = fingerprint(for: blob)
        let path = resolvedKnownHostsPath(knownHostsPath)
        let status = check(session: session, host: host, port: port, blob: blob, path: path)

        if status == .match { return }

        let info = HostKeyInfo(
            host: host,
            port: port,
            keyType: keyName,
            fingerprint: fingerprint,
            status: status
        )

        switch decide(info) {
        case .reject:
            throw SSHError.hostKeyRejected
        case .accept:
            return
        case .acceptAndSave:
            try save(blob: blob, keyName: keyName, host: host, port: port, path: path)
        }
    }

    // MARK: - known_hosts

    private static func check(
        session: OpaquePointer,
        host: String,
        port: UInt16,
        blob: Data,
        path: String?
    ) -> HostKeyStatus {
        guard let hosts = libssh2_knownhost_init(session) else { return .failure }
        defer { libssh2_knownhost_free(hosts) }

        if let path, !path.isEmpty {
            path.withCString { pointer in
                _ = libssh2_knownhost_readfile(hosts, pointer, LIBSSH2_KNOWNHOST_FILE_OPENSSH)
            }
        }

        var entry: UnsafeMutablePointer<libssh2_knownhost>?
        let result = host.withCString { hostPointer in
            blob.withUnsafeBytes { raw -> Int32 in
                libssh2_knownhost_checkp(
                    hosts,
                    hostPointer,
                    Int32(port),
                    raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                    raw.count,
                    LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW,
                    &entry
                )
            }
        }

        switch result {
        case LIBSSH2_KNOWNHOST_CHECK_MATCH: return .match
        case LIBSSH2_KNOWNHOST_CHECK_MISMATCH: return .mismatch
        case LIBSSH2_KNOWNHOST_CHECK_NOTFOUND: return .notFound
        default: return .failure
        }
    }

    private static func save(
        blob: Data,
        keyName: String,
        host: String,
        port: UInt16,
        path: String?
    ) throws {
        guard let path, !path.isEmpty else { return }

        let hostField = port == 22 ? host : "[\(host)]:\(port)"
        let line = "\(hostField) \(keyName) \(blob.base64EncodedString())\n"

        let fileManager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: URL(fileURLWithPath: path))
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    // MARK: - Fingerprints

    /// OpenSSH-style `SHA256:...` fingerprint of a public key blob.
    static func fingerprint(for blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let encoded = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    /// Reads the algorithm name (e.g. `ssh-ed25519`) from a key blob.
    static func keyAlgorithmName(for blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let length = blob.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        let end = 4 + Int(length)
        guard end <= blob.count else { return nil }
        return String(data: blob.subdata(in: 4..<end), encoding: .utf8)
    }
}
