#!/usr/bin/env bash
#
# Runs the test suite.
#
# On a Command Line Tools-only install, SwiftPM does not add the Swift Testing
# macro plugin search path, so `#expect`/`@Test` fail to resolve. When that
# plugin directory exists we point the compiler at it explicitly. Under a full
# Xcode install this is unnecessary and the flag is skipped.
#
# Deliberately avoids arrays: macOS ships bash 3.2, where expanding an empty
# array under `set -u` is an unbound-variable error.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEV_DIR="$(xcode-select -p)"
PLUGIN_DIR="$DEV_DIR/usr/lib/swift/host/plugins/testing"
PLUGIN_SERVER="$DEV_DIR/usr/bin/swift-plugin-server"

if [[ -d "$PLUGIN_DIR" && -x "$PLUGIN_SERVER" ]]; then
    exec swift test \
        -Xswiftc -external-plugin-path \
        -Xswiftc "$PLUGIN_DIR#$PLUGIN_SERVER" \
        "$@"
fi

exec swift test "$@"
