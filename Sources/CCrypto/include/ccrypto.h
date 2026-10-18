#ifndef CCRYPTO_H
#define CCRYPTO_H

#include <stddef.h>

/*
 * Small C shim over OpenSSL for the primitives the mRemoteNG importer needs.
 *
 * The header deliberately exposes no OpenSSL types so that Swift can import
 * this module without needing OpenSSL's headers on the search path.
 */

/// PBKDF2-HMAC-SHA1. Returns 0 on success.
int ccrypto_pbkdf2_sha1(const char *password, size_t passwordLen,
                        const unsigned char *salt, size_t saltLen,
                        int iterations,
                        unsigned char *out, size_t outLen);

/// MD5 digest of `input` into `out` (16 bytes). Returns 0 on success.
/// Used only for the legacy mRemoteNG (<= 1.74) key derivation.
int ccrypto_md5(const unsigned char *input, size_t inputLen,
                unsigned char *out);

/*
 * AES-GCM decryption with an arbitrary IV length.
 *
 * `out` must have room for `ciphertextLen` bytes. Returns 0 when the tag
 * verifies, non-zero otherwise.
 */
int ccrypto_aes_gcm_decrypt(const unsigned char *key, size_t keyLen,
                            const unsigned char *iv, size_t ivLen,
                            const unsigned char *aad, size_t aadLen,
                            const unsigned char *ciphertext, size_t ciphertextLen,
                            const unsigned char *tag, size_t tagLen,
                            unsigned char *out);

/// AES-CBC decryption (PKCS#7 padding), for legacy mRemoteNG files.
int ccrypto_aes_cbc_decrypt(const unsigned char *key, size_t keyLen,
                            const unsigned char *iv, size_t ivLen,
                            const unsigned char *ciphertext, size_t ciphertextLen,
                            unsigned char *out, size_t *outLen);

#endif /* CCRYPTO_H */
