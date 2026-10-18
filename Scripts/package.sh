#!/usr/bin/env bash
#
# Builds the release app bundle and packages it for distribution.
#
# Produces, in dist/:
#   SSHClientMac-<version>.zip   the .app, zipped for download
#   SSHClientMac-<version>.dmg   a disk image with an Applications symlink
#
# Usage:
#   Scripts/package.sh 0.2.0
#   VERSION=0.2.0 Scripts/package.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-${VERSION:-0.1.0}}"
VERSION="${VERSION#v}"

OUT="$ROOT/dist"
NAME="SSHClientMac-$VERSION"
APP="$OUT/SSHClientMac.app"

echo "==> Packaging $NAME"
VERSION="$VERSION" "$ROOT/Scripts/bundle.sh" release

if [[ ! -d "$APP" ]]; then
    echo "error: $APP was not produced" >&2
    exit 1
fi

# ditto, not zip: it preserves the bundle's symlinks, permissions and extended
# attributes, which a plain zip mangles.
rm -f "$OUT/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"

# A disk image with an Applications symlink, for drag-to-install.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/$NAME.dmg"
hdiutil create \
    -volname "SSH Client" \
    -srcfolder "$STAGE" \
    -ov -format UDZO -quiet \
    "$OUT/$NAME.dmg"

echo "==> Artifacts"
ls -lh "$OUT/$NAME.zip" "$OUT/$NAME.dmg" | awk '{print "    " $9 " (" $5 ")"}'
