import PublicEarFiCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    RunningTab()
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 12)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
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
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.28)))
  }
}

struct SectionLabel: View {
  var text: String

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .tracking(0.6)
  }
}

struct RunningTab: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: { model.toggleBroadcast() }) {
        HStack(spacing: 8) {
          if case .starting = model.phase {
            ProgressView().controlSize(.small)
          }
          Text(buttonTitle)
            .font(.title2.bold())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white)
      .background(buttonColor)
      .clipShape(RoundedRectangle(cornerRadius: 10))

      Card {
        HStack(spacing: 8) {
          Circle().fill(statusColor).frame(width: 10, height: 10)
          Text(model.statusLine()).fontWeight(.semibold)
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
          Text("Gain").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
          Slider(value: gainBinding, in: InputGain.minimumDB...InputGain.maximumDB)
          Text(InputGain.label(model.settings.inputGainDB))
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
        }
        Text("0 dB leaves the desk unchanged. Raise it when the interpreter is quiet.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if model.noSignal {
          Text("No signal for about 10 seconds. Check the desk feed.")
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
        HStack(alignment: .top, spacing: 14) {
          Button {
            model.showQR = true
          } label: {
            qrView(side: 112)
          }
          .buttonStyle(.plain)
          .help("Show the QR code full screen")
          VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Listeners open")
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
              Button("Copy link") { model.copyLink() }
              if model.rankedNetworks.count > 1 {
                Picker("Address", selection: addressBinding) {
                  Text("Auto").tag(nil as String?)
                  ForEach(model.rankedNetworks) { candidate in
                    Text("\(candidate.name) \(candidate.address)").tag(Optional(candidate.address))
                  }
                }
                .frame(maxWidth: 220)
              }
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
        Button("Copy diagnostics") { model.copyDiagnostics() }
      }
      if model.hasPendingChanges {
        WarningBanner(
          text:
            "Settings changed. Apply now (brief interruption), or they take effect on the next Start."
        ) {
          model.applyNow()
        }
      }
      Spacer(minLength: 0)
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

  private var buttonColor: Color {
    switch model.phase {
    case .stopped, .starting, .blocked:
      return Color(red: 0.16, green: 0.55, blue: 0.28)
    default:
      return Color(red: 0.84, green: 0.25, blue: 0.18)
    }
  }

  private var statusColor: Color {
    switch model.phase {
    case .live:
      return .green
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

struct LevelBar: View {
  var fraction: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.15))
        LinearGradient(
          stops: [
            .init(color: .green, location: 0),
            .init(color: .green, location: 0.7),
            .init(color: .yellow, location: 0.88),
            .init(color: .red, location: 1),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: geometry.size.width * min(1, max(0, fraction)))
        .clipShape(RoundedRectangle(cornerRadius: 3))
      }
    }
    .frame(height: 12)
  }
}

struct WarningBanner: View {
  var text: String
  var action: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      Text(text).font(.caption)
      Spacer()
      Button("Why?", action: action).font(.caption)
    }
    .padding(8)
    .background(Color.yellow.opacity(0.35))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

struct SettingsTab: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmReset = false

  var body: some View {
    ScrollView {
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
              Text("All inputs mixed")
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
        DisclosureGroup("Advanced") {
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
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .id(model.settingsRevision)
    .sheet(isPresented: $model.showCredits) { CreditsSheet() }
    .alert("Reset every setting, including the poster text?", isPresented: $confirmReset) {
      Button("Reset to defaults", role: .destructive) { model.resetDefaults() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Logs are kept. The defaults are saved immediately. If you are live, they apply on the next Start."
      )
    }
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
