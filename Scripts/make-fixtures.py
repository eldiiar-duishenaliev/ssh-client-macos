#!/usr/bin/env python3
"""Generate mRemoteNG `confCons.xml` fixtures for the importer tests.

This is an independent implementation of the documented mRemoteNG scheme,
written against OpenSSL via the `cryptography` package rather than the app's
own code, so the fixtures are a genuine cross-check.

  1.75+  PBKDF2-HMAC-SHA1 + AES-GCM
         blob = salt(16) || nonce(16) || ciphertext || tag(16), AAD = salt
  1.74-  MD5(password) as key + AES-CBC
         blob = iv(16) || ciphertext

Usage:  python3 Scripts/make-fixtures.py <output-directory>
"""

import base64
import hashlib
import os
import sys

from cryptography.hazmat.primitives import hashes, padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

ITERATIONS = 1000


def gcm_encrypt(password: str, plaintext: str, iterations: int = ITERATIONS) -> str:
    salt = os.urandom(16)
    nonce = os.urandom(16)
    key = PBKDF2HMAC(
        algorithm=hashes.SHA1(), length=32, salt=salt, iterations=iterations
    ).derive(password.encode())
    ciphertext_and_tag = AESGCM(key).encrypt(nonce, plaintext.encode(), salt)
    return base64.b64encode(salt + nonce + ciphertext_and_tag).decode()


def cbc_encrypt(password: str, plaintext: str) -> str:
    key = hashlib.md5(password.encode()).digest()
    iv = os.urandom(16)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plaintext.encode()) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    ciphertext = encryptor.update(padded) + encryptor.finalize()
    return base64.b64encode(iv + ciphertext).decode()


NODES_GCM = [
    ("Production", "Container", None, "deploy", "2222", "SSH2", "prod hosts"),
    ("web-01", "Connection", "10.0.0.5", "deploy", "2222", "SSH2", None),
    ("db-01", "Connection", "10.0.0.6", "dbadmin", None, "SSH2", None),
    ("legacy-box", "Connection", "10.0.9.9", "root", None, "RDP", None),
]


def node_xml(name, kind, hostname, username, port, protocol, description, password=None, indent=2):
    pad = " " * indent
    attributes = [f'Name="{name}"', f'Type="{kind}"']
    if hostname:
        attributes.append(f'Hostname="{hostname}"')
    if username:
        attributes.append(f'Username="{username}"')
    if password:
        attributes.append(f'Password="{password}"')
    attributes.append(f'Protocol="{protocol}"')
    if port:
        attributes.append(f'Port="{port}"')
    if description:
        attributes.append(f'Description="{description}"')
    return f"{pad}<Node {' '.join(attributes)} />"


def gcm_document(custom_password=None):
    password = custom_password or "mR3m"
    protected_plain = "ThisIsProtected" if custom_password else "ThisIsNotProtected"
    protected = gcm_encrypt(password, protected_plain)

    webs = node_xml(*NODES_GCM[1], password=gcm_encrypt(password, "s3cr3t"))
    dbs = node_xml(*NODES_GCM[2], password=gcm_encrypt(password, "pässwörd"))
    folder = NODES_GCM[0]
    legacy = node_xml(*NODES_GCM[3], password=gcm_encrypt(password, "topsecret"))

    return "\n".join([
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<Connections Name="Connections" Export="False" EncryptionEngine="AES" '
        f'BlockCipherMode="GCM" KdfIterations="{ITERATIONS}" FullFileEncryption="False" '
        f'Protected="{protected}" ConfVersion="2.6">',
        f'  <Node Name="Production" Type="Container" Protocol="SSH2" Username="deploy" '
        f'Port="2222" Description="prod hosts">',
        webs,
        dbs,
        '  </Node>',
        legacy,
        '</Connections>',
        '',
    ])


def legacy_document():
    webs = node_xml(*NODES_GCM[1], password=cbc_encrypt("mR3m", "legacy-secret"))
    return "\n".join([
        '<?xml version="1.0" encoding="utf-8"?>',
        '<Connections Name="Connections" Export="False" EncryptionEngine="AES" '
        'FullFileEncryption="False" ConfVersion="2.5">',
        webs,
        '</Connections>',
        '',
    ])


def full_file_document():
    password = "mR3m"
    inner = gcm_document()
    # Strip the XML declaration; the inner document is the node tree.
    inner = inner.split("\n", 1)[1]
    encrypted = gcm_encrypt(password, inner)
    protected = gcm_encrypt(password, "ThisIsNotProtected")
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<Connections Name="Connections" Export="False" EncryptionEngine="AES" '
        f'BlockCipherMode="GCM" KdfIterations="{ITERATIONS}" FullFileEncryption="True" '
        f'Protected="{protected}" ConfVersion="2.6">{encrypted}</Connections>\n'
    )


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    output = sys.argv[1]
    os.makedirs(output, exist_ok=True)

    files = {
        "confCons-gcm.xml": gcm_document(),
        "confCons-gcm-protected.xml": gcm_document(custom_password="CorpMaster2026"),
        "confCons-legacy-cbc.xml": legacy_document(),
        "confCons-fullfile.xml": full_file_document(),
    }
    for name, content in files.items():
        path = os.path.join(output, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
