# RoomCast Go

iPhone-only proof that a phone can host a **voice-only** RoomCast broadcast.
One screen: Start / Stop, a QR code, the listener URL, a listener count, and
a microphone meter. Opus mono at 32 kbps. No settings.

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
- Go 1.26 or newer from https://go.dev/dl/. The server tests run on older Go;
  building the iPhone framework does not. Quit and reopen Terminal after
  installing so `go version` shows 1.26 or newer.
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
4. Set Team to your team. Leave the bundle id as `channel.roomcast.go`.
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

Nothing else. No APNs key, no Sign in with Apple key, no App Store Connect
app record until you want TestFlight.

## Build and run

```bash
cd ios/RoomCastGo
./scripts/build-server-framework.sh
open RoomCastGo.xcodeproj
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
phone on the same Wi-Fi scans the QR code, opens the page, and taps the
speaker icon. The page starts muted, the same way the Mac listener page
does, so the browser will allow autoplay. The host’s lock screen should keep
the broadcast running. A phone call pauses the microphone and the broadcast
resumes when the call ends.

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
network) is the closer match to the Mac app. The server still caps the
session list at 16. That cap is a safety limit for this proof, not a promise
that 16 listeners will sound fine.

## If the build or the broadcast fails

- **“Roomcast.xcframework is missing”** in Xcode: run
  `./scripts/build-server-framework.sh` from `ios/RoomCastGo`, then build again.
- **“Go is too old”**: install Go 1.26 or newer and open a new Terminal.
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

On a Linux machine, without an iPhone: the WHEP server accepts the same
offer shape as the listener page, two listeners receive the same packets,
and the vendored Opus encoder round-trips a sine wave. A real iPhone is
still required for the microphone, the lock screen, phone-call
interruptions, AirPods, Personal Hotspot, latency, battery, and heat.
[FINDINGS.md](FINDINGS.md) lists each of those.

Licences: [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
