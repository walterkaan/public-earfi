#!/bin/bash
# Copy SwiftPM resource bundles into Contents/Resources before the app is signed.
# Bundle.module looks for these beside the executable and then traps. The app
# no longer calls it, and these copies are what the safe lookup reads.
set -euo pipefail

APP="${1:-}"
shift || true
if [[ -z "$APP" || ! -d "$APP/Contents/Resources" || "$#" -lt 1 ]]; then
  echo "usage: install-app-resources.sh RoomCast.app <swift-release-dir>..." >&2
  exit 1
fi

required=(
  PublicEarFi_PublicEarFiCore.bundle
  PublicEarFi_PublicEarFi.bundle
)

locate_bundle() {
  local release="$1" name="$2" found
  if [[ -d "$release/$name" ]]; then
    printf '%s\n' "$release/$name"
    return 0
  fi
  # BSD find has no -quit. head closes the pipe; ignore that signal.
  found="$(find "$release" -type d -name "$name" -print | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  echo "Missing $name in $release" >&2
  find "$release" -type d -name '*.bundle' -print >&2 || true
  return 1
}

source_dir=""
for release in "$@"; do
  if [[ ! -d "$release" ]]; then
    echo "Swift build directory is missing: $release" >&2
    exit 1
  fi
  for name in "${required[@]}"; do
    locate_bundle "$release" "$name" >/dev/null
  done
  if [[ -z "$source_dir" ]]; then
    source_dir="$release"
  fi
done

for name in "${required[@]}"; do
  origin="$(locate_bundle "$source_dir" "$name")"
  rm -rf "$APP/Contents/Resources/$name"
  cp -R "$origin" "$APP/Contents/Resources/$name"
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP/Contents/Resources/$name" || true
  fi
  echo "Installed $name"
done

core="$(locate_bundle "$source_dir" "PublicEarFi_PublicEarFiCore.bundle")"
cp "$core/favicon.png" "$APP/Contents/Resources/favicon.png"
cp "$core/ListenerPage.en.json" "$APP/Contents/Resources/ListenerPage.en.json"
echo "Installed loose listener-page resources"
