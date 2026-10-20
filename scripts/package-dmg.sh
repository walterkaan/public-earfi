#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${PUBLIC_EARFI_VERSION:-1.0.0}"
APP="$ROOT/dist/Public EarFi.app"
STAGE="$ROOT/build/dmg-root"
DMG="$ROOT/dist/Public-EarFi-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP. Run scripts/build-app.sh first." >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/FIRST-OPEN.txt" "$STAGE/Read Me First.txt"

python3 "$ROOT/scripts/make_dmg_background.py" "$STAGE/.background/background.png"

hdiutil create \
  -volname "Public EarFi" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

(
  cd "$ROOT/dist"
  shasum -a 256 "Public-EarFi-${VERSION}.dmg" > SHA256SUMS
)
echo "DMG: $DMG"
