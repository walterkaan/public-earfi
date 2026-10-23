#!/bin/bash
# Fail if the assembled app is missing the listener-page resources. Signing
# and notarization both run this so a package cannot ship without them.
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: check-app-resources.sh RoomCast.app" >&2
  exit 1
fi

fail() {
  echo "error: $1" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing $1"
}

require_dir() {
  [[ -d "$1" ]] || fail "missing $1"
}

resources="$APP/Contents/Resources"
require_dir "$resources"
require_file "$resources/favicon.png"
require_file "$resources/ListenerPage.en.json"
require_file "$resources/AppIcon.icns"
require_file "$resources/en.lproj/Localizable.strings"
require_file "$resources/Licenses/credits.json"

# macOS: Contents/Resources. Flat swift build: the bundle root.
bundle_resource() {
  local bundle="$1" name="$2"
  if [[ -f "$bundle/Contents/Resources/$name" ]]; then
    printf '%s\n' "$bundle/Contents/Resources/$name"
    return 0
  fi
  if [[ -f "$bundle/$name" ]]; then
    printf '%s\n' "$bundle/$name"
    return 0
  fi
  fail "missing $name in $bundle (Contents/Resources or the bundle root)"
}

core="$resources/PublicEarFi_PublicEarFiCore.bundle"
require_dir "$core"
require_dir "$core/Contents/Resources"
core_icon="$(bundle_resource "$core" favicon.png)" || exit 1
core_page="$(bundle_resource "$core" ListenerPage.en.json)" || exit 1
require_file "$core_icon"
require_file "$core_page"

app_bundle="$resources/PublicEarFi_PublicEarFi.bundle"
require_dir "$app_bundle"
if [[ ! -f "$app_bundle/Contents/Resources/Resources/Licenses/credits.json" \
  && ! -f "$app_bundle/Contents/Resources/Licenses/credits.json" \
  && ! -f "$app_bundle/Resources/Licenses/credits.json" \
  && ! -f "$app_bundle/Licenses/credits.json" ]]; then
  fail "app resource bundle has no credits.json"
fi

python3 - "$resources/ListenerPage.en.json" "$core_page" << 'PY'
import json, pathlib, sys
for path in sys.argv[1:]:
    text = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if text.get("loadError") != "The listener page could not load.":
        raise SystemExit(f"{path} is missing loadError")
print("App resources are present")
PY
