#!/bin/bash
# Fail if a bundled helper has no credits entry or its licence file is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Public EarFi.app}"
LICENSES="$APP/Contents/Resources/Licenses"
if [[ ! -d "$LICENSES" ]]; then
  LICENSES="$ROOT/Sources/PublicEarFi/Resources/Licenses"
fi

python3 - "$LICENSES" "$APP" << 'PY'
import json, pathlib, sys
licenses = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
document = json.loads((licenses / "credits.json").read_text())
required = ["public-earfi", "mediamtx", "ffmpeg", "libopus", "qr"]
found = {item["id"]: item for item in document["components"]}
missing = [item for item in required if item not in found]
if missing:
    raise SystemExit("credits.json is missing: " + ", ".join(missing))
statement = "This software uses code of FFmpeg (ffmpeg.org) licensed under the LGPL v2.1 or later."
if statement not in found["ffmpeg"]["notes"]:
    raise SystemExit("FFmpeg credits are missing the LGPL statement")
flags = found["ffmpeg"].get("configureFlags") or ""
for flag in ("--disable-gpl", "--disable-nonfree", "--enable-libopus", "--enable-avfoundation"):
    if flag not in flags:
        raise SystemExit(f"configure flags missing {flag}")
if " --enable-gpl" in " " + flags or flags.startswith("--enable-gpl"):
    raise SystemExit("configure flags enable GPL")
for item in document["components"]:
    name = item["licenseFile"]
    if not name:
        continue
    path = licenses / name
    if not path.is_file() or path.stat().st_size < 200:
        raise SystemExit(f"licence file missing or too small: {path}")
helpers = app / "Contents" / "Helpers"
if helpers.is_dir():
    for binary, component in (("mediamtx", "mediamtx"), ("ffmpeg", "ffmpeg")):
        if (helpers / binary).is_file() and component not in found:
            raise SystemExit(f"{binary} is bundled without a credits entry")
print("Credits check passed")
PY
