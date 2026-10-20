# Changelog

## 1.0.0 — 2026-10-20

First MVP build of Public EarFi.

- SwiftUI app with Running, Settings, and Poster tabs, plus the Credits sheet.
- Bundled MediaMTX 1.21.2 and an LGPL FFmpeg 9.0.2 with libopus 1.6.1, built from pinned source.
- Generated `mediamtx.yml`, device selection by name, defaults from the spec, and Reset.
- Start/stop supervision, auto-restart, stall detection, LAN address selection, and file logging.
- Poster preview, PDF export, printing, and QR copy.
- GitHub Actions builds an ad-hoc signed universal app and DMG. Release tags sign with `RELEASE_SIGNING_P12` when that secret exists.

Not yet verified on a Mac with a real audio interface or with phone listeners. See the pull request for what CI covered.
