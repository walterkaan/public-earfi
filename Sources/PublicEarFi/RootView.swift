import AppKit
import PublicEarFiCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack {
      BroadcastBackdrop(live: model.isBroadcasting, level: model.levelFraction)
        .ignoresSafeArea()
      VStack(spacing: 0) {
        // Hero stays in this band and in the outer margin. The plate below
        // is opaque, so the animation does not show between the cards.
        Color.clear
          .frame(height: 36)
          .accessibilityHidden(true)
        RunningTab()
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .background(AppChrome.window)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 16)
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
    .sheet(isPresented: $model.showWhy) { WhySheet() }
    .sheet(isPresented: $model.showQR) { QRSheet() }
    .alert("Allow incoming connections?", isPresented: $model.showFirewall) {
      Button("Continue") { model.confirmFirewallAndStart() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "macOS will ask to allow incoming connections so phones on the Wi-Fi can reach this Mac."
      )
    }
  }
}

/// Solid navy card on every macOS version, including Reduce Transparency.
/// The hero stays in the window margin, not inside or between these cards.
struct Card<Content: View>: View {
  var borderColor: Color = AppChrome.cardBorder
  var borderWidth: CGFloat = 1
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppChrome.card)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(borderColor, lineWidth: borderWidth)
    )
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
  /// Start and Save and Close. #8b5cf6
  static let primary = Color(red: 139.0 / 255, green: 92.0 / 255, blue: 246.0 / 255)
  /// Support links, lower saturation than the old filled pink. #d489ae
  static let support = Color(red: 212.0 / 255, green: 137.0 / 255, blue: 174.0 / 255)
  /// Helper text on navy. Light enough for 4.5:1 at 13 pt.
  static let helper = Color(red: 0.86, green: 0.88, blue: 0.93)
  static let stopButton = Color(red: 0.84, green: 0.25, blue: 0.18)
  /// The website hero stays visible in the window margin.
  static let heroOpacity = 0.72
}

