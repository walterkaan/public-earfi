# Changelog

## 1.0.0 — 2026-10-20

First MVP build of Public EarFi.

- SwiftUI app. The main window is the broadcast. Settings opens with Cmd-, from the app menu. The poster and the log are their own windows. Credits stays in Settings and About.
- App icon: Walter's yellow loudhailer on purple, masked to a squircle with transparent corners.
- Default quality is Speech: mono, 16 kHz, 32 kbps (the rate that worked in manual tests, and the lowest bandwidth). The target is a live interpreter for about 30 phones on venue Wi-Fi. The sample-rate picker offers the Opus rates (8, 12, 16, 24, 48 kHz). 44.1 kHz is not an encode rate; a saved 44.1 kHz setting loads as 48 kHz. The interface stays at its native rate. ffmpeg's aresample converts, without the async fill-and-trim that garbled 44.1 kHz devices forced to 48 kHz.
- Bundled MediaMTX 1.21.2 and an LGPL FFmpeg 9.0.2 with libopus 1.6.1, built from pinned source.
- Generated `mediamtx.yml`, device selection by name, defaults from the spec, and Reset.
- Start/stop supervision, auto-restart, stall detection, LAN address selection, and file logging.
- Poster preview, PDF export, printing, and QR copy.
- Organiser manual in `docs/MANUAL.md`: install, Speech, the poster, listener tips, bandwidth for about 30 phones, and a travel-router network. A phone server is described as planned.
- GitHub Actions builds an ad-hoc signed universal app and DMG. Release tags sign with `RELEASE_SIGNING_P12` when that secret exists.

Not yet verified on a Mac with a real audio interface or with phone listeners. See the pull request for what CI covered.
