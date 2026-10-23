# RoomCast Go

iPhone-only proof that a phone can host a **voice-only** RoomCast broadcast.
One screen: Start / Stop, a mute button, a mic-gain slider, and, while
live, a QR code, Share, the listener URL, a listener count, and a live
microphone meter. Tap the listener count for CPU, heat, and battery.
Opus mono at 32 kbps. No input picker: iOS switches the mic on its own.
While a broadcast is running, a Live Activity on the lock screen and in
the Dynamic Island shows the listener count, a level bar, and mute and
gain buttons.

Listeners open the same browser page as the Mac app, including the
“Powered by RoomCast” footer, and play over WebRTC. The iPhone runs the
listener server inside the app. iOS will not let an app launch the MediaMTX
helper the Mac uses. See [FINDINGS.md](FINDINGS.md) for why this build uses
an in-process Pion WHEP server, and for latency, battery, and App Store notes.

The app is iPhone only, iOS 17 or newer, portrait. Bundle id
`channel.roomcast.go`. It does not change the Mac app.

## What you need

- A Mac with Xcode 15 or newer, including the iOS 17 SDK. Open Xcode once so
  it finishes installing components. If `xcodebuild` is missing, run
  `sudo xcode-select -s /Applications/Xcode.app`.
- Go 1.26 or newer, Apple silicon. On a Mac, `brew install go` is the
  reliable install. An old Intel copy at `/usr/local/go` (a 2017 build is
  enough) is killed by macOS with exit 137 and hides a newer Go when it
  comes first on `PATH`. Open a new Terminal and check that `go version`
  prints `darwin/arm64` and `which go` is not `/usr/local/go/bin/go`.
- An iPhone on iOS 17 or newer, and a USB cable. The framework is built for
  a real device (`iphoneos` arm64). A simulator will not link.
- Your Apple Developer Program membership.

## What to create

Sign in first: Xcode → Settings → Accounts → add the Apple ID that belongs
to the developer team.

Prefer automatic signing. You do not create a certificate, profile, or key
by hand.

1. Open `ios/RoomCastGo/RoomCastGo.xcodeproj`.
2. Select the RoomCastGo target → Signing & Capabilities.
3. Leave “Automatically manage signing” on.
4. The project’s team is `6G2V545X95`. Leave the bundle id as
   `channel.roomcast.go`. The widget extension is
   `channel.roomcast.go.widget` on the same team.
5. Plug in the iPhone, select it as the run destination, and press Run.
   Xcode creates the App ID, the Apple Development certificate, and the
   development provisioning profile, and registers the phone’s UDID.

Do not add capabilities. This proof does not use Push Notifications,
Associated Domains, Multicast Networking, iCloud, or Sign in with Apple.
No `.p8` key is required.

If automatic signing fails, create these in
[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources):

| Thing | Exactly |
| --- | --- |
| App ID | Identifiers → App IDs → App. Description `RoomCast Go`. Explicit bundle ID `channel.roomcast.go`. Leave every capability unchecked. |
| Device | Devices → add the iPhone. The UDID is in Xcode → Window → Devices and Simulators. |
| Certificate | Certificates → Apple Development. Creating it from Xcode (the automatic path above) is enough. A certificate signing request is only needed if you make the certificate on the website. |
| Profile | Profiles → iOS App Development. App ID `channel.roomcast.go`, that development certificate, that iPhone. Name it `RoomCast Go Development`. Download it and double-click it. Then switch the target to manual signing and pick that profile. |
| App Group | Identifiers → App Groups → `group.channel.roomcast.go`. Then on both App IDs below, enable App Groups and select that group. |
| Widget App ID | Identifiers → App IDs → App. Description `RoomCast Go Widget`. Explicit bundle ID `channel.roomcast.go.widget`. Enable only App Groups, and select `group.channel.roomcast.go`. |

Nothing else. No APNs key, no push certificate, no Sign in with Apple key,
no App Store Connect app record until you want TestFlight. The lock screen
card is a local Live Activity, not a remote push.

Press Run once before creating those by hand. Automatic signing often
registers the widget App ID and the App Group. Create them in the portal
only if Xcode reports a signing error for the widget or the App Group.

On the iPhone, Settings → RoomCast Go → Live Activities should be on if you
want the lock screen card. The broadcast still runs if that switch is off.

## Build and run

```bash
cd ios/RoomCastGo
./scripts/build-server-framework.sh
open RoomCastGo.xcodeproj
```

The Xcode project is generated from `project.yml`. If Xcode says it is not a
valid property list, regenerate it from `ios/RoomCastGo`:

```bash
brew install xcodegen && xcodegen
```

The script needs a network connection the first time. It installs a pinned
`gomobile` and writes `build/Roomcast.xcframework` (gitignored). The first
build takes a few minutes.

In Xcode, choose your iPhone in the destination menu, not a simulator, and
press Run. Trust the developer on the phone if iOS asks
(Settings → General → VPN & Device Management).

On the phone, allow Microphone and Local Network. If you deny one of them:

- Settings → Privacy & Security → Microphone → RoomCast Go
- Settings → Privacy & Security → Local Network → RoomCast Go