extension View {
  /// 13 pt on navy, above the 4.5:1 contrast floor.
  func helperText() -> some View {
    font(.system(size: 13))
      .foregroundStyle(AppChrome.helper)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct SectionLabel: View {
  var text: LocalizedStringKey

  var body: some View {
    Text(text)
      .textCase(.uppercase)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(AppChrome.heading)
      .tracking(0.6)
  }
}

struct RunningTab: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var linkCopied = false
  @State private var copyReset: Task<Void, Never>?
  @State private var pulse = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Card(
        borderColor: isLive ? statusColor : AppChrome.cardBorder,
        borderWidth: isLive ? 1.5 : 1
      ) {
        HStack(spacing: 10) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 36, height: 36)
            .accessibilityLabel("RoomCast")
          SectionLabel(text: "Broadcast")
          Spacer(minLength: 0)
        }
        HStack(alignment: .top, spacing: 8) {
          statusDot
          Text(model.statusLine())
            .fontWeight(.semibold)
            .fixedSize(horizontal: false, vertical: true)
        }
        BroadcastButton(
          title: buttonTitle,
          isStop: isStop,
          showsProgress: isStarting
        ) {
          model.toggleBroadcast()
        }
        sourceButton
        if let stray = model.strayHelper {
          Text(
            "A leftover \(stray.processName) (pid \(stray.pid)) is using port \(stray.port)."
          )
          .helperText()
          Button("Stop leftover helper") { model.stopStrayHelper() }
        }
        HStack {
          Text("Input level")
            .helperText()
            .frame(width: 90, alignment: .leading)
          LevelBar(
            fraction: model.noSignal ? 0 : model.levelFraction,
            peak: model.noSignal ? 0 : model.meterPeakFraction,
            dimmed: model.noSignal
          )
          Text(levelText)
            .helperText()
            .foregroundStyle(model.noSignal ? AppChrome.helper.opacity(0.45) : AppChrome.helper)
            .frame(width: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(levelText)
        .accessibilityAddTraits(.updatesFrequently)
        HStack {
          Text("Volume")
            .helperText()
            .frame(width: 90, alignment: .leading)
          Slider(value: gainBinding, in: InputGain.minimumDB...InputGain.maximumDB)
            .tint(AppChrome.heading)
            .overlay(SliderDoubleClick { model.setInputGain(InputGain.defaultDB) })
          Text(InputGain.label(model.settings.inputGainDB))
            .helperText()
            .frame(width: 72, alignment: .trailing)
        }
        .help(
          "Volume, from -12 dB to +24 dB. Changes apply immediately, including while you are live. Double-click to reset to 0 dB."
        )
        Text(
          "0 dB leaves the volume unchanged. Increase or decrease the broadcast's volume."
        )
        .helperText()
        if model.noSignal {
          Text("No signal for about 5 seconds. Check the desk feed and the selected input.")
            .helperText()
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
        HStack(spacing: 8) {
          SectionLabel(text: "Listen")
          if isLive {
            Text("Live")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(AppChrome.window)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Capsule().fill(AppChrome.heading))
          }
          Spacer(minLength: 0)
        }
        ZStack {
          HStack(alignment: .top, spacing: 14) {
            Button {
              model.showQR = true
            } label: {
              qrView(side: 112)
            }
            .buttonStyle(.plain)
            .modifier(DarkFocusRing())
            .help("Show the QR code full screen")
            .accessibilityLabel(qrAccessibility)
            VStack(alignment: .leading, spacing: 6) {
              Text(shownURL)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .textSelection(.enabled)
              if let secondary = model.secondaryURL {
                Text("Doesn't work? Try: \(shownHost(secondary))")
                  .helperText()
                  .textSelection(.enabled)
              }
              TintedPushButton(linkCopied ? "Copied" : "Copy link") { copyListenerLink() }
                .disabled(model.listenerURL == nil)
              if model.settings.urlStyle == .localHostname {
                Text("Some Android phones can't open .local addresses.")
                  .helperText()
              }
            }
          }
          .opacity(isLive ? 1 : 0.3)
          if !isLive {
            Text("Not live yet: press Start Broadcasting")
              .font(.system(size: 13, weight: .semibold))
              .multilineTextAlignment(.center)
              .padding(10)
              .background(AppChrome.card.opacity(0.94))
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(AppChrome.heading.opacity(0.45))
              )
              .allowsHitTesting(false)
          }
        }
        HStack {
          TintedPushButton("Open PDF QR Poster") { model.openQuickPosterPDF() }
            .disabled(model.listenerURL == nil)
            .help("Save a PDF of the QR poster and open it. Print that PDF yourself.")
          Spacer(minLength: 0)
        }
        if model.rankedNetworks.count > 1 {
          Picker("Address", selection: addressBinding) {
            Text("Auto").tag(nil as String?)
            ForEach(model.rankedNetworks) { candidate in
              Text("\(candidate.name) \(candidate.address)").tag(Optional(candidate.address))
            }
          }
          .frame(maxWidth: 280)
        }
        VStack(alignment: .leading, spacing: 0) {
          SectionLabel(text: "Listening now")
          Text("\(model.listeners)")
            .font(.system(size: 32, weight: .bold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening now")
        .accessibilityValue("\(model.listeners)")
        .accessibilityAddTraits(.updatesFrequently)
      }

      Card {
        SectionLabel(text: "Support RoomCast")
        SupportLinks()
        SectionLabel(text: "Help")
          .padding(.top, 10)
        HStack(spacing: 10) {
          TintedPushButton("Getting Started") { model.reopenGettingStarted() }
          TintedPushButton("FAQ") { model.openFAQ() }
          TintedPushButton("Troubleshooting") { model.openTroubleshooting() }
          Spacer(minLength: 0)
        }
        .padding(.top, 4)
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
    }
    .onAppear { pulse = true }
  }

  private var sourceButton: some View {
    TintedPushButton("Change Sound Source") { model.openSettings() }
      .disabled(sourceLocked)
      .help(
        sourceLocked
          ? "Stop broadcasting to change source"
          : "Choose a microphone, headset, or mixing desk"
      )
      .overlay {
        if sourceLocked {
          Rectangle()
            .fill(Color.white.opacity(0.001))
            .help("Stop broadcasting to change source")
        }
      }
  }

  private var statusDot: some View {
    Circle()
      .fill(statusColor)
      .frame(width: 10, height: 10)
      .overlay {
        if shouldPulse && !reduceMotion {
          Circle()
            .stroke(statusColor.opacity(0.75), lineWidth: 2)
            .scaleEffect(pulse ? 2.2 : 1)
            .opacity(pulse ? 0 : 1)
        }
      }
      .animation(
        shouldPulse && !reduceMotion
          ? .easeOut(duration: 1.3).repeatForever(autoreverses: false) : .default,
        value: pulse
      )
      .accessibilityHidden(true)
  }

  private var isLive: Bool {
    if case .live = model.phase { return true }
    return false
  }

  private var sourceLocked: Bool {
    switch model.phase {
    case .stopped, .blocked:
      return false
    default:
      return true
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

  private var shouldPulse: Bool {
    isLive && !model.noSignal
  }

  private var statusColor: Color {
    // Orange is reserved for the no-signal warning. Live uses teal so the
    // border and dot do not look like a problem state.
    if model.noSignal, case .live = model.phase {
      return .orange
    }
    switch model.phase {
    case .stopped:
      return Color.gray
    case .live:
      return AppChrome.heading
    case .starting:
      return AppChrome.primary
    default:
      return AppChrome.primary
    }
  }

  private var levelText: String {
    if model.noSignal || model.levelDB <= -100 { return "— dB" }
    return String(format: "%.0f dB", model.levelDB)
  }

  private var shownURL: String {
    guard let listenerURL = model.listenerURL else { return "No LAN address yet" }
    return shownHost(listenerURL)
  }

  private var qrAccessibility: Text {
    if let listenerURL = model.listenerURL {
      return Text("Listen QR code, opens \(listenerURL)")
    }
    return Text("Listen QR code")
  }

  private func shownHost(_ url: String) -> String {
    ListenerLink.endpoint(url) ?? url
  }

  private func copyListenerLink() {
    model.copyLink()
    linkCopied = true
    copyReset?.cancel()
    copyReset = Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      if Task.isCancelled { return }
      linkCopied = false
    }
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

/// Ko-fi, Patreon, and Buy Me a Coffee, in the support card.
struct SupportLinks: View {
  var body: some View {
    HStack(spacing: 10) {
      TintedLinkButton("Ko-fi", destination: AppLinks.kofi, showsHeart: true)
      TintedLinkButton("Patreon", destination: AppLinks.patreon, showsHeart: true)
      TintedLinkButton(
        "Buy Me a Coffee", destination: AppLinks.buyMeACoffee, showsHeart: true)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Solid violet fill and white text. Used for Start's partner in Settings,
/// Save and Close. Other actions use the tinted outline.
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
    .modifier(DarkFocusRing())
  }
}

struct TintedPushButton: View {
  var title: LocalizedStringKey
  var systemImage: String?
  var tint: Color
  var action: () -> Void

  init(
    _ title: LocalizedStringKey,
    systemImage: String? = nil,
    tint: Color = AppChrome.primary,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      TintedLabel(title: title, systemImage: systemImage, tint: tint)
    }
    .buttonStyle(.plain)
    .modifier(DarkFocusRing())
  }
}

struct TintedLinkButton: View {
  var title: LocalizedStringKey
  var destination: URL
  var showsHeart: Bool

  init(_ title: LocalizedStringKey, destination: URL, showsHeart: Bool = false) {
    self.title = title
    self.destination = destination
    self.showsHeart = showsHeart
  }

  var body: some View {
    Link(destination: destination) {
      TintedLabel(
        title: title,
        systemImage: showsHeart ? "heart.fill" : nil,
        tint: AppChrome.support
      )
    }
    .buttonStyle(.plain)
    .modifier(DarkFocusRing())
  }
}

/// Start stays large and violet. Stop stays solid red.
struct BroadcastButton: View {
  var title: String
  var isStop: Bool
  var showsProgress: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
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
      .foregroundStyle(.white)
      .background(isStop ? AppChrome.stopButton : AppChrome.primary)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .modifier(DarkFocusRing())
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

private struct TintedLabel: View {
  var title: LocalizedStringKey
  var systemImage: String?
  var tint: Color

  var body: some View {
    HStack(spacing: 6) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
      }
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(tint.opacity(0.16))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.9), lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .contentShape(RoundedRectangle(cornerRadius: 8))
  }
}

private struct DarkFocusRing: ViewModifier {
  @FocusState private var focused: Bool

  func body(content: Content) -> some View {
    content
      .focused($focused)
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(AppChrome.heading, lineWidth: focused ? 2 : 0)
          .padding(-3)
          .allowsHitTesting(false)
      }
  }
}

struct LevelBar: View {
  var fraction: Double
  var peak: Double
  var dimmed: Bool = false

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let level = dimmed ? 0 : min(1, max(0, fraction))
      let held = dimmed ? 0 : min(1, max(0, peak))
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.white.opacity(dimmed ? 0.06 : 0.12))
        if !dimmed {
          Rectangle()
            .fill(Color.orange.opacity(0.45))
            .frame(width: max(0, width * 0.05))
            .offset(x: width * 0.9)
          Rectangle()
            .fill(Color.red.opacity(0.55))
            .frame(width: max(0, width * 0.05))
            .offset(x: width * 0.95)
        }
        RoundedRectangle(cornerRadius: 3)
          .fill(meterColor(level))
          .frame(width: max(0, width * level))
        if !dimmed {
          Rectangle()
            .fill(Color.white)
            .frame(width: 2)
            .offset(x: min(max(0, width * held - 1), max(0, width - 2)))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .frame(height: 12)
    .opacity(dimmed ? 0.55 : 1)
    .accessibilityHidden(true)
  }

  private func meterColor(_ level: Double) -> Color {
    if dimmed { return Color.white.opacity(0.18) }
    if level >= 0.95 { return Color(red: 0.92, green: 0.24, blue: 0.2) }
    if level >= 0.9 { return .orange }
    return AppChrome.heading
  }
}

struct WarningBanner: View {
  var text: String
  var buttonTitle: String = "Why?"
  var action: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      Text(text)
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button(buttonTitle, action: action)
        .font(.system(size: 13, weight: .semibold))
    }
    .padding(8)
    .background(Color.orange.opacity(0.28))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

struct SettingsTab: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmReset = false
  @State private var closeSettingsRequest = 0
  @State private var selected: SettingsPane = .audio
  @State private var search = ""

  var body: some View {
    // Manual sidebar+detail (not NavigationSplitView): avoids the tall
    // window toolbar / sidebar-toggle that was covering the detail header
    // and pushing the sidebar under the traffic lights.
    HStack(spacing: 0) {
      settingsSidebar
        .frame(width: 220)
      Divider()
      settingsDetail
    }
    .background(AppChrome.window)
    .background(CloseSettingsWindow(request: closeSettingsRequest))
    .background(
      EscapeCloser {
        model.saveAndCloseSettings()
      }
    )
    .background(SettingsAutosave { model.saveAndCloseSettings() })
    .background(SettingsWindowChrome())
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .id(model.settingsRevision)
    .onChange(of: search) { _ in
      if !filteredPanes.contains(selected), let first = filteredPanes.first {
        selected = first
      }
    }
    .alert(
      "Reset every setting, including the poster text and the Wi-Fi password?",
      isPresented: $confirmReset
    ) {
      Button("Cancel", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
      Button("Reset to defaults", role: .destructive) { model.resetDefaults() }
    } message: {
      Text(
        "Logs are kept. The Wi-Fi password is removed from the Keychain. The defaults are saved immediately. If you are live, they apply on the next Start."
      )
    }
  }

  private var filteredPanes: [SettingsPane] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return SettingsPane.allCases }
    return SettingsPane.allCases.filter { pane in
      pane.title.lowercased().contains(query)
        || pane.description.lowercased().contains(query)
        || pane.keywords.contains(where: { $0.contains(query) })
    }
  }

