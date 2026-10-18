import Testing
import Foundation
@testable import SSHCore

@Suite("SSH helpers")
struct SSHHelperTests {
    @Test("SHA256 fingerprint matches the OpenSSH format")
    func fingerprintFormat() {
        // SHA-256 of an empty blob, base64 without padding.
        #expect(SSHSession.fingerprint(for: Data()) == "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    @Test("key algorithm name is parsed from the blob header")
    func keyAlgorithmName() {
        var blob = Data()
        let name = "ssh-ed25519"
        let length = UInt32(name.utf8.count)
        blob.append(UInt8((length >> 24) & 0xff))
        blob.append(UInt8((length >> 16) & 0xff))
        blob.append(UInt8((length >> 8) & 0xff))
        blob.append(UInt8(length & 0xff))
        blob.append(contentsOf: name.utf8)
        blob.append(contentsOf: [UInt8](repeating: 0, count: 32))

        #expect(SSHSession.keyAlgorithmName(for: blob) == "ssh-ed25519")
    }

    @Test("a truncated blob yields no algorithm name")
    func truncatedBlob() {
        #expect(SSHSession.keyAlgorithmName(for: Data([0x00, 0x00])) == nil)
    }
}
