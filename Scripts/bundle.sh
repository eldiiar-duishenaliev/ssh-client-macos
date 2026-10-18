#!/usr/bin/env bash
#
# Builds the SwiftPM executable and assembles a runnable .app bundle.
#
# SwiftPM produces a bare Mach-O executable; macOS needs a bundle (Info.plist,
# Resources, code signature) for a proper GUI app with a menu bar and focus.
#
# Usage:
#   Scripts/bundle.sh              # debug build
#   Scripts/bundle.sh release      # release build
#
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SSHClientMac"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

cd "$ROOT"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "error: executable not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so the app launches cleanly on this machine.
# Note: --deep is deprecated and throws on recent macOS; the bundle has no
# nested code, so a plain signature is sufficient.
echo "==> Ad-hoc signing"
codesign --force --sign - \
    --entitlements "$ROOT/Resources/$APP_NAME.entitlements" \
    "$APP"

codesign --verify --verbose=2 "$APP"

echo "==> Done: $APP"
echo "    open \"$APP\""
