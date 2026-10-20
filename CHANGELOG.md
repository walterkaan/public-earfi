# Changelog

## 1.0.0 — 2026-10-20

First MVP build of Public EarFi.

- SwiftUI app. The main window is the broadcast. Settings opens with Cmd-, from the app menu. The poster and the log are their own windows. Credits stays in Settings and About.
- App icon: Walter's yellow loudhailer on purple, masked to a squircle with transparent corners.
- Default quality is Speech: mono, 32 kbps, for about 30 phones on venue Wi-Fi. The encode rate is fixed at 48 kHz in 20 ms frames. There is no sample-rate picker. The app captures with Core Audio and pipes 48 kHz PCM to ffmpeg, because ffmpeg's AVFoundation capture clicks even when the same device is clean in other apps.
- Bundled MediaMTX 1.21.2 and an LGPL FFmpeg 9.0.2 with libopus 1.6.1, built from pinned source.
- Generated `mediamtx.yml`, device selection by Core Audio UID, defaults from the spec, and Reset.
- Start/stop supervision, auto-restart, stall detection, LAN address selection, and file logging. A port that is already in use is named, including the other program, and is not retried. A leftover Public EarFi helper can be stopped from the window.
- Invalid saved settings are replaced with defaults instead of crashing Start. A missing audio device is reported and cleared. Reset to defaults writes a full default set back to preferences.
- Poster preview, PDF export, printing, and QR copy.
- Organiser manual in `docs/MANUAL.md`: install, Speech, the poster, listener tips, bandwidth for about 30 phones, and a travel-router network. A phone server is described as planned.
- GitHub Actions builds an ad-hoc signed universal app and DMG. Release tags sign with `RELEASE_SIGNING_P12` when that secret exists.

Not yet verified on a Mac with a real audio interface or with phone listeners. See the pull request for what CI covered.
