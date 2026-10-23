#!/bin/bash
# Turn Localizable.xcstrings into en.lproj/Localizable.strings.
#
# Checked with Swift 6.4: `swift build` does not compile an xcstrings catalog,
# so a catalog alone would not ship translations. This script writes the
# strings file that scripts/build-app.sh copies into the app. English still
# appears if that file is missing, because the SwiftUI text is the English key.
# When Xcode is installed, xcstringstool compiles every language in the catalog.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/Sources/PublicEarFi/Resources/Localizable.xcstrings"
OUT="$ROOT/Sources/PublicEarFi/Resources/en.lproj"
mkdir -p "$OUT"

if command -v xcrun >/dev/null 2>&1 && xcrun --find xcstringstool >/dev/null 2>&1; then
  COMPILED="$ROOT/build/strings"
  rm -rf "$COMPILED"
  mkdir -p "$COMPILED"
  if xcrun xcstringstool compile "$CATALOG" --output-directory "$COMPILED"; then
    if [[ -f "$COMPILED/en.lproj/Localizable.strings" ]]; then
      cp "$COMPILED/en.lproj/Localizable.strings" "$OUT/Localizable.strings"
      echo "Compiled string catalog with xcstringstool"
      exit 0
    fi
  fi
  echo "xcstringstool did not write en.lproj. Writing English from the catalog."
fi

python3 - "$CATALOG" "$OUT/Localizable.strings" << 'PY'
import json, pathlib, sys
catalog = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rows = []
for key, entry in catalog.get("strings", {}).items():
    localizations = entry.get("localizations") or {}
    english = (localizations.get("en") or {}).get("stringUnit") or {}
    value = english.get("value", key)
    def esc(text):
        return (
            text.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
        )
    rows.append(f'"{esc(key)}" = "{esc(value)}";')
rows.sort()
path = pathlib.Path(sys.argv[2])
path.write_text("\n".join(rows) + "\n", encoding="utf-8")
print(f"Wrote {len(rows)} English strings to {path}")
PY
