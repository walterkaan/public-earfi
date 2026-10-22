#!/bin/bash
# Sign RoomCast with Walter's Developer ID, make the disk image, notarise it,
# staple the ticket, and check it with spctl.
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
"$ROOT/scripts/package-dmg.sh"

APP="$ROOT/dist/RoomCast.app"
DMG="$ROOT/dist/RoomCast-${VERSION}.dmg"
if [[ ! -d "$APP" || ! -f "$DMG" ]]; then
  echo "Build did not produce $APP and $DMG" >&2
  exit 1
fi

echo "Submitting $DMG to the notary service (profile: $PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"
xcrun stapler validate "$DMG"
xcrun stapler validate "$APP"

spctl --assess --type execute --verbose=4 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
echo "Notarized and stapled: $DMG"
