#!/bin/bash
# Serve the listener page from the assembled RoomCast.app. This is the crash
# that happened when a phone opened the page in the notarized build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/RoomCast.app}"
"$ROOT/scripts/check-app-resources.sh" "$APP"
BIN="$APP/Contents/MacOS/RoomCast"
if [[ ! -x "$BIN" ]]; then
  echo "error: missing $BIN" >&2
  exit 1
fi
"$BIN" --listener-page-self-test
