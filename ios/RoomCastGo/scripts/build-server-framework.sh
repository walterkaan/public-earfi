#!/bin/bash
# Build the in-process WebRTC server as an iOS framework.
# Run this on a Mac with Xcode before opening RoomCastGo.xcodeproj.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Roomcast.xcframework"
GOMOBILE_REV="v0.0.0-20261011034528-197770444867"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this on your Mac. gomobile can only build the iOS framework where Xcode is installed." >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "Go is not installed. Install Go 1.26 or newer from https://go.dev/dl/ and open a new Terminal window." >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is not selected. Install Xcode, open it once, then run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

ver="$(go env GOVERSION | sed 's/^go//')"
major="${ver%%.*}"
rest="${ver#*.}"
minor="${rest%%.*}"
if [[ "$major" -lt 1 || ( "$major" -eq 1 && "$minor" -lt 26 ) ]]; then
  echo "Go $ver is too old for the gomobile version this proof uses." >&2
  echo "Install Go 1.26 or newer from https://go.dev/dl/ and open a new Terminal window." >&2
  exit 1
fi

export GOTOOLCHAIN=local
export GO111MODULE=on
GOBIN="$(go env GOPATH)/bin"
export PATH="$GOBIN:$PATH"

echo "Installing gomobile ($GOMOBILE_REV)…"
go install "golang.org/x/mobile/cmd/gomobile@${GOMOBILE_REV}"
go install "golang.org/x/mobile/cmd/gobind@${GOMOBILE_REV}"

mkdir -p "$ROOT/build"
echo "Compiling the listener server for iPhone (arm64). This takes a few minutes the first time."
(
  cd "$ROOT/Server"
  gomobile bind -target=ios/arm64 -iosversion=17.0 -trimpath -o "$OUT" .
)

echo "Wrote $OUT"
echo "In Xcode, open $ROOT/RoomCastGo.xcodeproj, select your iPhone, and press Run."
