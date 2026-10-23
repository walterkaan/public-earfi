#!/bin/bash
# Compile the vendored Opus sources the same way the Xcode target does,
# then encode and decode a sine. This does not need a phone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPUS="$ROOT/Vendor/opus"
BRIDGE="$ROOT/Vendor/opus-bridge"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(
  -std=c99
  -O2
  -Wall
  -Wextra
  -Wno-unused-function
  -Wno-unused-parameter
  -Wno-maybe-uninitialized
  -Wno-uninitialized
  -DHAVE_CONFIG_H
  -I"$OPUS"
  -I"$OPUS/include"
  -I"$OPUS/celt"
  -I"$OPUS/silk"
  -I"$OPUS/silk/float"
  -I"$OPUS/src"
  -I"$BRIDGE"
)

mapfile -t SOURCES < <(find "$OPUS" -name '*.c' | sort)
i=0
for src in "${SOURCES[@]}" "$BRIDGE/opus_bridge.c" "$ROOT/scripts/opus_roundtrip.c"; do
  gcc "${CFLAGS[@]}" -c "$src" -o "$WORK/$i.o"
  i=$((i + 1))
done
gcc "$WORK"/*.o -lm -o "$WORK/roundtrip"
"$WORK/roundtrip"
