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

# macOS SwiftPM stores bundle files in Contents/Resources. A Linux swift
# build leaves them at the bundle root.
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
  echo "Missing $name in $bundle (Contents/Resources or the bundle root)" >&2
  return 1
}

# Flat bundles become Contents/Resources so the signed app matches a macOS build.
mirror_macos_bundle() {
  local bundle="$1" entry base
  if [[ -d "$bundle/Contents/Resources" ]]; then
    return 0
  fi
  mkdir -p "$bundle/Contents/Resources"
  if [[ -f "$bundle/Info.plist" && ! -f "$bundle/Contents/Info.plist" ]]; then
    mv "$bundle/Info.plist" "$bundle/Contents/Info.plist"
  fi
  shopt -s nullglob dotglob
  for entry in "$bundle"/*; do
    base="$(basename "$entry")"
    [[ "$base" == "Contents" ]] && continue
    mv "$entry" "$bundle/Contents/Resources/"
  done
  shopt -u dotglob nullglob
  if [[ ! -f "$bundle/Contents/Info.plist" ]]; then
    cat > "$bundle/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
</dict>
</plist>
EOF
  fi
}

for name in "${required[@]}"; do
  origin="$(locate_bundle "$source_dir" "$name")"
  rm -rf "$APP/Contents/Resources/$name"
  cp -R "$origin" "$APP/Contents/Resources/$name"
  mirror_macos_bundle "$APP/Contents/Resources/$name"
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP/Contents/Resources/$name" || true
  fi
  echo "Installed $name"
done

core="$(locate_bundle "$source_dir" "PublicEarFi_PublicEarFiCore.bundle")"
favicon="$(bundle_resource "$core" favicon.png)" || exit 1
page="$(bundle_resource "$core" ListenerPage.en.json)" || exit 1
cp "$favicon" "$APP/Contents/Resources/favicon.png"
cp "$page" "$APP/Contents/Resources/ListenerPage.en.json"
for size in 96 192 256 512; do
  art="$(bundle_resource "$core" "artwork-${size}.png")" || exit 1
  cp "$art" "$APP/Contents/Resources/artwork-${size}.png"
done
echo "Installed loose listener-page resources"
