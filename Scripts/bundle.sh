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

# Development builds get their own bundle identifier. LaunchServices keys
# applications off the bundle id, so two builds sharing one id show up as
# duplicate apps, and `open` can resolve to the wrong copy. Release builds keep
# the production identifier.
if [[ "$CONFIG" != "release" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.eldiiar.sshclientmac.dev" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName SSH Client (dev)" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SSH Client (dev)" "$APP/Contents/Info.plist"
    echo "==> Development build: bundle id com.eldiiar.sshclientmac.dev"
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Stamp a version into the bundle when one is supplied, so releases report the
# tag they were built from rather than the placeholder in Info.plist.
if [[ -n "${VERSION:-}" ]]; then
    echo "==> Version $VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

# Sign the bundle. Ad-hoc by default, which is enough to launch locally but
# gives the app no stable identity: macOS records an ad-hoc app's designated
# requirement as the hash of that exact binary, so every rebuild looks like a
# different application to the Keychain, and stored secrets have to be
# re-authorised. Set CODESIGN_IDENTITY to a certificate (self-signed or
# Developer ID) for a stable identity.
#
# Note: --deep is deprecated and throws on recent macOS; the bundle has no
# nested code, so a plain signature is sufficient.
IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ "$IDENTITY" == "-" ]]; then
    echo "==> Ad-hoc signing (no stable identity; see README on Keychain prompts)"
    codesign --force --sign - \
        --entitlements "$ROOT/Resources/$APP_NAME.entitlements" \
        "$APP"
else
    echo "==> Signing with: $IDENTITY"
    codesign --force \
        --options runtime \
        --timestamp \
        --sign "$IDENTITY" \
        --entitlements "$ROOT/Resources/$APP_NAME.entitlements" \
        "$APP"
fi

codesign --verify --verbose=2 "$APP"
echo "    designated requirement: $(codesign -d -r- "$APP" 2>&1 | grep -i designated | head -1)"

echo "==> Done: $APP"
echo "    open \"$APP\""
