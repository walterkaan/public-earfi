# Third-party notices

RoomCast Go itself is MIT, Copyright 2026 Walter Kaan. See [LICENSE](LICENSE).
The pieces below stay under their own licences.

## Opus 1.6.1

Vendored under [Vendor/opus](Vendor/opus) from the official 1.6.1 tarball
(`6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1`), the same
pin the Mac app uses. This tree keeps the generic float C sources only: no
DNN or DRED, no ARM or x86 assembly, no fixed-point Silk, no demos. The
encoder bridge is [Vendor/opus-bridge](Vendor/opus-bridge).

Opus is BSD. The copyright notice and conditions are in
[Vendor/opus/COPYING](Vendor/opus/COPYING). The royalty-free patent licences
are listed at the bottom of that file.

## Listener page script

[Server/assets/reader.js](Server/assets/reader.js) is
`internal/servers/webrtc/reader.js` from MediaMTX v1.21.2, unchanged.
MediaMTX is MIT, Copyright bluenviron:

https://github.com/bluenviron/mediamtx/blob/v1.21.2/LICENSE

## WebRTC server

The listener server links [pion/webrtc v4](https://github.com/pion/webrtc)
(v4.1.2) and [pion/ice v4](https://github.com/pion/ice) (v4.0.10). Pion is
MIT. Those modules are not copied into this folder; `scripts/build-server-framework.sh`
downloads them when it builds `Roomcast.xcframework`.
