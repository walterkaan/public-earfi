# Findings: can an iPhone host voice-only RoomCast?

**Yes, for a handful of listeners on the same Wi-Fi or on this iPhone’s
Personal Hotspot.** Walter ran it on an iPhone 15: the stream kept going
with the screen locked, two listeners worked including over the phone’s
hotspot, and the delay was about 500 ms. This proof is not a stand-in for
the Mac app at a 30-person venue. Battery and heat were not measured.

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

The listener HTML is the Mac page at the RoomCast beta commit `780ddc8`,
including the waiting state and the “Powered by RoomCast” footer, plus a
reconnect when the audio track ends so a restart on the same address comes
back. `reader.js` is the MediaMTX v1.21.2 file, byte for byte.

## Licence, size, battery, App Store

| | This proof |
| --- | --- |
| Licence | App code is MIT. Pion is MIT. `reader.js` is MediaMTX MIT. Opus is BSD and stays royalty-free. All four are acceptable in an App Store binary. Notices are in `THIRD_PARTY_NOTICES.md`. |
| Size | Not measured. gomobile bind needs macOS and Xcode, which this environment does not have. A device build of pion/webrtc is commonly tens of megabytes. The Opus objects are small next to that. Embedding MediaMTX would not be smaller. |
| Battery | The 32 kbps voice encode is cheap: 50 frames of a sine encoded immediately in the Linux round-trip. The Wi-Fi or hotspot radio dominates, and background audio keeps that radio up while the screen is locked. Personal Hotspot access-point mode is the hot case. Not measured on a device. |
| Heat | One to five listeners should be comfortable. There is no session cap. Each extra listener adds a PeerConnection, not another Opus encode. Many browser tabs on one computer, with the on-screen stats line, is the way to see CPU and thermal state. Not run on a device yet. |
| App Store | A local HTTP server plus a real microphone, with the `audio` background mode, is a normal audio app. Do not switch that mode to `voip`. mDNS is off, so there is no multicast entitlement and no Bonjour approval. The LAN address is shown as a QR code instead. `ITSAppUsesNonExemptEncryption` is false because the only cryptography is standard DTLS and SRTP. A privacy report is still required before any upload. The bundled privacy manifest declares no tracking and a File Timestamp reason (`C617.1`) because the Go runtime calls `stat`. That reason should be re-checked against the built binary before submission. |

## Latency

About 500 ms on Walter’s iPhone 15, by ear, with the 32 kbps voice preset.
That is the number to plan around. The design path is a 20 ms capture
period, Opus in VoIP mode, a browser jitter buffer, and a short LAN hop,
which on paper is closer to 100–200 ms. The extra delay is likely the
browser buffer, and it can be higher again on Personal Hotspot or with
AirPods in call mode. It is one phone’s observation, not a lab recording.

## What Walter confirmed on an iPhone 15

- Background audio while the screen is locked. The orange microphone
  indicator is the lock-screen signal.
- Two listeners, on Wi-Fi and on this iPhone’s Personal Hotspot.
- About 500 ms of delay. Audio quality was good at Opus 32 kbps mono, so
  that bitrate stays.
- iOS switches the input on its own: AirPods, the built-in mic, a USB sound
  card. There is no input picker.
- A network change did not rebind on the first device build. The next build
  rebound on the main thread, froze the UI, then worked. This revision
  shows Reconnecting… and runs that stop/start off the main actor. It has
  not been tried on a phone yet.

## What each listener costs

There is no listener cap. The old proof limit of 16 is gone, so a many-tab
test is not cut off by the server.

The microphone is encoded once, in the app, to one 32 kbps Opus packet.
`PublishOpus` hands that packet to a single `TrackLocalStaticSample`.
Pion packetizes it once, then walks every bound peer and rewrites the SSRC
and payload type before `WriteRTP`. Each peer’s write path encrypts its own
SRTP copy. Each listener is also its own `PeerConnection`: ICE, a DTLS
handshake, an SRTP context, and a goroutine reading RTCP.

