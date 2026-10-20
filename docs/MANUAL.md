# Public EarFi user manual

This guide is for the person running the event. You do not need to be comfortable with networks or audio software. Listeners do even less: they join a Wi-Fi network, scan a QR code, and listen in the browser. They do not install an app or sign in.

Public EarFi sends sound from a Mac to phones in the same room. The usual job is a live interpreter, with about 30 listeners on venue Wi-Fi. The audio stays on the local network. It is not uploaded to the internet, and the app does not record.

The full setup that is available today uses a **Mac as the server**. A **phone as the server** is a planned future app. It is described at the end so you can see where this is going. Do not plan an event around the phone app until it exists.

## What to bring

- A Mac with macOS 13 Ventura or later (Apple silicon or Intel).
- Public EarFi, installed in the Applications folder.
- The sound source: a USB or Thunderbolt audio interface from the sound desk, or the Mac’s built-in microphone for a small room.
- Your own small Wi-Fi network for the phones and the Mac. A portable or travel router is the reliable choice. The venue’s Wi-Fi often blocks phones from seeing each other.
- Power for the Mac and that router. Closing the laptop lid puts the Mac to sleep.

## Two ways to run the server

| | Mac as the server | Phone as the server |
|---|---|---|
| Status | Available now. This is the Public EarFi Mac app. | Planned. There is no phone app yet. |
| What the server does | The Mac takes the sound and serves it to the phones. | A future phone app would do that job, so you might leave the Mac at home. |
| What listeners do | Join the Wi-Fi, scan the listen QR, and press play in the browser. | The same listener steps are the goal. |
| What you should do now | Follow the rest of this manual. | Read the planned section at the end, then use the Mac. |

## Bring your own network

Venue Wi-Fi often blocks this. Guest networks isolate each phone, so a phone can reach the internet and still be unable to reach the Mac. Bring a small network of your own and the venue’s Wi-Fi no longer matters.

Any portable or travel Wi-Fi router will do. It does not need an internet connection. Public EarFi only needs the phones and the Mac on that same private Wi-Fi.

What to look for when you buy or borrow one:

- It can handle about 30 devices at once, or more.
- It can reserve a fixed address for the Mac (sometimes called a DHCP reservation, a static lease, or address binding).

A phone’s personal hotspot usually stops at about 5 to 10 devices. That is fine for a rehearsal or a handful of listeners. It is too small for about 30 people.

The useful part is doing this at home, before the event. Set up the router and the Mac, listen on your own phone, and confirm it works. Give the Mac a fixed address on that router so the listener link stays the same next time you power everything on. The QR code contains that address, for example `http://192.168.1.20:8889/live`. When the address stays put, you can print the poster or email the PDF days ahead, including a “join this Wi-Fi” step.

The app warns you if the Mac’s address has changed since the poster was made. If you have to use the venue’s network instead, ask them for a fixed address for the Mac.

### Name the Wi-Fi on the poster

Listeners have to join your network before the listen QR will work. In the poster window, fill in **Wi-Fi network name**. The first printed step becomes “Join the Wi-Fi network” followed by that name. The line is hidden when the name is empty, so type the name you want people to see.

**Use current network name** fills in the Wi-Fi the Mac can see. If that button is missing, type the name yourself.

### Optional: a second QR code that joins the Wi-Fi

Public EarFi’s QR code is the listen link only. The app does not draw a Wi-Fi-join code. You can make one yourself and place it beside the listen QR, on the same sheet or in the same email. A phone camera can join the network from that code before the person scans the listen code.

Any QR generator can turn a single line of text into an image. Use a simple password of letters and numbers. For a network with the usual WPA password, the text is:

```text
WIFI:T:WPA;S:Interpreter;P:thepassword;;
```

Replace `Interpreter` with the Wi-Fi name and `thepassword` with the password. Keep the semicolons. Label that image “1. Join the Wi-Fi” and label the Public EarFi image “2. Listen”.

## Set it up at home, then test it

Do this once, on the Wi-Fi you will take to the venue.

1. Turn on your router. It does not need the internet.
2. Join the Mac to it, with the Mac’s address reserved so it stays the same.
3. Install Public EarFi and open it (the next section). Allow the microphone. If the firewall asks, allow incoming connections for mediamtx. That program is what the phones connect to.
4. Plug in the audio interface, or use the built-in microphone for this test. In Settings, choose the input. Leave quality on **Speech 32k**.
5. Watch the level meter on the main window. Talk, or play the desk. The meter moves before you go live. If it stays empty, the Mac is listening to the wrong input.
6. Press **Start Broadcasting**. The window should say Live and show a link like `http://192.168.1.20:8889/live`.
7. On your phone, join that same Wi-Fi. A phone still on the house network will not open the link.
8. Scan the QR code, or type the link. Tap play. If you hear nothing, unmute using the listener steps below.
9. Fill in the poster, including the Wi-Fi name, and export the PDF. Email it to yourself and open it on the phone. The QR code in that PDF should still open the stream.
10. Stop the broadcast. Power the router off and on, start the Mac again, and confirm the listener link is unchanged.

