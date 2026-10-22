#!/bin/bash
# Sign inside-out. SIGN_IDENTITY="-" is ad-hoc. A release identity is used when set.
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: sign-app.sh Public\\ EarFi.app" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGN_IDENTITY:--}"
echo "Signing with identity: $IDENTITY"

sign_one() {
  local target="$1" identifier="$2" entitlements="${3:-}"
  local args=(--force --sign "$IDENTITY" --options runtime --identifier "$identifier")
  if [[ "$IDENTITY" != "-" ]]; then
    args+=(--timestamp)
  fi
  if [[ -n "$entitlements" ]]; then
    args+=(--entitlements "$entitlements")
  fi
  codesign "${args[@]}" "$target"
}

sign_one "$APP/Contents/Helpers/ffmpeg" "channel.roomcast.app.ffmpeg" "$ROOT/scripts/ffmpeg.entitlements"
sign_one "$APP/Contents/Helpers/mediamtx" "channel.roomcast.app.mediamtx" "$ROOT/scripts/mediamtx.entitlements"
sign_one "$APP" "channel.roomcast.app" "$ROOT/Sources/PublicEarFi/PublicEarFi.entitlements"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signature verified"
