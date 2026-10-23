# Findings: can an iPhone host voice-only RoomCast?

**Yes, for a handful of listeners on the same Wi-Fi or on this iPhone’s
Personal Hotspot.** This proof is not a stand-in for the Mac app at a
30-person venue. Latency, battery, and heat were not measured on a phone.
The numbers below are design bounds, not device results.

## Server choice

The Mac app runs MediaMTX as a separate process and feeds it Opus over RTSP
from ffmpeg. iOS apps cannot spawn that helper, and the RTSP hop would still
need a second encoder process.

| Option | Why it lost or won |
| --- | --- |
| Embed all of MediaMTX with gomobile | MediaMTX’s `internal` packages cannot be imported, so this needs a fork. RTMP, HLS, SRT, and the API server would ship unused. The binary would be similar or larger, and the app would still need its own capture path because ffmpeg cannot be spawned. |
| Google WebRTC.framework | Large binary, awkward fit for the listener page’s WHEP flow, and the SDK is a long build. Encoding once and fanning out is clumsier than a static RTP track. |
| Pure Swift ICE and DTLS | Not a practical proof. The security and congestion code is the whole problem. |
| **In-process Pion WHEP server** | **Chosen.** Pion is the WebRTC library MediaMTX already uses. One Go package, bound with gomobile to `Roomcast.xcframework`, speaks the same WHEP and `reader.js` contract as the Mac listener page. Opus is compiled by Xcode from the vendored 1.6.1 float sources. `AVAudioEngine` captures the mic. One Opus encode is fanned out to every peer. |

The listener HTML is a copy of the Mac page at the RoomCast beta commit
`780ddc8`, including the waiting state, the retry, and the
“Powered by RoomCast” footer. `reader.js` is the MediaMTX v1.21.2 file,
byte for byte.

## Licence, size, battery, App Store

| | This proof |
| --- | --- |
| Licence | App code is MIT. Pion is MIT. `reader.js` is MediaMTX MIT. Opus is BSD and stays royalty-free. All four are acceptable in an App Store binary. Notices are in `THIRD_PARTY_NOTICES.md`. |
| Size | Not measured. gomobile bind needs macOS and Xcode, which this environment does not have. A device build of pion/webrtc is commonly tens of megabytes. The Opus objects are small next to that. Embedding MediaMTX would not be smaller. |
| Battery | The 32 kbps voice encode is cheap: 50 frames of a sine encoded immediately in the Linux round-trip. The Wi-Fi or hotspot radio dominates, and background audio keeps that radio up while the screen is locked. Personal Hotspot access-point mode is the hot case. Not measured on a device. |
| Heat | One to five listeners should be comfortable. Sixteen SRTP sessions plus a hotspot is the stress case and was not run. |
| App Store | A local HTTP server plus a real microphone, with the `audio` background mode, is a normal audio app. Do not switch that mode to `voip`. mDNS is off, so there is no multicast entitlement and no Bonjour approval. The LAN address is shown as a QR code instead. `ITSAppUsesNonExemptEncryption` is false because the only cryptography is standard DTLS and SRTP. A privacy report is still required before any upload. The bundled privacy manifest declares no tracking and a File Timestamp reason (`C617.1`) because the Go runtime calls `stat`. That reason should be re-checked against the built binary before submission. |

## Latency

Not measured. The path is a 20 ms capture period, Opus in VoIP mode
(algorithmic delay on top of that frame), a browser jitter buffer that is
often about 40–100 ms, and well under 10 ms on a quiet LAN. Expect roughly
100–200 ms mouth-to-ear, possibly a little under the Mac app because there
is no ffmpeg-to-RTSP hop. A phone-to-phone recording is the measurement a
real version needs.

## Behaviour that is designed and not device-tested

- Background audio while the screen is locked or the app is not in front.
  The orange microphone indicator is the lock-screen signal.
- A phone call stops the microphone and does not tear down listener
  sessions. When the interruption ends, capture starts again. If iOS
  suspends the process anyway, the listener page retries WHEP on its own.
- The system picks the input: built-in mic, AirPods, a wired headset, or a
  USB-C mic. Voice processing runs only for the built-in mic, so a headset
  is not run through speakerphone echo control. AirPods use the hands-free
  profile and will sound like a call.
- The server binds the chosen private IPv4 only, on port 8889 for the page
  and WHEP and port 8189 for ICE over both UDP and TCP. It does not listen
  on the cellular address. A one-packet UDP poke to a neighbour on the same
  subnet is what triggers the Local Network prompt. Bonjour is not used.
- Personal Hotspot address `172.20.10.1` wins over venue Wi-Fi when both
  exist. See the hotspot limits in [README.md](README.md).

## What a real version needs

- Measurements on a device: latency, battery, and heat at 1 listener, at 5,
  and at however many the hotspot will actually hold.
- Lock-screen, Low Power Mode, and incoming-call runs, including AirPods,
  a wired headset, and a USB-C class-compliant mic.
- Share the listener HTML with the Mac app’s `ListenerPage.swift` so the
  two copies cannot drift. This proof copied the page; it is not a shared
  target.
- A TCP-ICE check on a network that blocks UDP, and a check on an IPv6-only
  network. This proof advertises IPv4 only.
- Show the listener cap in the UI. Do not promise the Mac venue size.
- TestFlight, then a privacy report generated from the archive.

## What this environment verified

Linux, no iPhone, no Xcode, no Safari:

- `go test` in `Server/`: host selection (hotspot before Wi-Fi, cellular
  ignored, public addresses ignored), the listener page contract, two
  listeners receiving the same payloads, trickle ICE, and start/stop.
- `scripts/test-opus.sh`: the vendored encoder round-trips a 220 Hz sine
  (best correlation 0.99949 after the codec delay).

Not verified, because there is no iPhone and no macOS SDK here: the
gomobile framework link, the SwiftUI compile, the microphone, background
audio, call interruptions, AirPods, Personal Hotspot, latency, battery,
and heat.