So the encode does not grow with the room. What grows per listener is
encryption, sockets, and the radio sending another copy of the same 32 kbps
stream. A computer with many tabs on the same Wi-Fi shows the CPU and heat
of that fan-out without a room of phones. A Personal Hotspot still has its
own small client limit, which is separate from this server.

## Behaviour that is designed and not device-tested

- When the network changes, the app shows “Reconnecting…” immediately.
  `RoomcastStop` and `RoomcastStart` run on a background actor, not the
  main actor, then the QR code updates. The microphone stays up. Listeners
  whose page is still on that same address retry WHEP. A new IP means they
  need the new QR code or the Share link.
- Mute encodes silence and leaves the WebRTC sessions up. The on-screen
  meter keeps showing the mic. The app’s gain control is a slider from
  0.5× to 3×. The lock screen keeps minus and plus, because a Live Activity
  cannot host a slider. Control Center pause and play mute and unmute. If
  Live Activities are switched off, Start still broadcasts.
- Gain at 1× and below leaves the built-in mic’s voice-processing AGC on.
  That is the sensitive, clean sound. The slider used to multiply after
  that AGC and then hard-clip at ±1, so turning it up barely got louder
  while turning it down was obvious. `AVAudioSession.inputGain` cannot fix
  that: its range is 0 to 1, and the built-in mic usually is not settable.
  `.voiceChat` would add another session AGC. `.measurement` would turn
  the voice processing off. Above 1× the app switches off only the
  voice-processing AGC (`kAUVoiceIOProperty_VoiceProcessingEnableAGC`,
  property 2107), keeps echo control, and runs a software leveler that
  aims louder as the slider rises, then soft-clips. This has not been
  heard on a phone.
- Start and Stop paint “Starting…” or “Stopping…” (amber, spinner, taps
  ignored) before the gomobile call. Stop is red once the server is up.
  The QR code, URL, Share button, listener count, and meter are on screen
  only while live. Tap the listener count for a line with the count, app
  CPU percent, `ProcessInfo.thermalState`, and battery level.
- The lock-screen Live Activity has padding, the app logo, a teal Live
  pill, a filled level bar, and rounded icon buttons. The Now Playing card
  uses that logo, the title “RoomCast Go”, and the artist “Live · N
  listeners” (or “Muted · N listeners”).
- A phone call stops the microphone and does not tear down listener
  sessions. When the interruption ends, capture starts again. If iOS
  suspends the process anyway, the listener page retries WHEP on its own.
- Voice processing runs only for the built-in mic, so a headset is not run
  through speakerphone echo control. AirPods use the hands-free profile
  and will sound like a call.
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
- Read the stats line (tap the listener count) with one tab, then with
  many tabs on one computer: app CPU, thermal state, and battery. Do not
  promise the Mac venue size. A hotspot still has its own client limit.
- TestFlight, then a privacy report generated from the archive.

## What this environment verified

Linux, no iPhone, no Xcode, no Safari:

- `go test` in `Server/`: host selection (hotspot before Wi-Fi, cellular
  ignored, public addresses ignored), the listener page contract, two
  listeners receiving the same payloads, trickle ICE, and start/stop.
- `scripts/test-opus.sh`: the vendored encoder round-trips a 220 Hz sine
  (best correlation 0.99949 after the codec delay).

Not verified in this environment, because there is no iPhone and no macOS
SDK here: the SwiftUI compile (`xcodebuild` was not run), linking this
revision’s framework, Starting… / Stopping…, the tighter layout, the
off-main rebind, the gain leveler, the restyled Live Activity, Now Playing
artwork, or the stats line. Walter’s iPhone 15 already showed lock-screen
audio, two listeners, Personal Hotspot, and about 500 ms of delay on an
earlier build. Battery and heat are still unmeasured. This revision’s Go
change (no listener cap) needs `./scripts/build-server-framework.sh`
before that device build.
