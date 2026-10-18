#!/usr/bin/env bash
#
# Builds Resources/AppIcon.icns from the programmatic icon renderer.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Rendering 1024px master"
swift "$ROOT/Scripts/make-icon.swift" "$WORK/icon.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# Each entry is "<pixels> <iconset filename>".
while read -r pixels file; do
    sips -z "$pixels" "$pixels" "$WORK/icon.png" --out "$ICONSET/$file" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES

echo "==> Packing icns"
iconutil -c icns "$ICONSET" -o "$OUTPUT"

echo "==> Done: $OUTPUT"