Take the same router, the same Mac, and that PDF to the event.

## Install and first open

1. Download `Public-EarFi-x.y.z.dmg` from the GitHub Releases page.
2. Open the disk image and drag **Public EarFi** to **Applications**. Running it from the disk image or from Downloads makes macOS treat it as untrusted, and it then behaves oddly.
3. Open Public EarFi from the Applications folder.
4. Allow the microphone when asked. That permission is how the app hears the sound desk.
5. If macOS asks about incoming connections for mediamtx, allow them.

The app is ad-hoc signed, or signed with a self-made certificate. It is not notarized, so each Mac needs a one-time approval. There is no paid Apple Developer account. The same steps are in `docs/FIRST-OPEN.txt`, which the disk image copies as **Read Me First.txt**. This manual is copied onto the disk image as **User Manual.md**.

### macOS 15 Sequoia and later

1. A dialog says *"Public EarFi" Not Opened – Apple could not verify…*. Click **Done**. Do not click Move to Trash.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security**, find *"Public EarFi was blocked…"*, and click **Open Anyway**.
4. Confirm with your password or Touch ID, then click **Open**.

Right-click → Open does not bypass this dialog on macOS 15 or later.

### macOS 13 and 14

Control-click (right-click) Public EarFi in Applications → **Open** → **Open**. The **Open Anyway** button in System Settings → Privacy & Security works as well.

### After an update

Repeat the first-open steps. Each download is quarantined again. With ad-hoc signing, macOS may also ask for the microphone again. If you previously clicked Don’t Allow, go to System Settings → Privacy & Security → Microphone.

If macOS says the app **is damaged**, the download or the signature is broken. Download it again. If it still fails, use **Copy diagnostics** on the main window and report the bug.

## Choose the input

Open **Public EarFi → Settings…** (Command-,). Settings is in the app menu, under the Public EarFi name. It is not in the File menu.

- **Device.** Pick the USB interface. If you have not chosen one yet, the app prefers a USB interface over the built-in microphone.
- **Channels.** For an interpreter feed, leave this on **Mono** and choose the input the desk is using, often Input 1. Stereo is for a left-and-right feed.
- **Level meter.** It is on the main window, and it works before Start. No movement means the desk is not reaching that input, or the channel number is wrong.

## Leave the quality on Speech

**Speech 32k** is the default, and it is the right preset for a live interpreter. It is mono and 32 kbps. Choosing Speech sets those. The app always sends 48 kHz audio in small 20 ms pieces. There is no sample-rate menu, and you do not change the rate in Audio MIDI Setup.

That uses the least Wi-Fi. Standard and Music use more for the same number of listeners.

Standard (64 kbps) and Music (96 kbps mono, or 128 kbps stereo) use more of the Wi-Fi for the same number of listeners. Speech is the one sized for about 30 phones.

**TCP only**, under Network mode, is the setting to try if listeners hear dropouts on Wi-Fi. Auto is the normal choice.

**Keep Mac awake while broadcasting** is on by default. The Mac still sleeps if you close the lid, unless it is on power with an external display. Leave the lid open, or plug in a screen.

## The poster and the QR code

**File → Print Poster…** (Command-P) opens the poster window. **File → Export Poster PDF…** (Command-Shift-E) saves a PDF without opening that window. The poster window also has Export PDF, Print, and Copy QR image. The Edit menu can copy the listener link and the QR image.

On the poster you can set:

- A header. The default is “Listen live on your phone”.
- A short description, such as the talk title.
- Instructions. The defaults tell people to join the Wi-Fi, scan the code, tap play, keep the screen on, and unmute.
- The Wi-Fi network name, which fills in `{network}` in the first instruction.
- Paper size. Letter in the US and Canada, A4 elsewhere, unless you pick one.
- Address style. **IP** is the one to use. The `.local` name survives an address change on iPhone, iPad, and Mac, and fails on many Android phones, so leave the poster on IP when the address is reserved.

Default listener steps, once the Wi-Fi name is filled in:

1. Join the Wi-Fi network, followed by the name you typed.
2. Scan the QR code or type the address below.
3. Tap play, and keep the screen on. Locking the phone may pause the audio.
4. No sound? Tap the speaker/mute icon on the player or in the browser tab, and turn the phone volume up.

Export the PDF after the home test, when the link is the reserved address. Email that PDF, or print it. People can arrive, join the Wi-Fi, and scan a code you published beforehand.

