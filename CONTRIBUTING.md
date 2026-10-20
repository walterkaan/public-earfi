# Contributing to Public EarFi

Public EarFi is an MIT-licensed macOS app. Small pull requests are the easiest to review. Include a short description and a test when the change is in the logic that does not need a Mac GUI.

## Build

Requirements: macOS 13 or later, Xcode or the Swift toolchain, and `pkg-config`.

```bash
./scripts/build-helpers.sh
./scripts/build-app.sh
open "dist/Public EarFi.app"
```

`scripts/build-helpers.sh` downloads the pinned MediaMTX release and builds libopus plus an LGPL FFmpeg from source for arm64 and x86_64. Do not commit those binaries. The script checks the SHA-256 values in `scripts/versions.env`.

Unit tests do not need the helpers:

```bash
swift test
```

To also ask the real MediaMTX binary to parse a generated config:

```bash
MEDIAMTX_BIN=build/helpers/mediamtx swift test --filter MediaMTXConfigTests
```

## Style

CI runs `swift-format lint --recursive --strict` with the default configuration. Format before you push:

```bash
swift-format format --recursive --in-place Sources Tests
```

## Pull requests

Keep the change focused. Describe what a volunteer would notice, and mention how you tested it. `main` should stay green.

Do not add a dependency without also adding it to `THIRD_PARTY_NOTICES.md` and the Credits sheet (`credits.json`). Do not enable GPL or non-free FFmpeg components.

## Developer Certificate of Origin

This project uses the [Developer Certificate of Origin](https://developercertificate.org/) instead of a contributor licence agreement. Add a `Signed-off-by` line to each commit:

```bash
git commit -s
```

By signing off, you certify that you can submit the change under the MIT licence.

## Reporting bugs

Use the bug report template. Include the output of **Copy diagnostics**, the macOS version, and the audio interface model.