Press Start. The orange microphone dot means the phone is capturing. Another
phone on the same Wi-Fi scans the QR code, or you tap Share and send the
URL by Messages or AirDrop. The page starts muted, the same way the Mac
listener page does, so the browser will allow autoplay. Tap the speaker
icon. The host’s lock screen keeps the broadcast running. Start and Stop
show Starting… or Stopping… until the server answers, so a second tap does
not undo the first. Mute sends silence and leaves the listeners connected.
The gain slider runs from 0.5× to 3×. At 1× the built-in mic keeps its
usual voice processing. Above 1× that automatic gain switches off so the
boost can be heard. A phone call pauses the microphone and the broadcast
resumes when the call ends. Tap the listener count while live for the
listener count, app CPU, thermal state, and battery.

Plug the phone in for a long event. The meter on the main screen is the
live mic level. The lock screen meter updates about once a second.

If the iPhone changes networks, the app rebinds the server and refreshes
the QR code. Listeners who still have the same address reconnect on their
own. If the address changed, they need the new code or the new shared link.
Control Center’s pause and play buttons mute and unmute.

## Personal Hotspot

When Personal Hotspot is on, the QR code uses `http://172.20.10.1:8889/`.
Listeners must join **this iPhone’s** hotspot, then scan. They cannot be on
venue Wi-Fi at the same time.

Limits, compared with the Mac app’s venue target of about 30 phones:

- A Personal Hotspot client cap is small. Apple’s commonly cited limit is
  about 5 clients, and it varies by model and iOS version.
- The hotspot radio, not the 32 kbps encoder, is the battery and heat cost.
- Low Power Mode, and on some iOS versions a locked screen, can drop the
  hotspot even while the app still holds the microphone.
- “Maximize Compatibility” forces 2.4 GHz. That is the more reliable choice
  for a mixed bag of listener phones.
- While this iPhone is the hotspot, it is generally not also a client of the
  venue Wi-Fi, so the QR address will not be a venue address.

Same-Wi-Fi mode (the iPhone joined to a normal network, listeners on that
network) is the closer match to the Mac app. The server does not cap the
session list. One Opus encode is shared. Each listener adds a WebRTC
session and its own encryption. Many browser tabs on one computer is a way
to see that cost. It is not a promise that a hotspot full of phones will
sound fine. See [FINDINGS.md](FINDINGS.md).

## If the build or the broadcast fails

- **Xcode says the project is not a valid property list**: from
  `ios/RoomCastGo`, run `brew install xcodegen && xcodegen`.
- **“Roomcast.xcframework is missing”**, or you just pulled a change to
  the listener page or the Go server: run `./scripts/build-server-framework.sh`
  from `ios/RoomCastGo`, then build again. The page and the server are
  compiled into the framework. The current branch removed the 16-listener
  cap, so rebuild before the many-tab test.
- **Widget or App Group signing error**: create `group.channel.roomcast.go`
  and the App ID `channel.roomcast.go.widget` as in the table above, enable
  the group on both `channel.roomcast.go` and `channel.roomcast.go.widget`,
  then build again.
- **Go is too old, not Apple silicon, or macOS kills `go` with exit 137**:
  `which go` is probably an old Intel build at `/usr/local/go/bin/go`.
  Run `brew install go`, open a new Terminal, and confirm `which go` is
  `/opt/homebrew/bin/go` and `go version` says `darwin/arm64`.
- **Run destination is a simulator**: switch to the plugged-in iPhone. The
  framework has no simulator slice.
- **Port already in use**: another RoomCast Go (or the Mac app) is already
  bound to 8889 or 8189 on this phone. Stop it and press Start again.
- **Xcode console says `answer candidates: 0`**: the page can load and still
  stay silent. Local Network permission is the usual cause. Also confirm
  the listener phone is on the same network as the address in the QR code.
- **Page loads, no sound**: tap the speaker icon on the page, and raise the
  listener phone’s volume.
- **AirPods sound like a phone call**: the system selects the headset
  automatically. A Bluetooth headset uses the hands-free profile, which is
  16 kHz call quality. That is the same class of limit as the Mac app.
- **Export compliance** if you archive: the app uses standard WebRTC
  encryption only. `ITSAppUsesNonExemptEncryption` is already `false`.
  Answer that the app uses exempt encryption.

## What is already proven

On Walter’s iPhone 15: the broadcast kept going with the screen locked,
two listeners worked including over Personal Hotspot, and the delay was
about 500 ms. Opus stays at 32 kbps. iOS picked the input (AirPods, the
built-in mic, a USB sound card) without a picker.

On a Linux machine, without an iPhone: the WHEP server accepts the same
offer shape as the listener page, two listeners receive the same packets,
seventeen sessions are accepted, and the vendored Opus encoder round-trips
a sine wave. The network restart, mute, gain, Share, Live Activity, and
stats line were not run on a phone here. Battery and heat are still
unmeasured. `xcodebuild` was not run here.
[FINDINGS.md](FINDINGS.md) lists each of those.

Licences: [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
