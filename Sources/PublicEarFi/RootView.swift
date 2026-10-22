import AppKit
import PublicEarFiCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack {
      BroadcastBackdrop(live: model.isBroadcasting, level: model.levelFraction)
        .ignoresSafeArea()
      RunningTab()
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("RoomCast 1.0 Beta Release")
    .background {
      // Zero size so this AppKit view cannot paint over the hero.
      MainWindowTitle(title: "RoomCast 1.0 Beta Release")
        .frame(width: 0, height: 0)
    }
    .preferredColorScheme(.dark)
    .toolbarBackground(AppChrome.window, for: .windowToolbar)
    .onAppear { model.onAppear() }
    .sheet(isPresented: $model.showFirstRun) { FirstRunSheet() }
    .sheet(isPresented: $model.showWhy) { WhySheet() }
    .sheet(isPresented: $model.showQR) { QRSheet() }
    .alert("Allow incoming connections?", isPresented: $model.showFirewall) {
      Button("Continue") { model.confirmFirewallAndStart() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "If the macOS firewall is on, it will ask to allow incoming connections for mediamtx. That is the listener server. Choose Allow. If phones cannot connect later, check System Settings → Network → Firewall."
      )
    }
  }
}

struct Card<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @ViewBuilder var content: () -> Content

  var body: some View {
    let stack = VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)

    #if compiler(>=6.2)
      if #available(macOS 26, *), !reduceTransparency {
        // Each card keeps its own dark fill. A shared glass container had
        // merged these sections into one panel, so the glass stays inside
        // this card's rounded rectangle. Reduce Transparency skips the glass
        // so the card stays a solid plate and the hero still shows in the gaps.
        stack
          .background {
            RoundedRectangle(cornerRadius: 8)
              .fill(AppChrome.card)
            RoundedRectangle(cornerRadius: 8)
              .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
          }
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppChrome.cardBorder))
      } else {
        stack.modifier(OpaqueCardPlate())
      }
    #else
      stack.modifier(OpaqueCardPlate())
    #endif
  }
}

/// Separate dark card used on macOS 13–15, and the same shape on macOS 26.
private struct OpaqueCardPlate: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(AppChrome.card)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppChrome.cardBorder))
  }
}

/// Sets the main window title. `navigationTitle` does not always reach the
/// title bar of a plain window group.
private struct MainWindowTitle: NSViewRepresentable {
  var title: String

  func makeNSView(context: Context) -> TitleView {
    let view = TitleView()
    view.title = title
    return view
  }

  func updateNSView(_ view: TitleView, context: Context) {
    view.title = title
    view.window?.title = title
  }
}

private final class TitleView: NSView {
  var title = ""

  override var isOpaque: Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.title = title
    // Navy field. The dimmed hero shows in the gaps the cards do not cover.
    window?.backgroundColor = AppChrome.windowNSColor
  }
}

enum AppChrome {
  static let windowRed = 22.0 / 255
  static let windowGreen = 26.0 / 255
  static let windowBlue = 66.0 / 255
  /// Dark navy behind the dimmed hero. #161a42
  static let window = Color(red: windowRed, green: windowGreen, blue: windowBlue)
  static var windowNSColor: NSColor {
    NSColor(srgbRed: windowRed, green: windowGreen, blue: windowBlue, alpha: 1)
  }
  /// Separate card fill. #1c1f3a
  static let card = Color(red: 28.0 / 255, green: 31.0 / 255, blue: 58.0 / 255)
  static let cardBorder = Color.white.opacity(0.14)
  /// Section headings and the level meter. #2fd0bd
  static let heading = Color(red: 47.0 / 255, green: 208.0 / 255, blue: 189.0 / 255)
  /// Start, copy, settings, and the other primary actions. #8b5cf6
  static let primary = Color(red: 139.0 / 255, green: 92.0 / 255, blue: 246.0 / 255)
  /// Ko-fi, Patreon, and Buy Me a Coffee. #f472b6
  static let support = Color(red: 244.0 / 255, green: 114.0 / 255, blue: 182.0 / 255)
  static let stopButton = Color(red: 0.84, green: 0.25, blue: 0.18)
  /// The website hero stays visible in the gaps, softer than the cards.
  static let heroOpacity = 0.72
}

