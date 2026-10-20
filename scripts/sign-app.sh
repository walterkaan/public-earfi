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
  local target="$1" identifier="$2" entitlements="${3:-}" runtime="${4:-yes}"
  local args=(--force --sign "$IDENTITY" --identifier "$identifier")
  if [[ "$runtime" == "yes" ]]; then
    args+=(--options runtime)
  fi
  if [[ "$IDENTITY" != "-" ]]; then
    args+=(--timestamp)
  fi
  if [[ -n "$entitlements" ]]; then
    args+=(--entitlements "$entitlements")
  fi
  codesign "${args[@]}" "$target"
}

sign_one "$APP/Contents/Helpers/ffmpeg" "io.github.walterkaan.public-earfi.ffmpeg" "$ROOT/scripts/ffmpeg.entitlements"
sign_one "$APP/Contents/Helpers/mediamtx" "io.github.walterkaan.public-earfi.mediamtx" "$ROOT/scripts/mediamtx.entitlements"
# Resource bundles have no executable. Hardened runtime is rejected on them.
while IFS= read -r bundle; do
  sign_one "$bundle" "io.github.walterkaan.public-earfi.resources" "" "no"
done < <(find "$APP" -name '*.bundle' -type d | sort)
sign_one "$APP" "io.github.walterkaan.public-earfi" "$ROOT/Sources/PublicEarFi/PublicEarFi.entitlements"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signature verified"
