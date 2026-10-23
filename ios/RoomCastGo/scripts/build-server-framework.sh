#!/bin/bash
# Build the in-process WebRTC server as an iOS framework.
# Run this on a Mac with Xcode before opening RoomCastGo.xcodeproj.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Roomcast.xcframework"
GOMOBILE_REV="v0.0.0-20261011034528-197770444867"

brew_hint() {
  echo "Install a current Apple silicon Go with:" >&2
  echo "  brew install go" >&2
  echo "Then open a new Terminal. 'which go' should be /opt/homebrew/bin/go" >&2
  echo "(or another Go 1.26+ darwin/arm64), not an old /usr/local/go/bin/go." >&2
  echo "A download from https://go.dev/dl/ works too, if it replaces that old copy." >&2
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this on your Mac. gomobile can only build the iOS framework where Xcode is installed." >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "Go is not installed." >&2
  brew_hint
  exit 1
fi

go_bin="$(command -v go)"

# An old Intel toolchain (a 2017 /usr/local/go is enough) is SIGKILL'd by
# macOS on Apple silicon, exit 137, before it can print a version.
if [[ "$(uname -m)" == "arm64" ]]; then
  go_kind="$(file -b "$go_bin" 2>/dev/null || true)"
  if [[ "$go_kind" == *"x86_64"* && "$go_kind" != *"arm64"* ]]; then
    echo "The go at $go_bin is an Intel binary, not Apple silicon." >&2
    echo "file says: $go_kind" >&2
    echo "macOS kills that kind of old Go with exit 137." >&2
    brew_hint
    exit 1
  fi
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is not selected. Install Xcode, open it once, then run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

set +e
env_out="$(go env GOVERSION GOHOSTARCH 2>/dev/null)"
status=$?
set -e
if [[ $status -ne 0 || -z "$env_out" ]]; then
  echo "Could not run $go_bin (exit ${status})." >&2
  if [[ $status -eq 137 ]]; then
    echo "macOS killed it. That is usually an old Intel Go under /usr/local/go." >&2
  fi
  brew_hint
  exit 1
fi

ver="${env_out%%$'\n'*}"
hostarch="${env_out#*$'\n'}"
ver="${ver#go}"
if [[ "$(uname -m)" == "arm64" && "$hostarch" != "arm64" ]]; then
  echo "Go at $go_bin is running as ${hostarch}, not arm64." >&2
  brew_hint
  exit 1
fi

major="${ver%%.*}"
rest="${ver#*.}"
minor="${rest%%.*}"
if [[ "$major" -lt 1 || ( "$major" -eq 1 && "$minor" -lt 26 ) ]]; then
  echo "Go $ver at $go_bin is too old. This proof needs Go 1.26 or newer." >&2
  brew_hint
  exit 1
fi

export GOTOOLCHAIN=local
export GO111MODULE=on
GOBIN="$(go env GOPATH)/bin"
export PATH="$GOBIN:$PATH"

# Server/go.mod records gobind as a tool, which gomobile bind requires
# (https://go.dev/issue/77183). Installing the two commands only puts them on PATH.
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
