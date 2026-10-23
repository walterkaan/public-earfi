#!/bin/bash
# Sign RoomCast with Walter's Developer ID, make the disk image, sign that
# image, notarise it, staple the ticket, and check it with spctl.
#
# Run this on Walter's Mac. The notary credentials stay in that Mac's keychain:
#   xcrun notarytool store-credentials roomcast
# This script does not contain an Apple ID, app-specific password, or API key.
# Distribution is the stapled .dmg from roomcast.channel, not the App Store.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Walter Kaan (6G2V545X95)}"
PROFILE="${NOTARY_KEYCHAIN_PROFILE:-roomcast}"
VERSION="${PUBLIC_EARFI_VERSION:-1.0.0}"
export SIGN_IDENTITY="$IDENTITY"
export PUBLIC_EARFI_VERSION="$VERSION"

"$ROOT/scripts/build-app.sh"
# build-app.sh installed the resource bundles before it signed. Serve the
# listener page from that signed app, and refuse to notarise if they are gone.
"$ROOT/scripts/check-listener-page.sh" "$ROOT/dist/RoomCast.app"
"$ROOT/scripts/package-dmg.sh"

APP="$ROOT/dist/RoomCast.app"
DMG="$ROOT/dist/RoomCast-${VERSION}.dmg"
if [[ ! -d "$APP" || ! -f "$DMG" ]]; then
  echo "Build did not produce $APP and $DMG" >&2
  exit 1
fi

# The disk image needs its own Developer ID signature before notarization.
# An unsigned image is rejected as "no usable signature" even after the app inside is accepted.
echo "Signing $DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

echo "Submitting $DMG to the notary service (profile: $PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"
xcrun stapler validate "$DMG"
xcrun stapler validate "$APP"

# Signing and stapling change the file, so the checksum from package-dmg.sh is stale.
(
  cd "$ROOT/dist"
  shasum -a 256 "RoomCast-${VERSION}.dmg" > SHA256SUMS
)

spctl --assess --type execute --verbose=4 "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "Notarized and stapled: $DMG"
