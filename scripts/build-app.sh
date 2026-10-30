#!/bin/bash
# Assemble a universal RoomCast.app and ad-hoc sign it unless SIGN_IDENTITY is set.
# The deployment target stays macOS 13. When this Mac's Xcode is 26, swift
# uses the macOS 26 SDK. That compiles the Liquid Glass calls. They run only
# on macOS 26. An older SDK skips those calls and keeps the solid controls.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${PUBLIC_EARFI_VERSION:-1.0.0}"
BUILD_NUMBER="${PUBLIC_EARFI_BUILD:-${GITHUB_RUN_NUMBER:-1}}"
COMMIT="${PUBLIC_EARFI_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
export MACOSX_DEPLOYMENT_TARGET=13.0
SWIFT_SDK=()
if SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"; then
  SWIFT_SDK=(--sdk "$SDK_PATH")
fi

if [[ ! -x "$ROOT/build/helpers/ffmpeg" || ! -x "$ROOT/build/helpers/mediamtx" ]]; then
  "$ROOT/scripts/build-helpers.sh"
fi

"$ROOT/scripts/compile-strings.sh"

rm -rf "$ROOT/build/swift-arm64" "$ROOT/build/swift-x86_64"
swift build -c release --triple arm64-apple-macosx13.0 "${SWIFT_SDK[@]}" --build-path "$ROOT/build/swift-arm64"
if [[ "${SKIP_X86:-}" == "1" ]]; then
  echo "SKIP_X86=1: arm64-only assemble"
else
  swift build -c release --triple x86_64-apple-macosx13.0 "${SWIFT_SDK[@]}" --build-path "$ROOT/build/swift-x86_64"
fi

APP="$ROOT/dist/RoomCast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

if [[ "${SKIP_X86:-}" == "1" ]]; then
  cp "$ROOT/build/swift-arm64/release/RoomCast" "$APP/Contents/MacOS/RoomCast"
else
  lipo -create \
    "$ROOT/build/swift-arm64/release/RoomCast" \
    "$ROOT/build/swift-x86_64/release/RoomCast" \
    -output "$APP/Contents/MacOS/RoomCast"
fi
chmod +x "$APP/Contents/MacOS/RoomCast"

cp "$ROOT/build/helpers/ffmpeg" "$ROOT/build/helpers/mediamtx" "$APP/Contents/Helpers/"
chmod +x "$APP/Contents/Helpers/ffmpeg" "$APP/Contents/Helpers/mediamtx"
# The listener page is embedded in the MediaMTX binary. Patch that copy only.
# build/helpers stays the pinned download so the helper cache can be reused.
python3 "$ROOT/scripts/patch-mediamtx-listener.py" "$APP/Contents/Helpers/mediamtx"

mkdir -p "$APP/Contents/Resources/Licenses"
cp -R "$ROOT/Sources/PublicEarFi/Resources/Licenses/." "$APP/Contents/Resources/Licenses/"

mkdir -p "$ROOT/build"
python3 "$ROOT/scripts/make_icon.py" "$ROOT/build/AppIcon.icns"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/en.lproj"
cp "$ROOT/Sources/PublicEarFi/Resources/en.lproj/Localizable.strings" \
  "$APP/Contents/Resources/en.lproj/Localizable.strings"
cp "$ROOT/Sources/PublicEarFiCore/ListenerPage.en.json" \
  "$APP/Contents/Resources/ListenerPage.en.json"
# SwiftPM resource bundles, before the signature. The listener page reads
# these from Contents/Resources and must not call Bundle.module.
if [[ "${SKIP_X86:-}" == "1" ]]; then
  "$ROOT/scripts/install-app-resources.sh" "$APP" \
    "$ROOT/build/swift-arm64/release"
else
  "$ROOT/scripts/install-app-resources.sh" "$APP" \
    "$ROOT/build/swift-arm64/release" \
    "$ROOT/build/swift-x86_64/release"
fi

sed \
  -e "s/__VERSION__/${VERSION}/g" \
  -e "s/__BUILD__/${BUILD_NUMBER}/g" \
  -e "s/__COMMIT__/${COMMIT}/g" \
  "$ROOT/scripts/Info.plist.in" > "$APP/Contents/Info.plist"
# Serve the page from the assembled app before it is signed. Notarization
# runs the same check again on the signed copy.
"$ROOT/scripts/check-listener-page.sh" "$APP"

export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
"$ROOT/scripts/sign-app.sh" "$APP"
echo "Built $APP"
lipo -info "$APP/Contents/MacOS/RoomCast"
codesign --verify --deep --strict --verbose=2 "$APP"
