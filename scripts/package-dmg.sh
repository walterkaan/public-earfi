#!/bin/bash
# Build a branded RoomCast DMG: navy/violet/teal background (@1x+@2x), large
# icons, Applications drop link, custom volume icon. Volume name: RoomCast.
# Compressed UDZO. Does not notarize or upload.
#
# Prefers create-dmg (brew install create-dmg) for Finder layout + volume icon.
# Falls back to hdiutil + AppleScript when create-dmg is not installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${PUBLIC_EARFI_VERSION:-1.0.0}"
APP="$ROOT/dist/RoomCast.app"
STAGE="$ROOT/build/dmg-root"
RW_DMG="$ROOT/build/RoomCast-rw.dmg"
DMG="$ROOT/dist/RoomCast-${VERSION}.dmg"
BG_1X="$ROOT/design/dmg/background.png"
BG_2X="$ROOT/design/dmg/background@2x.png"
VOLICON_SRC="${APP}/Contents/Resources/AppIcon.icns"
VOLUME_NAME="RoomCast"

WIN_X=200
WIN_Y=120
WIN_W=640
WIN_H=400
ICON_SIZE=128
APP_ICON_X=160
APP_ICON_Y=190
APPS_ICON_X=480
APPS_ICON_Y=190

detach_volume() {
  local target="${1:-}"
  if [[ -n "$target" ]]; then
    hdiutil detach "$target" -force >/dev/null 2>&1 || true
  fi
  hdiutil detach "/Volumes/${VOLUME_NAME}" -force >/dev/null 2>&1 || true
}

inject_retina_background_and_finalize() {
  # $1 = existing UDZO/UDRW path to augment with @2x, rewritten as UDZO at $DMG.
  local source_dmg="$1"
  local tmp_rw="$ROOT/build/RoomCast-bgfix.dmg"
  rm -f "$tmp_rw"
  hdiutil convert "$source_dmg" -format UDRW -o "$tmp_rw" >/dev/null
  local mount_dir
  mount_dir="$(hdiutil attach -readwrite -noverify -noautoopen "$tmp_rw" \
    | awk '/\/Volumes\// {for (i=3; i<=NF; i++) printf "%s%s", $i, (i<NF?" ":""); print ""; exit}')"
  if [[ -z "${mount_dir:-}" || ! -d "$mount_dir" ]]; then
    echo "Failed to remount for Retina background." >&2
    rm -f "$tmp_rw"
    return 1
  fi
  mkdir -p "$mount_dir/.background"
  cp "$BG_1X" "$mount_dir/.background/background.png"
  cp "$BG_2X" "$mount_dir/.background/background@2x.png"
  SetFile -a V "$mount_dir/.background" 2>/dev/null || true
  if [[ -f "$mount_dir/.VolumeIcon.icns" ]]; then
    SetFile -c icnC "$mount_dir/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$mount_dir" 2>/dev/null || true
  else
    cp "$VOLICON_SRC" "$mount_dir/.VolumeIcon.icns"
    SetFile -c icnC "$mount_dir/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$mount_dir" 2>/dev/null || true
  fi
  rm -rf "$mount_dir/.fseventsd" || true
  sync
  detach_volume "$mount_dir"
  # Detach retries
  local attempt=1
  while hdiutil info | grep -q "/Volumes/${VOLUME_NAME}"; do
    if [[ "$attempt" -ge 6 ]]; then
      detach_volume "/Volumes/${VOLUME_NAME}"
      break
    fi
    sleep 2
    hdiutil detach "/Volumes/${VOLUME_NAME}" >/dev/null 2>&1 || true
    attempt=$((attempt + 1))
  done
  rm -f "$DMG"
  hdiutil convert "$tmp_rw" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
  rm -f "$tmp_rw"
}

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP. Run scripts/build-app.sh first." >&2
  exit 1
fi
if [[ ! -f "$BG_1X" || ! -f "$BG_2X" ]]; then
  echo "Missing DMG backgrounds in design/dmg/. Regenerate with:" >&2
  echo "  python3 scripts/make_dmg_background.py" >&2
  exit 1
fi
if [[ ! -f "$VOLICON_SRC" ]]; then
  echo "Missing volume icon source: $VOLICON_SRC" >&2
  exit 1
fi

echo "Staging DMG contents…"
rm -rf "$STAGE" "$RW_DMG" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# create-dmg --app-drop-link creates Applications; for the fallback we need the link.
if ! command -v create-dmg >/dev/null 2>&1; then
  ln -s /Applications "$STAGE/Applications"
fi

detach_volume "/Volumes/${VOLUME_NAME}"