struct SectionLabel: View {
  var text: LocalizedStringKey

  var body: some View {
    Text(text)
      .textCase(.uppercase)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(AppChrome.heading)
      .tracking(0.6)
  }
}

struct RunningTab: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 48, height: 48)
          .accessibilityLabel("RoomCast")
        Spacer()
      }

      Card {
        SectionLabel(text: "Broadcast")
        HStack(spacing: 8) {
          Circle().fill(statusColor).frame(width: 10, height: 10)
          Text(model.statusLine()).fontWeight(.semibold)
        }
        BroadcastButton(
          title: buttonTitle,
          isStop: isStop,
          showsProgress: isStarting
        ) {
          model.toggleBroadcast()
        }
        if case .stopped = model.phase {
          GreenPushButton("Change Sound Source") { model.openSettings() }
        }
        if let stray = model.strayHelper {
          Text(
            "A leftover \(stray.processName) (pid \(stray.pid)) is using port \(stray.port)."
          )
          .font(.caption)
          Button("Stop leftover helper") { model.stopStrayHelper() }
        }
        HStack {
          Text("Input level").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
          LevelBar(fraction: model.levelFraction)
          Text(levelText).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        HStack {
          Text("Volume").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
          Slider(value: gainBinding, in: InputGain.minimumDB...InputGain.maximumDB)
            .tint(AppChrome.heading)
          Text(InputGain.label(model.settings.inputGainDB))
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
        }
        .help(
          "Volume, from -12 dB to +24 dB. Changes apply immediately, including while you are live."
        )
        Text(
          "0db leaves the volume unchanged. Increase or decrease the broadcast's volume."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if model.noSignal {
          Text("No signal for about 5 seconds. Check the desk feed and the selected input.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      if let stale = model.staleAddress {
        WarningBanner(text: stale.message) { model.showWhy = true }
      }
      if model.onBattery && model.isBroadcasting {
        WarningBanner(
          text:
            "Running on battery. Plug in power for a long session. Closing the lid still sleeps the Mac."
        ) {
          model.showWhy = true
        }
      }

      Card {
        SectionLabel(text: "Listen")
        HStack(alignment: .top, spacing: 14) {
          Button {
            model.showQR = true
          } label: {
            qrView(side: 112)
          }
          .buttonStyle(.plain)
          .help("Show the QR code full screen")
          VStack(alignment: .leading, spacing: 6) {
            Text(model.listenerURL ?? "No LAN address yet")
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .padding(6)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color(nsColor: .controlBackgroundColor))
              .clipShape(RoundedRectangle(cornerRadius: 5))
            if let secondary = model.secondaryURL {
              Text(secondary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if model.settings.urlStyle == .localHostname {
              Text("Some Android phones can't open .local addresses.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
              GreenPushButton("Copy link") { model.copyLink() }
                .disabled(model.listenerURL == nil)
              GreenPushButton("Open PDF QR Poster") { model.openQuickPosterPDF() }
                .disabled(model.listenerURL == nil)
                .help("Save a PDF of the QR poster and open it. Print that PDF yourself.")
            }
            if model.rankedNetworks.count > 1 {
              Picker("Address", selection: addressBinding) {
                Text("Auto").tag(nil as String?)
                ForEach(model.rankedNetworks) { candidate in
                  Text("\(candidate.name) \(candidate.address)").tag(Optional(candidate.address))
                }
              }
              .frame(maxWidth: 220)
            }
            SectionLabel(text: "Listening now")
            Text("\(model.listeners)")
              .font(.system(size: 32, weight: .bold))
          }
        }
      }

      Card {
        SectionLabel(text: "Health")
        Text(model.healthLine)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.yellow.opacity(0.18))
          .clipShape(RoundedRectangle(cornerRadius: 5))
        GreenPushButton("Copy diagnostics") { model.copyDiagnostics() }
      }
      Card {
        SectionLabel(text: "Please Consider Supporting this Project")
        SupportLinks()
      }
      if model.hasPendingChanges {
        WarningBanner(
          text:
            "Settings changed. Apply now (brief interruption), or they take effect on the next Start.",
          buttonTitle: "Apply New Settings Now"
        ) {
          model.applyNow()
        }
      }
      Spacer(minLength: 8)
      HStack {
        Spacer()
        GreenPushButton("Getting Started") { model.reopenGettingStarted() }
        Spacer()
      }
    }
  }

  private var isStarting: Bool {
    if case .starting = model.phase { return true }
    return false
  }

  private var isStop: Bool {
    switch model.phase {
    case .stopped, .starting, .blocked:
      return false
    default:
      return true
    }
  }

  private var buttonTitle: String {
    switch model.phase {
    case .starting:
      return "Starting…"
    case .stopped, .blocked:
      return "Start Broadcasting"
    default:
      return "Stop Broadcasting"
    }
  }

  private var statusColor: Color {
    switch model.phase {
    case .live:
      return AppChrome.heading
    case .starting:
      return .orange
    case .stopped:
      return .gray
    default:
      return .red
    }
  }

  private var levelText: String {
    if model.levelDB <= -100 { return "— dB" }
    return String(format: "%.0f dB", model.levelDB)
  }

  private var gainBinding: Binding<Double> {
    Binding(
      get: { model.settings.inputGainDB },
      set: { model.setInputGain($0) }
    )
  }

  private var addressBinding: Binding<String?> {
    Binding(
      get: { model.settings.advertisedAddress },
      set: { value in model.mutate { $0.advertisedAddress = value } }
    )
  }

  @ViewBuilder
  private func qrView(side: CGFloat) -> some View {
    if let image = model.qrImage {
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .frame(width: side, height: side)
    } else {
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color.gray.opacity(0.4))
        .frame(width: side, height: side)
    }
  }
}

enum AppLinks {
  static let kofi = URL(string: "https://ko-fi.com/roomcast")!
  static let patreon = URL(string: "https://www.patreon.com/roomcastapp")!
  static let buyMeACoffee = URL(string: "https://buymeacoffee.com/roomcast")!
}

/// Ko-fi, Patreon, and Buy Me a Coffee, in the card under Health.
struct SupportLinks: View {
  var body: some View {
    HStack(spacing: 10) {
      GreenLinkButton("Ko-fi", destination: AppLinks.kofi, fill: AppChrome.support)
      GreenLinkButton("Patreon", destination: AppLinks.patreon, fill: AppChrome.support)
      GreenLinkButton(
        "Buy Me a Coffee", destination: AppLinks.buyMeACoffee, fill: AppChrome.support)
    }
    .frame(maxWidth: .infinity)
  }
}

/// Solid violet fill and white text on every macOS version. The glass button
/// style drew black on black on macOS 26, so these controls keep the solid fill.
struct GreenPushButton: View {
  var title: LocalizedStringKey
  var fill: Color
  var action: () -> Void

  init(
    _ title: LocalizedStringKey, fill: Color = AppChrome.primary, action: @escaping () -> Void
  ) {
    self.title = title
    self.fill = fill
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      SolidGreenLabel(title: title, large: false, fill: fill)
    }
    .buttonStyle(.plain)
  }
}