  private var settingsSidebar: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search", text: $search)
          .textFieldStyle(.plain)
      }
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 8)

      List(selection: $selected) {
        ForEach(filteredPanes) { pane in
          Label {
            Text(pane.title)
          } icon: {
            SettingsSidebarIcon(symbol: pane.symbol, tint: pane.tint)
          }
          .tag(pane)
          .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(selected == pane ? AppChrome.primary.opacity(0.28) : Color.clear)
              .padding(.horizontal, 4)
          )
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .tint(AppChrome.primary)
      .accentColor(AppChrome.primary)
    }
    .background(AppChrome.window)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private var settingsDetail: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          settingsHeader(for: selected)
          VStack(alignment: .leading, spacing: 14) {
            paneContent(selected)
            if let issue = validate(model.settings).first {
              Text(issue.message)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.58))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(AppChrome.card)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(Color.white.opacity(0.08), lineWidth: 1)
          )
          .padding(.horizontal, 24)
          .padding(.bottom, 16)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      settingsSaveRow
    }
    .background(AppChrome.window)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private func settingsHeader(for pane: SettingsPane) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(pane.title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
      Text(pane.description)
        .font(.system(size: 12))
        .foregroundStyle(AppChrome.helper)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.top, 4)
  }

  @ViewBuilder
  private func paneContent(_ pane: SettingsPane) -> some View {
    switch pane {
    case .audio:
      soundFields
    case .stream:
      streamFields
    case .poster:
      posterFields
    case .general:
      macFields
    case .advanced:
      advancedFields
    }
  }

  private var settingsSaveRow: some View {
    HStack(alignment: .center, spacing: 12) {
      GreenPushButton("Save and Close") {
        model.saveAndCloseSettings()
        closeSettingsRequest += 1
      }
      Text("Changes take effect next time you start broadcasting.")
        .helperText()
      Spacer(minLength: 8)
      if model.hasPendingChanges {
        TintedPushButton("Apply now") { model.applyNow() }
          .help("Brief interruption, then the new settings are live.")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(AppChrome.window)
    .overlay(alignment: .top) {
      Rectangle().fill(AppChrome.heading.opacity(0.35)).frame(height: 1)
    }
  }

  @ViewBuilder
  private var soundFields: some View {
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
    TintedPushButton("Broadcast music from an app") { model.openMusicFAQ() }
    if model.selectedDevice?.isBluetooth == true {
      Text(
        "Bluetooth earbuds switch to call mode while they are the microphone. The mic stays speech quality. Their own playback drops to call quality, so the stage may be harder to hear. A wired or USB microphone, or separate wired headphones, avoids that. Turn Bluetooth off on your phone, and on any other nearby device paired to the earbuds, before you go live, so the phone does not take them back and cut the stream."
      )
      .helperText()
    }
    LabeledRow(title: "Channels") {
      Picker("Channels", selection: modeBinding) {
        Text("Mono").tag(ChannelMode.mono)
        Text("Stereo").tag(ChannelMode.stereo)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 160)
      .accessibilityLabel("Channels")
      if model.settings.channelMode == .stereo {
        Picker("Input", selection: channelBinding) {
          ForEach(1...channelUpper, id: \.self) { channel in
            Text("Inputs \(channel)–\(channel + 1)").tag(channel)
          }
        }
        .labelsHidden()
        .frame(width: 130)
      } else {
        Text("All inputs summed")
          .helperText()
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
      .helperText()
  }

  @ViewBuilder
  private var posterFields: some View {
    LabeledRow(title: "Wi-Fi name") {
      TextField("Network name", text: posterNetworkBinding)
        .frame(maxWidth: 280)
    }
    if let ssid = model.knownSSID, !ssid.isEmpty,
      ssid != model.settings.posterNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
    {
      Button("Use this Mac’s Wi-Fi (\(ssid))") { model.useCurrentNetworkName() }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(AppChrome.primary)
    }
    Text(
      "Phones join this network before the listen code works. Leave it blank to print a line you can write in. Use this Mac’s Wi-Fi only when that is the network people will join."
    )
    .helperText()
    LabeledRow(title: "Password") {
      SecureField("Wi-Fi password", text: posterPasswordBinding)
        .frame(maxWidth: 280)
    }
    if let notice = model.posterPasswordNotice {
      Text(notice)
        .helperText()
        .foregroundStyle(.orange)
    }
    Text(
      "Saved in the macOS Keychain on this Mac. It is not written into settings, the log, or Copy diagnostics. The printed poster shows it under the join code."
    )
    .helperText()
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
        .helperText()
    }
    Toggle("Hidden network", isOn: posterHiddenBinding)
  }

  @ViewBuilder
  private var streamFields: some View {
    LabeledRow(title: "Stream name") {
      TextField("live", text: streamBinding)
        .frame(width: 120)
      Text("Port")
        .helperText()
      TextField("8889", text: portText)
        .frame(width: 70)
    }
    LabeledRow(title: "Broadcast title") {
      TextField(model.defaultBroadcastTitle, text: titleBinding)
        .frame(maxWidth: 280)
    }
    Text("Shown on Lockscreen and Users' Browser")
      .helperText()
    LabeledRow(title: "Network mode") {
      Picker("Network", selection: networkBinding) {
        Text("Auto (UDP+TCP)").tag(NetworkMode.auto)
        Text("UDP only").tag(NetworkMode.udpOnly)
        Text("TCP only").tag(NetworkMode.tcpOnly)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
    Text("Choose TCP only if listeners hear dropouts.")
      .helperText()
  }

  @ViewBuilder
  private var macFields: some View {
    Toggle("Keep Mac awake while broadcasting", isOn: awakeBinding)
    Text(
      "Closing the laptop lid will still sleep the Mac unless it is on power with an external display."
    )
    .helperText()
    Toggle("Launch at login", isOn: loginBinding)
    Toggle("Start broadcasting when the app opens", isOn: autoStartBinding)
    if let message = model.loginItemMessage {
      Text(message)
        .helperText()
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var advancedFields: some View {
    LabeledRow(title: "ICE port") {
      TextField("8189", text: iceText).frame(width: 80)
    }
    Text("WebRTC ICE port. Phones receive the audio on this UDP or TCP port.")
      .helperText()
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
        .helperText()
    }
    LabeledRow(title: "Max listeners") {
      TextField("0", text: maxText).frame(width: 80)
      Text("0 = unlimited")
        .helperText()
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
        Text("16–256 kbps")
          .helperText()
      }
    }
    TintedPushButton("Reset to defaults…") { confirmReset = true }
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

/// Sidebar panes for the System Settings–style window.
private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
  case audio
  case stream
  case poster
  case general
  case advanced

  var id: String { rawValue }

  var title: String {
    switch self {
    case .audio: return "Audio"
    case .stream: return "Stream"
    case .poster: return "Poster"
    case .general: return "General"
    case .advanced: return "Advanced"
    }
  }

  var symbol: String {
    switch self {
    case .audio: return "mic.fill"
    case .stream: return "dot.radiowaves.left.and.right"
    case .poster: return "qrcode"
    case .general: return "gearshape.fill"
    case .advanced: return "slider.horizontal.3"
    }
  }

  var tint: Color {
    // Section icons stay inside the app palette (violet / teal / support pink /
    // muted helper). Avoid system red/orange/blue that fight the navy chrome.
    switch self {
    case .audio: return AppChrome.heading
    case .stream: return AppChrome.primary
    case .poster: return AppChrome.primary.opacity(0.85)
    case .general: return Color(red: 0.55, green: 0.58, blue: 0.70)
    case .advanced: return AppChrome.support
    }
  }

  var description: String {
    switch self {
    case .audio:
      return "Choose the microphone or desk feed, channels, and stream quality."
    case .stream:
      return "Name the broadcast and how RoomCast talks to phones on the Wi-Fi."
    case .poster:
      return "Wi-Fi details printed on the QR poster so guests can join and listen."
    case .general:
      return "Keep the Mac awake, launch at login, and start broadcasting automatically."
    case .advanced:
      return "Ports, listener limits, logging, and custom bitrate for organisers who need them."
    }
  }

  var keywords: [String] {
    switch self {
    case .audio:
      return ["mic", "device", "mono", "stereo", "quality", "speech", "music", "bitrate", "blackhole"]
    case .stream:
      return ["port", "title", "udp", "tcp", "network", "name"]
    case .poster:
      return ["wifi", "wi-fi", "password", "ssid", "security", "hidden", "qr"]
    case .general:
      return ["awake", "login", "launch", "autostart", "sleep"]
    case .advanced:
      return ["ice", "webrtc", "url", "local", "listeners", "log", "custom", "reset"]
    }
  }
}

private struct SettingsSidebarIcon: View {
  var symbol: String
  var tint: Color
  var side: CGFloat = 26
  var pointSize: CGFloat = 13

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: pointSize, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: side, height: side)
      .background(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous).fill(tint))
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

/// Keeps Settings content below a normal title bar (no fullSizeContentView),
/// resizable, with a fresh frame-autosave name when the default size changes.
private struct SettingsWindowChrome: NSViewRepresentable {
  /// Bump when default size / chrome changes so old frame keys are ignored.
  static let autosaveName = "RoomCast.Settings.v4"
  /// ~900×620 content ≈ 950×660 with title bar (~3:2).
  static let defaultContentSize = NSSize(width: 900, height: 620)
  static let minContentSize = NSSize(width: 720, height: 480)

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.isHidden = true
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      // Content must sit below a normal title bar — never under traffic lights.
      if window.styleMask.contains(.fullSizeContentView) {
        window.styleMask.remove(.fullSizeContentView)
      }
      window.titlebarAppearsTransparent = false
      window.titleVisibility = .visible
      if window.frameAutosaveName != Self.autosaveName {
        window.setFrameAutosaveName(Self.autosaveName)
      }
      if !window.styleMask.contains(.resizable) {
        window.styleMask.insert(.resizable)
      }
      window.contentMinSize = Self.minContentSize
      let minFrame = window.frameRect(
        forContentRect: NSRect(origin: .zero, size: Self.minContentSize))
      window.minSize = minFrame.size

      guard !context.coordinator.didApply else { return }
      context.coordinator.didApply = true
      let key = "NSWindow Frame \(Self.autosaveName)"
      let hasSaved = UserDefaults.standard.string(forKey: key) != nil
      // Only seed the default once per autosave generation. Do not fight a
      // user who later makes the window taller or shorter than 620.
      if !hasSaved {
        window.setContentSize(Self.defaultContentSize)
        if let screen = window.screen ?? NSScreen.main {
          var frame = window.frame
          let visible = screen.visibleFrame
          frame.origin.x = visible.midX - frame.width / 2
          frame.origin.y = visible.midY - frame.height / 2
          window.setFrame(frame, display: true)
        }
        window.saveFrame(usingName: Self.autosaveName)
      }
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var didApply = false
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

/// The red close button saves, the same way Escape does. A second save from
/// Escape is the same settings already stored.
private struct SettingsAutosave: NSViewRepresentable {
  var onClose: () -> Void

  func makeNSView(context: Context) -> SettingsAutosaveView {
    let view = SettingsAutosaveView()
    view.onClose = onClose
    return view
  }

  func updateNSView(_ view: SettingsAutosaveView, context: Context) {
    view.onClose = onClose
  }
}

private final class SettingsAutosaveView: NSView {
  var onClose: (() -> Void)?
  private var observer: NSObjectProtocol?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let observer {
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
    }
    guard let window else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.onClose?()
      }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}

/// Double-click on the volume slider resets to 0 dB. The view does not take
/// the click, so a drag still moves the slider.
private struct SliderDoubleClick: NSViewRepresentable {
  var action: () -> Void

  func makeNSView(context: Context) -> SliderDoubleClickView {
    let view = SliderDoubleClickView()
    view.action = action
    return view
  }

  func updateNSView(_ view: SliderDoubleClickView, context: Context) {
    view.action = action
  }
}

private final class SliderDoubleClickView: NSView {
  var action: (() -> Void)?
  private var monitor: Any?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      guard let self, let window = self.window, event.window === window, event.clickCount == 2
      else { return event }
      let point = self.convert(event.locationInWindow, from: nil)
      guard self.bounds.contains(point) else { return event }
      MainActor.assumeIsolated {
        self.action?()
      }
      return nil
    }
  }

  deinit {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}

struct LabeledRow<Content: View>: View {
  var title: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.system(size: 13))
        .foregroundStyle(AppChrome.helper)
        .frame(width: 120, alignment: .leading)
      content()
    }
  }
}