If you later see a warning that the address changed since the poster was made, the printed code is stale. Fix the reservation, or make a new poster. Do not tell people to keep using the old one.

## What to tell listeners

Say this in the room, and leave it on the poster:

- Join the named Wi-Fi first. A phone that is still on the venue’s Wi-Fi, or on mobile data, cannot open the link.
- Scan the listen QR code, or type the address. Tap play.
- If there is silence, tap the speaker or mute icon on the player and in the browser tab, then turn the phone volume up. Phones often start a web player muted.
- Keep the screen on and the browser in front. Locking the phone, or leaving the browser, may pause the audio.
- Plug the phone in for a long session.

There is no password on the stream. Anyone on that Wi-Fi who has the link can listen. The Wi-Fi password is what keeps strangers off your own network.

## On the day

1. Turn on your own Wi-Fi. It does not need the internet.
2. Join the Mac to it and open Public EarFi. Confirm the listener link matches the poster.
3. Connect the sound desk to the interface. Check the level meter.
4. Press **Start Broadcasting**.
5. Listen on your own phone once, on that Wi-Fi, before people arrive.
6. Put the poster where people can scan it. Remind them about the Wi-Fi name and the unmute step.
7. The main window shows how many people are listening, and one health line. **View → Show Log** (Command-L) opens the longer log if you need it.

Stop with **Stop Broadcasting** when the session ends. Quitting the app also stops the stream.

## Bandwidth

Every listener is their own copy of the audio. At the Speech preset each copy is about **32 kbps** (kilobits per second).

Multiply:

**listeners × 32 kbps ÷ 1000 = megabits per second of audio**

| Listeners | Audio at Speech (32 kbps each) |
|---|---|
| 10 | 0.32 Mbps |
| 30 | 0.96 Mbps, about 1 Mbps |
| 50 | 1.6 Mbps |

About **30 listeners is about 1 Mbps** of audio. The network also carries a little protocol overhead, so leave some spare room. Settings shows this for the current quality as “30 listeners ≈ 0.96 Mbps”.

The same 30 people at Standard 64 kbps would be about 1.9 Mbps. That is why Speech stays the default for an interpreter on Wi-Fi.

Your own Wi-Fi still has to carry that 1 Mbps, plus a little overhead, shared among the phones. Thirty listeners is the size this setup is aimed at. A larger room needs a rehearsal on that same Wi-Fi before you promise it.

## Troubleshooting

| What you see | What to do |
|---|---|
| macOS says the app was not opened, or is from an unidentified developer | Use the Open Anyway steps above. On macOS 15, click Done first, then System Settings → Privacy & Security → Open Anyway. |
| macOS says the app is damaged | Download it again. Drag a fresh copy to Applications. |
| The level meter does not move | The desk is not feeding that input, or Mono / Input is the wrong channel. Try the other input number. |
| Your test phone will not open the link | The phone is on a different Wi-Fi. Join the same network as the Mac. Turn mobile data off for the test if the phone keeps leaving that network. |
| Listeners in the venue cannot connect | They are on the venue Wi-Fi, or that Wi-Fi isolates clients. Move them to your own Wi-Fi. If you must use the venue network, ask for a fixed address for the Mac. |
| The link used to work and now times out | The Mac’s address changed. Check the reservation, then compare the on-screen link with the poster. Make a new poster if they differ. |
| People connect and hear nothing | Tap play. Tap the speaker/mute icon on the player and in the browser tab. Turn the phone volume up. Keep the screen on. |
| The sound breaks up, or you hear a regular click | Leave quality on Speech. In Settings, try **TCP only**. |
| The Mac slept | The lid was closed, or it was on battery and idle. Power is connected, the lid is open, and “Keep Mac awake while broadcasting” is on. |
| The microphone prompt appears after an update | Expected. Allow it again. See Install and first open. |
| You quit the app hard and it says a port is busy | Open Public EarFi again. It stops leftover helper programs it started. |

**Copy diagnostics** on the main window puts the version, the settings, and the recent log on the clipboard. That is the useful thing to attach to a bug report. Logs are also in `~/Library/Logs/Public EarFi/`.

## Phone as the server (planned)

A future Public EarFi app on a phone would let that phone be the server: it would take the sound and serve the same kind of browser link and QR code. Listeners would still join the Wi-Fi and listen in the browser, without installing anything.

That app is not available. There is nothing to download, and this manual’s install steps are for the Mac only. Use the Mac as the server, with your own Wi-Fi and the home test above, for every event until a phone server is actually released.

## Limits worth knowing

- The stream is local. People off your Wi-Fi cannot listen, including people at home.
- There is no recording in the app.
- About 30 phones at Speech is the target. It still has to be tried once in a real room.
- Phone operating systems may pause the audio when the screen locks or the browser is in the background.