struct GreenLinkButton: View {
  var title: LocalizedStringKey
  var destination: URL
  var fill: Color

  init(_ title: LocalizedStringKey, destination: URL, fill: Color = AppChrome.primary) {
    self.title = title
    self.destination = destination
    self.fill = fill
  }

  var body: some View {
    Link(destination: destination) {
      SolidGreenLabel(title: title, large: false, fill: fill)
    }
    .buttonStyle(.plain)
  }
}

/// Start stays large and violet. Stop stays solid red. Both keep a solid fill
/// so the label stays readable on macOS 26.
struct BroadcastButton: View {
  var title: String
  var isStop: Bool
  var showsProgress: Bool
  var action: () -> Void

  var body: some View {
    solid
  }

  private var label: some View {
    HStack(spacing: 8) {
      if showsProgress {
        ProgressView().controlSize(.small)
      }
      Text(title)
        .font(.title2.bold())
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
  }

  private var solid: some View {
    Button(action: action) {
      label
        .foregroundStyle(.white)
        .background(isStop ? AppChrome.stopButton : AppChrome.primary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
  }
}

private struct SolidGreenLabel: View {
  var title: LocalizedStringKey
  var large: Bool
  var fill: Color

  var body: some View {
    Text(title)
      .font(large ? .title2.bold() : .callout.weight(.semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, large ? 16 : 12)
      .padding(.vertical, large ? 12 : 6)
      .frame(maxWidth: large ? .infinity : nil)
      .background(fill)
      .clipShape(RoundedRectangle(cornerRadius: large ? 10 : 8))
      .contentShape(RoundedRectangle(cornerRadius: large ? 10 : 8))
  }
}

struct LevelBar: View {
  var fraction: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.15))
        RoundedRectangle(cornerRadius: 3)
          .fill(AppChrome.heading)
          .frame(width: geometry.size.width * min(1, max(0, fraction)))
      }
    }
    .frame(height: 12)
  }
}

