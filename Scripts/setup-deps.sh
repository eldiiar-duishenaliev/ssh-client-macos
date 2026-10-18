#!/usr/bin/env bash
#
# Ensures the native dependencies the package links are present, and that the
# Clibssh2 modulemap and OPENSSL_PREFIX point at them.
#
# Run this after a fresh clone, and in CI before building.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew is required (https://brew.sh)" >&2
    exit 1
fi

if ! brew list --versions libssh2 >/dev/null 2>&1; then
    echo "==> Installing libssh2"
    brew install libssh2
fi

LIBSSH2_PREFIX="$(brew --prefix libssh2)"
echo "==> libssh2: $LIBSSH2_PREFIX"

# The modulemap must carry absolute header paths: a system-library target
# cannot inherit include flags from its dependents, so the paths have to be
# baked in.
MODULEMAP="$ROOT/Sources/Clibssh2/module.modulemap"
cat > "$MODULEMAP" <<EOF
module Clibssh2 [system] {
    header "$LIBSSH2_PREFIX/include/libssh2.h"
    header "$LIBSSH2_PREFIX/include/libssh2_sftp.h"
    export *
}
EOF

# Pin the OpenSSL that libssh2 was itself built against. The crypto shim links
# OpenSSL statically, and pulling in a different major version would put two
# copies of libcrypto in the process.
OPENSSL_PREFIX="$(otool -L "$LIBSSH2_PREFIX/lib/libssh2.dylib" 2>/dev/null \
    | grep -oE '/(opt/homebrew|usr/local)/opt/openssl@?[0-9]*' \
    | head -1 || true)"

if [[ -n "$OPENSSL_PREFIX" ]]; then
    echo "==> OpenSSL: $OPENSSL_PREFIX"
    export OPENSSL_PREFIX
    # Make it visible to later CI steps.
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "OPENSSL_PREFIX=$OPENSSL_PREFIX" >> "$GITHUB_ENV"
    fi
else
    echo "==> OpenSSL: not pinned, letting the package detect it"
fi