if command -v create-dmg >/dev/null 2>&1; then
  echo "Using create-dmg for Finder layout…"
  # Write to a temp path; we re-compress after adding the @2x background.
  TMP_OUT="$ROOT/build/RoomCast-createdmg.dmg"
  rm -f "$TMP_OUT"
  create-dmg \
    --volname "$VOLUME_NAME" \
    --volicon "$VOLICON_SRC" \
    --background "$BG_1X" \
    --window-pos "$WIN_X" "$WIN_Y" \
    --window-size "$WIN_W" "$WIN_H" \
    --icon-size "$ICON_SIZE" \
    --text-size 12 \
    --icon "RoomCast.app" "$APP_ICON_X" "$APP_ICON_Y" \
    --hide-extension "RoomCast.app" \
    --app-drop-link "$APPS_ICON_X" "$APPS_ICON_Y" \
    --format UDZO \
    --hdiutil-quiet \
    --hdiutil-retries 5 \
    --no-internet-enable \
    --overwrite \
    "$TMP_OUT" \
    "$STAGE"
  echo "Adding Retina background…"
  inject_retina_background_and_finalize "$TMP_OUT"
  rm -f "$TMP_OUT"
else
  echo "create-dmg not found; using hdiutil + AppleScript…"
  echo "(Install with: brew install create-dmg)"
  APP_MB=$(du -sm "$STAGE" | awk '{print $1}')
  SIZE_MB=$((APP_MB + 50))

  attempt=1
  until hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_MB}m" \
    "$RW_DMG" >/dev/null
  do
    if [[ "$attempt" -ge 5 ]]; then
      echo "hdiutil could not create the writable disk image" >&2
      exit 1
    fi
    echo "hdiutil was busy (attempt ${attempt}). Retrying."
    detach_volume "/Volumes/${VOLUME_NAME}"
    rm -f "$RW_DMG"
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done

  MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" \
    | awk '/\/Volumes\// {for (i=3; i<=NF; i++) printf "%s%s", $i, (i<NF?" ":""); print ""; exit}')"
  if [[ -z "${MOUNT_DIR:-}" || ! -d "$MOUNT_DIR" ]]; then
    echo "Failed to mount $RW_DMG" >&2
    exit 1
  fi

  mkdir -p "$MOUNT_DIR/.background"
  cp "$BG_1X" "$MOUNT_DIR/.background/background.png"
  cp "$BG_2X" "$MOUNT_DIR/.background/background@2x.png"
  SetFile -a V "$MOUNT_DIR/.background" 2>/dev/null || true

  cp "$VOLICON_SRC" "$MOUNT_DIR/.VolumeIcon.icns"
  SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns"

  sleep 3
  WIN_R=$((WIN_X + WIN_W))
  WIN_B=$((WIN_Y + WIN_H))
  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    try
      set sidebar width of container window to 0
    end try
    set the bounds of container window to {$WIN_X, $WIN_Y, $WIN_R, $WIN_B}
    -- Park Finder-visible support files outside the window, then place icons.
    set position of every item to {$WIN_R + 100, 100}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    try
      set text size of theViewOptions to 12
    end try
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "RoomCast.app" of container window to {$APP_ICON_X, $APP_ICON_Y}
    set position of item "Applications" of container window to {$APPS_ICON_X, $APPS_ICON_Y}
    set the bounds of container window to {$WIN_X, $WIN_Y, $WIN_R, $WIN_B}
    update without registering applications
    delay 2
    close
    open
    delay 1
    set the bounds of container window to {$WIN_X, $WIN_Y, $WIN_R, $WIN_B}
    delay 2
    close
  end tell
end tell
APPLESCRIPT

  sleep 2
  if [[ ! -f "$MOUNT_DIR/.VolumeIcon.icns" ]]; then
    cp "$VOLICON_SRC" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns"
  fi
  SetFile -a C "$MOUNT_DIR"
  chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
  rm -rf "$MOUNT_DIR/.fseventsd" || true
  sync

  attempt=1
  until hdiutil detach "$MOUNT_DIR" >/dev/null
  do
    if [[ "$attempt" -ge 8 ]]; then
      detach_volume "$MOUNT_DIR"
      break
    fi
    osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1 || true
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done

  rm -f "$DMG"
  hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
  rm -f "$RW_DMG"
fi

if [[ ! -f "$DMG" ]]; then
  echo "DMG was not created." >&2
  exit 1
fi

(
  cd "$ROOT/dist"
  shasum -a 256 "RoomCast-${VERSION}.dmg" > SHA256SUMS
)

SIZE=$(du -h "$DMG" | awk '{print $1}')
SUM=$(awk '{print $1}' "$ROOT/dist/SHA256SUMS")
echo "DMG: $DMG"
echo "Size: $SIZE"
echo "SHA256: $SUM"
