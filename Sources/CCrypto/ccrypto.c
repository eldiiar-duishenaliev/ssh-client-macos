#include "ccrypto.h"

#include <openssl/evp.h>
#include <string.h>

int ccrypto_pbkdf2_sha1(const char *password, size_t passwordLen,
                        const unsigned char *salt, size_t saltLen,
                        int iterations,
                        unsigned char *out, size_t outLen)
{
    if (PKCS5_PBKDF2_HMAC(password, (int)passwordLen,
                          salt, (int)saltLen,
                          iterations, EVP_sha1(),
                          (int)outLen, out) != 1) {
        return 1;
    }
    return 0;
}

int ccrypto_md5(const unsigned char *input, size_t inputLen, unsigned char *out)
{
    unsigned int length = 0;
    if (EVP_Digest(input, inputLen, out, &length, EVP_md5(), NULL) != 1) {
        return 1;
    }
    return length == 16 ? 0 : 2;
}

static const EVP_CIPHER *cipher_for_key_length(size_t keyLen)
{
    switch (keyLen) {
        case 16: return EVP_aes_128_gcm();
        case 24: return EVP_aes_192_gcm();
        case 32: return EVP_aes_256_gcm();
        default: return NULL;
    }
}

int ccrypto_aes_gcm_decrypt(const unsigned char *key, size_t keyLen,
                            const unsigned char *iv, size_t ivLen,
                            const unsigned char *aad, size_t aadLen,
                            const unsigned char *ciphertext, size_t ciphertextLen,
                            const unsigned char *tag, size_t tagLen,
                            unsigned char *out)
{
    const EVP_CIPHER *cipher = cipher_for_key_length(keyLen);
    if (cipher == NULL) {
        return 2;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx == NULL) {
        return 3;
    }

    int ok = 0;
    int written = 0;
    int total = 0;

    do {
        if (EVP_DecryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1) break;
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)ivLen, NULL) != 1) break;
        if (EVP_DecryptInit_ex(ctx, NULL, NULL, key, iv) != 1) break;

        if (aadLen > 0) {
            if (EVP_DecryptUpdate(ctx, NULL, &written, aad, (int)aadLen) != 1) break;
        }

        if (ciphertextLen > 0) {
            if (EVP_DecryptUpdate(ctx, out, &written, ciphertext, (int)ciphertextLen) != 1) break;
            total = written;
        }

        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, (int)tagLen, (void *)tag) != 1) break;

        if (EVP_DecryptFinal_ex(ctx, out + total, &written) != 1) break;
        total += written;
        ok = 1;
    } while (0);

    EVP_CIPHER_CTX_free(ctx);
    return ok ? 0 : 4;
}

int ccrypto_aes_cbc_decrypt(const unsigned char *key, size_t keyLen,
                            const unsigned char *iv, size_t ivLen,
                            const unsigned char *ciphertext, size_t ciphertextLen,
                            unsigned char *out, size_t *outLen)
{
    const EVP_CIPHER *cipher = NULL;
    switch (keyLen) {
        case 16: cipher = EVP_aes_128_cbc(); break;
        case 24: cipher = EVP_aes_192_cbc(); break;
        case 32: cipher = EVP_aes_256_cbc(); break;
        default: return 2;
    }
    if (ivLen != 16) {
        return 3;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx == NULL) {
        return 4;
    }

    int ok = 0;
    int written = 0;
    int total = 0;

    do {
        if (EVP_DecryptInit_ex(ctx, cipher, NULL, key, iv) != 1) break;
        if (EVP_DecryptUpdate(ctx, out, &written, ciphertext, (int)ciphertextLen) != 1) break;
        total = written;
        if (EVP_DecryptFinal_ex(ctx, out + total, &written) != 1) break;
        total += written;
        ok = 1;
    } while (0);

    EVP_CIPHER_CTX_free(ctx);
    if (!ok) return 5;
    if (outLen) *outLen = (size_t)total;
    return 0;
}