struct WarningBanner: View {
  var text: String
  var buttonTitle: String = "Why?"
  var action: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      Text(text).font(.caption)
      Spacer()
      Button(buttonTitle, action: action).font(.caption)
    }
    .padding(8)
    .background(Color.yellow.opacity(0.35))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

struct SettingsTab: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmReset = false
  @State private var closeSettingsRequest = 0

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        settingsForm
      }
      settingsSaveRow
    }
    .background(AppChrome.window)
    .background(CloseSettingsWindow(request: closeSettingsRequest))
    .background(
      EscapeCloser {
        model.saveAndCloseSettings()
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .id(model.settingsRevision)
    .sheet(isPresented: $model.showCredits) { CreditsSheet() }
    .alert(
      "Reset every setting, including the poster text and the Wi-Fi password?",
      isPresented: $confirmReset
    ) {
      Button("Reset to defaults", role: .destructive) { model.resetDefaults() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Logs are kept. The Wi-Fi password is removed from the Keychain. The defaults are saved immediately. If you are live, they apply on the next Start."
      )
    }
  }

  private var settingsSaveRow: some View {
    HStack {
      GreenPushButton("Save and Close") {
        model.saveAndCloseSettings()
        closeSettingsRequest += 1
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var settingsForm: some View {
    VStack(alignment: .leading, spacing: 12) {
      Card {
        SectionLabel(text: "Audio input")
        LabeledRow(title: "Device") {
          Picker("Device", selection: deviceBinding) {
            Text("Automatic").tag(String?.none)
            ForEach(model.devices) { device in
              Text(device.name).tag(Optional(device.id))
            }
            if let uid = model.settings.inputDeviceUID,
              !model.devices.contains(where: { $0.id == uid })
            {
              Text("Not connected").tag(Optional(uid))
            }
          }
          .labelsHidden()
        }
        GreenPushButton("Broadcast music from an app") { model.openMusicFAQ() }
        if model.selectedDevice?.isBluetooth == true {
          Text(
            "Bluetooth earbuds switch to call mode while they are the microphone. The mic stays speech quality. Their own playback drops to call quality, so the stage may be harder to hear. A wired or USB microphone, or separate wired headphones, avoids that. Turn Bluetooth off on your phone, and on any other nearby device paired to the earbuds, before you go live, so the phone does not take them back and cut the stream."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        LabeledRow(title: "Channels") {
          Picker("Mode", selection: modeBinding) {
            Text("Mono").tag(ChannelMode.mono)
            Text("Stereo").tag(ChannelMode.stereo)
          }
          .pickerStyle(.segmented)
          .frame(width: 150)
          if model.settings.channelMode == .stereo {
            Picker("Input", selection: channelBinding) {
              ForEach(1...channelUpper, id: \.self) { channel in
                Text("Input \(channel)").tag(channel)
              }
            }
            .labelsHidden()
            .frame(width: 110)
          } else {
            Text("All inputs summed")
              .foregroundStyle(.secondary)
          }
        }
        LabeledRow(title: "Quality") {
          Picker("Quality", selection: qualityBinding) {
            Text("Speech 32k").tag(QualityPreset.speech)
            Text("Standard 64k").tag(QualityPreset.standard)
            Text("Music 96k").tag(QualityPreset.music)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        Text(model.settings.bandwidthHint)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(
          "Speech is mono, 32 kbps, for about 30 phones. The stream is always 48 kHz. Music is 96 kbps mono or 128 kbps stereo."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Card {
        SectionLabel(text: "Stream")
        LabeledRow(title: "Stream name") {
          TextField("live", text: streamBinding)
            .frame(width: 120)
          Text("Port")
          TextField("8889", text: portText)
            .frame(width: 70)
        }
        LabeledRow(title: "Broadcast title") {
          TextField(model.defaultBroadcastTitle, text: titleBinding)
            .frame(maxWidth: 280)
        }
        Text(
          "Shown on the lock screen and in the browser tab. Leave this blank for \(model.defaultBroadcastTitle). A blank title follows the app name. Changing it does not change the link."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        LabeledRow(title: "Network mode") {
          Picker("Network", selection: networkBinding) {
            Text("Auto (UDP+TCP)").tag(NetworkMode.auto)
            Text("UDP only").tag(NetworkMode.udpOnly)
            Text("TCP only").tag(NetworkMode.tcpOnly)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        Text("TCP only = Wi-Fi-friendly; try it if listeners hear dropouts.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Card {
        SectionLabel(text: "Poster")
        LabeledRow(title: "Wi-Fi name") {
          TextField("Network name", text: posterNetworkBinding)
            .frame(maxWidth: 280)
        }
        if let ssid = model.knownSSID, !ssid.isEmpty,
          ssid != model.settings.posterNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
        {
          Button("Use this Mac’s Wi-Fi (\(ssid))") { model.useCurrentNetworkName() }
            .font(.caption)
        }
        Text(
          "Phones join this network before the listen code works. Leave it blank to print a line you can write in. Use this Mac’s Wi-Fi only when that is the network people will join."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        LabeledRow(title: "Password") {
          SecureField("Wi-Fi password", text: posterPasswordBinding)
            .frame(maxWidth: 280)
        }
        if let notice = model.posterPasswordNotice {
          Text(notice).font(.caption).foregroundStyle(.orange)
        }
        Text(
          "Saved in the macOS Keychain on this Mac. It is not written into settings, the log, or Copy diagnostics. The printed poster shows it under the join code."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        LabeledRow(title: "Security") {
          Picker("Security", selection: posterSecurityBinding) {
            ForEach(WiFiSecurity.allCases, id: \.self) { security in
              Text(security.menuLabel).tag(security)
            }
          }
          .labelsHidden()
          .frame(width: 180)
        }
        if model.settings.posterWiFiSecurity == .none {
          Text("An open network has no password. The poster will not print one.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Toggle("Hidden network", isOn: posterHiddenBinding)
      }
      Card {
        SectionLabel(text: "This Mac")
        Toggle("Keep Mac awake while broadcasting", isOn: awakeBinding)
        Text(
          "Closing the laptop lid will still sleep the Mac unless it is on power with an external display."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Toggle("Launch at login", isOn: loginBinding)
        Toggle("Start broadcasting when the app opens", isOn: autoStartBinding)
        if let message = model.loginItemMessage {
          Text(message).font(.caption).foregroundStyle(.orange)
        }
      }
      Card {
        SectionLabel(text: "Advanced")
        LabeledRow(title: "ICE port") {
          TextField("8189", text: iceText).frame(width: 80)
        }
        LabeledRow(title: "URL style") {
          Picker("URL", selection: styleBinding) {
            Text("IP address").tag(URLStyle.ip)
            Text(".local hostname").tag(URLStyle.localHostname)
          }
          .labelsHidden()
          .frame(width: 180)
        }
        if model.settings.urlStyle == .localHostname {
          Text("Some Android phones can't open .local addresses.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        LabeledRow(title: "Max listeners") {
          TextField("0", text: maxText).frame(width: 80)
          Text("0 = unlimited").font(.caption).foregroundStyle(.secondary)
        }
        LabeledRow(title: "Log level") {
          Picker("Log", selection: logBinding) {
            ForEach(LogLevel.allCases, id: \.self) { level in
              Text(level.rawValue).tag(level)
            }
          }
          .labelsHidden()
          .frame(width: 120)
        }
        Toggle("Custom bitrate", isOn: customToggle)
        if model.settings.quality == .custom {
          LabeledRow(title: "Bitrate") {
            TextField("64", text: bitrateText).frame(width: 80)
            Text("16–256 kbps").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if let issue = validate(model.settings).first {
        Text(issue.message).foregroundStyle(.red)
      }
      HStack {
        Button("Reset to defaults…") { confirmReset = true }
        Button("Credits…") { model.showCredits = true }
        Text(
          model.hasPendingChanges
            ? "Apply now, or on the next Start." : "Changes apply on the next Start."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if model.hasPendingChanges {
        Button("Apply now (brief interruption)") { model.applyNow() }
      }
    }
    .padding(.bottom, 8)
    .padding(16)
  }

  private var deviceBinding: Binding<String?> {
    Binding(
      get: { model.settings.inputDeviceUID },
      set: { model.chooseDevice($0) }
    )
  }
  private var channelUpper: Int {
    let available = max(1, model.selectedDevice?.inputChannels ?? 1)
    let selected = model.settings.inputChannel
    if (1...SettingsRepair.maxInputChannel).contains(selected) {
      return max(available, selected)
    }
    return available
  }
  private var modeBinding: Binding<ChannelMode> {
    Binding(
      get: { model.settings.channelMode }, set: { value in model.mutate { $0.channelMode = value } }
    )
  }
  private var channelBinding: Binding<Int> {
    Binding(
      get: {
        let selected = model.settings.inputChannel
        return (1...channelUpper).contains(selected) ? selected : 1
      },
      set: { value in model.mutate { $0.inputChannel = value } })
  }
  private var qualityBinding: Binding<QualityPreset> {
    Binding(
      get: { model.settings.quality == .custom ? .standard : model.settings.quality },
      set: { value in model.mutate { $0.applyPreset(value) } }
    )
  }
  private var streamBinding: Binding<String> {
    Binding(
      get: { model.settings.streamName }, set: { value in model.mutate { $0.streamName = value } })
  }
  private var titleBinding: Binding<String> {
    Binding(
      get: { model.settings.broadcastTitle },
      set: { value in model.mutate { $0.broadcastTitle = BroadcastTitle.limited(value) } }
    )
  }
  private var portText: Binding<String> { numberText(\.listenerPort) }
  private var networkBinding: Binding<NetworkMode> {
    Binding(
      get: { model.settings.networkMode }, set: { value in model.mutate { $0.networkMode = value } }
    )
  }
  private var awakeBinding: Binding<Bool> {
    Binding(
      get: { model.settings.keepAwake }, set: { value in model.mutate { $0.keepAwake = value } })
  }
  private var loginBinding: Binding<Bool> {
    Binding(
      get: { model.settings.launchAtLogin },
      set: { value in model.mutate { $0.launchAtLogin = value } })
  }
  private var autoStartBinding: Binding<Bool> {
    Binding(
      get: { model.settings.startWhenAppOpens },
      set: { value in model.mutate { $0.startWhenAppOpens = value } })
  }
  private var iceText: Binding<String> { numberText(\.icePort) }
  private var styleBinding: Binding<URLStyle> {
    Binding(
      get: { model.settings.urlStyle }, set: { value in model.mutate { $0.urlStyle = value } })
  }
  private var maxText: Binding<String> { numberText(\.maxListeners) }
  private var logBinding: Binding<LogLevel> {
    Binding(
      get: { model.settings.logLevel }, set: { value in model.mutate { $0.logLevel = value } })
  }
  private var customToggle: Binding<Bool> {
    Binding(
      get: { model.settings.quality == .custom },
      set: { enabled in
        model.mutate { settings in
          settings.quality = enabled ? .custom : .standard
        }
      }
    )
  }
  private func numberText(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<String> {
    Binding(
      get: { String(model.settings[keyPath: keyPath]) },
      set: { text in
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed) else { return }
        model.mutate { $0[keyPath: keyPath] = value }
      }
    )
  }
  private var bitrateText: Binding<String> { numberText(\.customBitrateKbps) }
  private var posterNetworkBinding: Binding<String> {
    Binding(
      get: { model.settings.posterNetworkName },
      set: { value in model.mutate { $0.posterNetworkName = value } })
  }
  private var posterPasswordBinding: Binding<String> {
    Binding(get: { model.posterPassword }, set: { model.setPosterPassword($0) })
  }
  private var posterSecurityBinding: Binding<WiFiSecurity> {
    Binding(
      get: { model.settings.posterWiFiSecurity },
      set: { value in model.mutate { $0.posterWiFiSecurity = value } })
  }
  private var posterHiddenBinding: Binding<Bool> {
    Binding(
      get: { model.settings.posterWiFiHidden },
      set: { value in model.mutate { $0.posterWiFiHidden = value } })
  }
}

/// Escape closes the window that contains this view. The main window does not
/// use it, and a window titled as the broadcast is never closed from here.
struct EscapeCloser: NSViewRepresentable {
  var onEscape: () -> Void

  func makeNSView(context: Context) -> EscapeMonitorView {
    let view = EscapeMonitorView()
    view.isHidden = true
    view.onEscape = onEscape
    return view
  }

  func updateNSView(_ view: EscapeMonitorView, context: Context) {
    view.onEscape = onEscape
  }
}

final class EscapeMonitorView: NSView {
  var onEscape: (() -> Void)?
  private var monitor: Any?
  private let mainTitle = "RoomCast 1.0 Beta Release"

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    install()
  }

  deinit {
    remove()
  }

  private func remove() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }

  private func install() {
    remove()
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handle(event) ?? event
      }
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let window, event.window === window, event.keyCode == 53 else { return event }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
      || flags.contains(.shift)
    {
      return event
    }
    guard window.attachedSheet == nil else { return event }
    guard window.title != mainTitle else { return event }
    onEscape?()
    window.close()
    return nil
  }
}

/// Closes the Settings window that contains this view, not the broadcast window.
private struct CloseSettingsWindow: NSViewRepresentable {
  var request: Int

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.isHidden = true
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard request != context.coordinator.applied else { return }
    context.coordinator.applied = request
    guard request > 0 else { return }
    DispatchQueue.main.async {
      view.window?.close()
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var applied = 0
  }
}

struct LabeledRow<Content: View>: View {
  var title: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack {
      Text(title).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
      content()
    }
  }
}
