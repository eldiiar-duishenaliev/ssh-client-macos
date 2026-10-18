#!/usr/bin/env bash
#
# Bundles the app and launches it.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"

"$ROOT/Scripts/bundle.sh" "$CONFIG"
open "$ROOT/dist/SSHClientMac.app"
