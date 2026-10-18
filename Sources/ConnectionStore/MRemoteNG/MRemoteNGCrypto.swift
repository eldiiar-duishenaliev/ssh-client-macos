import Foundation
import CCrypto

/// The cryptographic primitives mRemoteNG uses for stored passwords.
///
/// mRemoteNG 1.75+ uses PBKDF2-HMAC-SHA1 plus AES-GCM; the blob layout is
/// `salt(16) || nonce(16) || ciphertext || tag(16)` and the salt doubles as the
/// GCM associated data. Files from 1.74 and earlier use a single MD5 round as
/// the key with AES-CBC and an `iv(16) || ciphertext` layout.
enum MRemoteNGCrypto {

    // MARK: - Key derivation

    static func pbkdf2SHA1(password: String, salt: Data, iterations: Int, keyLength: Int = 32) -> Data? {
        var passwordBytes = [UInt8](password.utf8)
        if passwordBytes.isEmpty { passwordBytes = [0] }

        var output = Data(count: keyLength)
        let status: Int32 = output.withUnsafeMutableBytes { outBuffer -> Int32 in
            salt.withUnsafeBytes { saltBuffer -> Int32 in
                passwordBytes.withUnsafeBufferPointer { passwordBuffer -> Int32 in
                    ccrypto_pbkdf2_sha1(
                        UnsafeRawPointer(passwordBuffer.baseAddress!).assumingMemoryBound(to: CChar.self),
                        passwordBuffer.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        Int32(iterations),
                        outBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return status == 0 ? output : nil
    }

    static func md5(_ data: Data) -> Data? {
        var output = Data(count: 16)
        let status: Int32 = output.withUnsafeMutableBytes { outBuffer -> Int32 in
            data.withUnsafeBytes { inputBuffer -> Int32 in
                ccrypto_md5(
                    inputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    outBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        return status == 0 ? output : nil
    }

    // MARK: - Ciphers

    static func aesGCMDecrypt(key: Data, iv: Data, aad: Data, ciphertext: Data, tag: Data) -> Data? {
        var output = Data(count: max(ciphertext.count, 1))
        let status: Int32 = output.withUnsafeMutableBytes { outBuffer -> Int32 in
            key.withUnsafeBytes { keyBuffer -> Int32 in
                iv.withUnsafeBytes { ivBuffer -> Int32 in
                    aad.withUnsafeBytes { aadBuffer -> Int32 in
                        ciphertext.withUnsafeBytes { ciphertextBuffer -> Int32 in
                            tag.withUnsafeBytes { tagBuffer -> Int32 in
                                ccrypto_aes_gcm_decrypt(
                                    keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), key.count,
                                    ivBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), iv.count,
                                    aadBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), aad.count,
                                    ciphertextBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), ciphertext.count,
                                    tagBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), tag.count,
                                    outBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                                )
                            }
                        }
                    }
                }
            }
        }
        guard status == 0 else { return nil }
        return output.prefix(ciphertext.count)
    }

    static func aesCBCDecrypt(key: Data, iv: Data, ciphertext: Data) -> Data? {
        var output = Data(count: max(ciphertext.count, 16))
        var written = 0
        let status: Int32 = output.withUnsafeMutableBytes { outBuffer -> Int32 in
            key.withUnsafeBytes { keyBuffer -> Int32 in
                iv.withUnsafeBytes { ivBuffer -> Int32 in
                    ciphertext.withUnsafeBytes { ciphertextBuffer -> Int32 in
                        ccrypto_aes_cbc_decrypt(
                            keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), key.count,
                            ivBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), iv.count,
                            ciphertextBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), ciphertext.count,
                            outBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            &written
                        )
                    }
                }
            }
        }
        guard status == 0 else { return nil }
        return output.prefix(written)
    }
}
