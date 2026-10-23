#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${PUBLIC_EARFI_VERSION:-1.0.0}"
APP="$ROOT/dist/RoomCast.app"
STAGE="$ROOT/build/dmg-root"
DMG="$ROOT/dist/RoomCast-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP. Run scripts/build-app.sh first." >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/FIRST-OPEN.txt" "$STAGE/Read Me First.txt"
cp "$ROOT/docs/MANUAL.md" "$STAGE/User Manual.md"

python3 "$ROOT/scripts/make_dmg_background.py" "$STAGE/.background/background.png"

# GitHub's macOS runners sometimes return "Resource busy" from hdiutil
# while another image is still attached. A short retry clears it.
attempt=1
until hdiutil create \
  -volname "RoomCast" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"
do
  if [[ "$attempt" -ge 5 ]]; then
    echo "hdiutil could not create the disk image" >&2
    exit 1
  fi
  echo "hdiutil was busy (attempt ${attempt}). Retrying."
  hdiutil detach "/Volumes/RoomCast" -force >/dev/null 2>&1 || true
  rm -f "$DMG"
  sleep $((attempt * 5))
  attempt=$((attempt + 1))
done

(
  cd "$ROOT/dist"
  shasum -a 256 "RoomCast-${VERSION}.dmg" > SHA256SUMS
)
echo "DMG: $DMG"
