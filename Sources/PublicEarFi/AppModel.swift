import AVFoundation
import AppKit
import Foundation
import PublicEarFiCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  @Published var settings: AppSettings
  @Published var phase: BroadcastPhase = .stopped
  @Published var health = "Ready"
  @Published var listeners = 0
  @Published var devices: [AudioInputDevice] = []
  @Published var networks: [NetworkCandidate] = []
  @Published var levelDB = -120.0
  @Published var levelFraction = 0.0
  @Published var noSignal = false
  @Published var logLines: [String] = []
  @Published var showFirstRun = false
  @Published var showFirewall = false
  @Published var showWhy = false
  @Published var showQR = false
  @Published var onBattery = false
  @Published var knownSSID: String?
  /// Poster Wi-Fi password. Held in memory for the poster and the Settings
  /// field. The Keychain is the only copy on disk. Never log this value.
  @Published var posterPassword = ""
  @Published var posterPasswordNotice: String?
  @Published var now = Date()
  @Published var loginItemMessage: String?
  @Published var qrImage: NSImage?
  @Published var selectedLicense: CreditComponent?
  @Published var strayHelper: StrayHelper?
  /// Bumped when Reset replaces every control, so text fields rebuild.
  @Published var settingsRevision = 0

  let credits: CreditsDocument?
  private let store: SettingsStore
  private let logger: FileLogger
  private let controller: BroadcastController
  private let meter = LevelMeter()
  private let hotplug = AudioHotplug()
  private let pathWatcher = PathWatcher()
  private let sleepAssertion = SleepAssertion()
  private var runningSignature: BroadcastSignature?
  private var didAutoStart = false
  private var lastAnnouncedLevel = Int.min
  private var peakFraction = 0.0
  private var peakHoldUntil = Date.distantPast
  var meterPeakFraction: Double { peakFraction }
  private var lastAnnouncedIP: String?
  private var lastDeviceName = "audio interface"
  private var feedingDeviceName = ""
  /// True from the moment Start is requested until the broadcast stops.
  /// The preview meter must not open the device during this time: a second
  /// engine rebinding it leaves the 48 kHz capture tap with nothing to write.
  private var captureOwnsInput = false
  /// Last known LAN reachability while live, for Wi-Fi lost/restored alerts.
  private var hadReachableLAN: Bool?
  private var lastDockVUUpdate = Date.distantPast
  private var silenceWatch = SilenceWatch()
  private var timer: Timer?
  private var meterTimer: Timer?

  init() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    logger = FileLogger(directory: AppPaths.logDirectory(home: home))
    controller = BroadcastController(logger: logger)
    store = SettingsStore()
    let resolved = store.loadResolved()
    settings = resolved.settings
    let passwordLoad = PosterPasswordStore.load()
    posterPassword = passwordLoad.password
    if passwordLoad.unreadable {
      posterPasswordNotice = "The saved Wi-Fi password could not be read from the Keychain."
    }
    credits = BundledResources.credits()
    controller.onPhase = { [weak self] phase in
      Task { @MainActor in self?.apply(phase: phase) }
    }
    controller.onHealth = { [weak self] line in
      Task { @MainActor in self?.health = line }
    }
    controller.onListeners = { [weak self] count in
      Task { @MainActor in
        guard let self else { return }
        let previous = self.listeners
        self.listeners = count
        if previous != count {
          self.announce("\(count) listening")
        }
        self.refreshChrome()
      }
    }
    controller.onLog = { [weak self] line in
      Task { @MainActor in self?.appendLog(line) }
    }
    controller.onStray = { [weak self] stray in
      Task { @MainActor in self?.strayHelper = stray }
    }
    let located = HelperLocator.locate()
    let helperPaths = located.map { [$0.mediamtx.path, $0.ffmpeg.path] } ?? []
    controller.reapStaleChildren(settings: settings, helperPaths: helperPaths)
    var notices: [String] = []
    if let notice = resolved.notice {
      notices.append(notice)
    }
    notices += adoptDeviceList(AudioDeviceList.inputs())
    if let helpers = located,
      let conflict = controller.bundledConflict(
        settings: settings,
        helperPaths: [helpers.mediamtx.path, helpers.ffmpeg.path]
      )
    {
      strayHelper = conflict.stray
      notices.append(conflict.message)
    }
    noteSettings(notices)
    refreshDevices(startMeter: false)
    refreshNetwork()
    hotplug.start { [weak self] in
      Task { @MainActor in self?.refreshDevices() }
    }
    pathWatcher.start { [weak self] in
      Task { @MainActor in self?.refreshNetwork() }
    }
    if !UserDefaults.standard.bool(forKey: Self.firstRunKey) {
      showFirstRun = true
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
      [weak self] _ in
      Task { @MainActor in self?.pollMeter() }
    }
    Self.shared = self
  }

  var isBroadcasting: Bool {
    switch phase {
    case .stopped, .blocked:
      return false
    default:
      return true
    }
  }

  /// Dock badge / VU and the floating mini-player.
  func refreshChrome() {
    DockFeedback.shared.sync(
      listeners: listeners, level: levelFraction, broadcasting: isBroadcasting)
    MiniPlayerController.shared.sync()
  }

  var hasPendingChanges: Bool {
    guard let runningSignature, isBroadcasting else { return false }
    return BroadcastSignature(settings) != runningSignature
  }

  var rankedNetworks: [NetworkCandidate] {
    NetworkSelection.ranked(networks)
  }

  var selectedIP: String? {
    if let chosen = settings.advertisedAddress,
      rankedNetworks.contains(where: { $0.address == chosen })
    {
      return chosen
    }
    return rankedNetworks.first?.address
  }

  var hostname: String {
    InterfaceEnumerator.localHostname()
  }

  var defaultBroadcastTitle: String {
    BroadcastTitle.resolved(stored: "", appName: AppIdentity.name)
  }

  var broadcastTitle: String {
    BroadcastTitle.resolved(stored: settings.broadcastTitle, appName: AppIdentity.name)
  }

  var listenerURL: String? {
    ListenerLink.make(
      style: settings.urlStyle,
      ipAddress: selectedIP,
      localHostname: hostname,
      port: settings.listenerPort
    )
  }

  var secondaryURL: String? {
    guard settings.urlStyle == .ip else { return nil }
    return ListenerLink.make(
      style: .localHostname,
      ipAddress: nil,
      localHostname: hostname,
      port: settings.listenerPort
    )
  }

  var staleAddress: StaleAddress? {
    ListenerLink.staleWarning(previousURL: store.posterStamp()?.url, currentURL: listenerURL)
  }

  var versionLabel: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    let build = info?["CFBundleVersion"] as? String ?? "0"
    let commit = info?["RoomCastCommit"] as? String ?? "dev"
    return "\(short) (\(build), \(commit))"
  }

  var selectedDevice: AudioInputDevice? {
    if let uid = settings.inputDeviceUID {
      return devices.first { $0.id == uid }
    }
    let candidates = devices.map {
      DeviceCandidate(
        uid: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn, inputChannels: $0.inputChannels)
    }
    guard let preferred = DeviceSelection.preferred(devices: candidates, rememberedUID: nil) else {
      return nil
    }
    return devices.first { $0.id == preferred.uid }
  }

  func statusLine() -> String {
    switch phase {
    case .stopped:
      let name = selectedDevice?.name ?? String(localized: "No device")
      return String(format: String(localized: "Stopped · Sound from: %@"), name)
    case .starting:
      return "Starting…"
    case .waitingForDevice(let name):
      return "Problem: Audio interface unplugged, waiting for \(name)…"
    case .problem(let reason), .blocked(let reason):
      return "Problem: \(reason)"
    case .live(let since):
      let feeding = feedingDeviceName.isEmpty ? lastDeviceName : feedingDeviceName
      let name = feeding.isEmpty ? "audio interface" : feeding
      return "Live · \(elapsed(since: since)) · \(name)"
    }
  }

  func onAppear() {
    refreshQR()
    if !showFirstRun {
      restartMeter()
    }
    if settings.startWhenAppOpens && !didAutoStart && !showFirstRun {
      didAutoStart = true
      beginBroadcast()
    }
  }

  func shutdown() {
    timer?.invalidate()
    timer = nil
    meterTimer?.invalidate()
    meterTimer = nil
    controller.stopAndWait()
    sleepAssertion.release()
    meter.stop()
    hotplug.stop()
    pathWatcher.stop()
  }

  /// Shows the welcome sheet again. Does not clear `roomcast.didFinishFirstRun`,
  /// so a later launch still skips the sheet until the person finishes it.
  func reopenGettingStarted() {
    showFirstRun = true
  }

  func finishFirstRun() {
    UserDefaults.standard.set(true, forKey: Self.firstRunKey)
    showFirstRun = false
    // Ask for mic access then open Settings — no intermediate alert.
    AVCaptureDevice.requestAccess(for: .audio) { _ in
      Task { @MainActor in
        self.refreshDevices()
        self.restartMeter()
        self.openSettings()
      }
    }
  }

  func openSettings() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
  }

  /// Settings are already written on each change. This flushes that copy.
  /// The Settings window closes itself from the button that called this.
  func saveAndCloseSettings() {
    store.save(settings)
  }

  func toggleBroadcast() {
    if isBroadcasting {
      if listeners > 0 {
        confirmStopWhileListenersRemain()
        return
      }
      controller.stop()
      return
    }
    if !UserDefaults.standard.bool(forKey: Self.firewallKey) {
      showFirewall = true
      return
    }
    beginBroadcast()
  }

  /// Cancel is the first button, so Return and Escape leave the stream up.
  private func confirmStopWhileListenersRemain() {
    let count = listeners
    let alert = NSAlert()
    if count == 1 {
      alert.messageText = String(localized: "Stop broadcasting? 1 person is listening.")
    } else {
      alert.messageText = String(
        format: String(localized: "Stop broadcasting? %d people are listening."), count)
    }
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Cancel"))
    let stop = alert.addButton(withTitle: String(localized: "Stop Broadcasting"))
    stop.hasDestructiveAction = true
    if alert.runModal() == .alertSecondButtonReturn {
      controller.stop()
    }
  }

  private func announce(_ message: String) {
    let info: [NSAccessibility.NotificationUserInfoKey: Any] = [
      .announcement: message,
      .priority: NSNumber(value: NSAccessibilityPriorityLevel.medium.rawValue),
    ]
    NSAccessibility.post(
      element: NSApp, notification: .announcementRequested, userInfo: info)
  }

  func confirmFirewallAndStart() {
    UserDefaults.standard.set(true, forKey: Self.firewallKey)
    showFirewall = false
    beginBroadcast()
  }

  func applyNow() {
    beginBroadcast()
  }

  func resetDefaults() {
    if case .failed(let status) = PosterPasswordStore.delete() {
      posterPasswordNotice =
        "The Wi-Fi password could not be removed from the Keychain (error \(status))."
    } else {
      posterPasswordNotice = nil
    }
    posterPassword = ""
    settings = store.reset()
    settingsRevision += 1
    loginItemMessage = nil
    try? LoginItemController.apply(false)
    objectWillChange.send()
    refreshDevices()
    refreshQR()
    if case .blocked = phase {
      phase = .stopped
      health = "Ready"
    }
  }

  func restoreInstructions() {
    mutate { $0.posterInstructions = PosterBuilder.defaultInstructions }
  }

  func useCurrentNetworkName() {
    guard let knownSSID, !knownSSID.isEmpty else { return }
    mutate { $0.posterNetworkName = knownSSID }
  }

  func setPosterPassword(_ value: String) {
    posterPassword = value
    switch PosterPasswordStore.save(value) {
    case .saved, .cleared:
      posterPasswordNotice = nil
    case .failed(let status):
      posterPasswordNotice =
        "The Wi-Fi password could not be saved in the Keychain (error \(status))."
    }
  }

  func setInputGain(_ db: Double) {
    let clamped = InputGain.clamped(db)
    mutate { $0.inputGainDB = clamped }
    meter.setGainDB(clamped)
    controller.setInputGain(clamped)
  }

  func chooseDevice(_ uid: String?) {
    let trimmed = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
    let stored = (trimmed?.isEmpty == false) ? trimmed : nil
    mutate { $0.inputDeviceUID = stored }
    restartMeter()
    if isBroadcasting {
      let device = stored.flatMap { value in devices.first { $0.id == value } }
      noteFeedingDevice(device?.name)
      controller.deviceChanged(
        name: device?.name, deviceID: device?.deviceID, present: device != nil)
    }
  }

  func mutate(_ body: (inout AppSettings) -> Void) {
    var copy = settings
    body(&copy)
    settings = copy
    store.save(settings)
    refreshQR()
    controller.setPageTitle(broadcastTitle)
    if settings.launchAtLogin {
      do {
        try LoginItemController.apply(true)
        loginItemMessage = nil
      } catch {
        loginItemMessage =
          "Launch at login needs the installed RoomCast.app (\(error.localizedDescription))."
      }
    } else {
      try? LoginItemController.apply(false)
      loginItemMessage = nil
    }
    updateSleepAssertion()
  }

  func stopStrayHelper() {
    guard let stray = strayHelper else { return }
    controller.stopStray(stray) { stopped in
      Task { @MainActor in
        guard stopped else { return }
        self.strayHelper = nil
        if case .blocked = self.phase {
          self.phase = .stopped
          self.health = "Ready"
        }
      }
    }
  }

  func copyLink() {
    guard let listenerURL else { return }
    Clipboard.copy(listenerURL)
  }

  func openQuickPosterPDF() {
    guard let page = quickPosterModel() else { return }
    let url = AppPaths.posterFile(home: FileManager.default.homeDirectoryForCurrentUser)
    PosterActions.writeAndOpenPDF(model: page, url: url) { self.rememberPoster() }
  }

  private func quickPosterModel() -> PosterRenderModel? {
    guard let listenerURL else { return nil }
    let paper = settings.resolvedPaperSize(
      regionCode: Locale.current.region?.identifier,
      measurementSystemIsUS: Locale.current.measurementSystem == .us
    )
    let network = settings.posterNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
    let plan = PosterBuilder.quickPlan(
      networkName: network,
      password: posterPassword,
      security: settings.posterWiFiSecurity,
      hidden: settings.posterWiFiHidden,
      listenerURL: listenerURL
    )
    if plan.includesWiFiCode {
      let codes = plan.codes.map { code in
        PosterCodeBlock(
          label: code.label,
          image: QRCodeMaker.image(text: code.payload, side: 2048),
          lines: code.lines
        )
      }
      return PosterRenderModel(
        header: broadcastTitle,
        description: "",
        steps: [],
        url: listenerURL,
        qr: nil,
        showFooter: true,
        paper: paper,
        footerText: PosterBuilder.poweredBy,
        headerPoints: 36,
        stepPoints: 16,
        qrFraction: 0.42,
        codes: codes,
        closing: plan.closing
      )
    }
    return PosterRenderModel(
      header: broadcastTitle,
      description: "",
      steps: plan.steps,
      url: listenerURL,
      qr: QRCodeMaker.image(text: plan.codes.first?.payload ?? listenerURL, side: 2048),
      showFooter: true,
      paper: paper,
      footerText: PosterBuilder.poweredBy,
      headerPoints: 44,
      stepPoints: 17,
      qrFraction: 0.62
    )
  }

  func copyQRImage() {
    guard let listenerURL, let data = QRCodeMaker.pngData(text: listenerURL) else { return }
    Clipboard.copyPNG(data)
  }

  func exportPosterPDF() {
    PosterActions.exportPDF(
      model: PosterDocument.renderModel(from: self, highResolutionQR: true)
    ) {
      self.rememberPoster()
    }
  }

  var healthLine: String {
    let line = health.split(whereSeparator: \.isNewline).first.map(String.init) ?? health
    return line.isEmpty ? "Ready" : line
  }

  func copyDiagnostics() {
    let helperSummary =
      credits?.components.map { "\($0.name) \($0.version) \($0.license)" }.joined(separator: "\n")
      ?? "credits unavailable"
    let report = DiagnosticsReport.make(
      appVersion: versionLabel,
      systemDescription: ProcessInfo.processInfo.operatingSystemVersionString,
      settings: settings,
      appName: AppIdentity.name,
      listenerURL: listenerURL ?? "(no LAN address)",
      helperSummary: helperSummary,
      logLines: logger.recent(200)
    )
    Clipboard.copy(report)
  }

  func copyNotices() {
    guard let credits else { return }
    var bodies: [String: String] = [:]
    for component in credits.components {
      bodies[component.id] = BundledResources.licenseText(for: component)
    }
    Clipboard.copy(credits.plainText(licenseBodies: bodies))
  }

  func rememberPoster() {
    guard let listenerURL else { return }
    store.rememberPoster(url: listenerURL)
    objectWillChange.send()
  }

  func showAboutPanel() {
    let text = credits?.plainText() ?? "RoomCast\nCopyright (c) 2026 Walter Kaan. MIT License."
    NSApp.orderFrontStandardAboutPanel(options: [
      .credits: NSAttributedString(string: text)
    ])
  }

  func openGitHub() {
    if let url = URL(string: "https://github.com/walterkaan/public-earfi") {
      NSWorkspace.shared.open(url)
    }
  }

  /// How to send another app's audio through a loopback device.
  func openMusicFAQ() {
    if let url = URL(string: "https://roomcast.channel/faq.html#music") {
      NSWorkspace.shared.open(url)
    }
  }

  /// The public FAQ, in the default browser.
  func openFAQ() {
    if let url = URL(string: "https://roomcast.channel/faq.html") {
      NSWorkspace.shared.open(url)
    }
  }

  /// The public troubleshooting guide.
  func openTroubleshooting() {
    if let url = URL(string: "https://roomcast.channel/troubleshooting.html") {
      NSWorkspace.shared.open(url)
    }
  }

  func openNotices() {
    if let url = URL(
      string: "https://github.com/walterkaan/public-earfi/blob/main/THIRD_PARTY_NOTICES.md")
    {
      NSWorkspace.shared.open(url)
    }
  }

  private func beginBroadcast() {
    var notices = adoptDeviceList(AudioDeviceList.inputs())
    let (repaired, fields) = SettingsRepair.applying(settings)
    if repaired != settings {
      settings = repaired
      store.save(settings)
      if let notice = SettingsRepair.notice(for: fields) {
        notices.append(notice)
      }
    }
    if let channel = clampChannelToSelectedDevice() {
      notices.append(channel)
    }
    if !notices.isEmpty {
      noteSettings(notices)
      restartMeter()
      return
    }
    let issues = validate(settings)
    if let issue = issues.first {
      phase = .blocked(issue.message)
      health = issue.message
      return
    }
    guard let helpers = HelperLocator.locate() else {
      phase = .problem(
        "Bundled mediamtx or ffmpeg is missing. Build them with scripts/build-helpers.sh.")
      return
    }
    let device = selectedDevice
    if let device {
      lastDeviceName = device.name
      feedingDeviceName = device.name
      if settings.inputDeviceUID == nil {
        settings.inputDeviceUID = device.id
        store.save(settings)
      }
    }
    let snapshot = settings
    let host = snapshot.advertisedAddress
    runningSignature = BroadcastSignature(snapshot)
    captureOwnsInput = true
    meter.stop()
    controller.setInputGain(snapshot.inputGainDB)
    controller.start(
      BroadcastLaunch(
        settings: snapshot,
        deviceName: device?.name,
        deviceID: device?.deviceID,
        devicePresent: device != nil,
        advertisedHost: host,
        helpers: helpers,
        home: FileManager.default.homeDirectoryForCurrentUser,
        prepareAudio: {
          // The app opens this device with Core Audio and writes 48 kHz
          // PCM to ffmpeg. Do not change the interface clock, and do not
          // capture with ffmpeg's avfoundation device.
          guard device != nil else { return "No input device is available." }
          return nil
        },
        pageTitle: broadcastTitle
      )
    )
  }

  private func apply(phase: BroadcastPhase) {
    self.phase = phase
    switch phase {
    case .stopped, .blocked:
      listeners = 0
      runningSignature = nil
      captureOwnsInput = false
      hadReachableLAN = nil
      restartMeter()
    case .starting, .live, .waitingForDevice, .problem:
      captureOwnsInput = true
      meter.stop()
      if hadReachableLAN == nil {
        hadReachableLAN = rankedNetworks.contains(where: \.isUp) && selectedIP != nil
      }
    }
    updateSleepAssertion()
    refreshChrome()
  }

  private func updateSleepAssertion() {
    let live: Bool
    if case .live = phase {
      live = true
    } else if case .starting = phase {
      live = true
    } else if case .waitingForDevice = phase {
      live = true
    } else if case .problem = phase {
      live = isBroadcasting
    } else {
      live = false
    }
    sleepAssertion.set(enabled: live && settings.keepAwake)
  }

  private func pollMeter() {
    if captureOwnsInput {
      let decibels = controller.recentCaptureDecibels()
      levelDB = decibels
      levelFraction = min(1, max(0, (decibels + 60) / 60))
    } else {
      let reading = meter.latest()
      levelDB = reading.decibels
      levelFraction = reading.fraction
    }
    notePeak()
    noteLevelAnnouncement()
    if isBroadcasting {
      let now = Date()
      if now.timeIntervalSince(lastDockVUUpdate) >= 0.12 {
        lastDockVUUpdate = now
        DockFeedback.shared.sync(
          listeners: listeners, level: levelFraction, broadcasting: true)
        MiniPlayerController.shared.sync()
      }
    }
  }

  private func notePeak() {
    let level = min(1, max(0, levelFraction))
    let moment = Date()
    if level >= peakFraction {
      peakFraction = level
      peakHoldUntil = moment.addingTimeInterval(0.9)
    } else if moment > peakHoldUntil {
      peakFraction = max(level, peakFraction - 0.02)
    }
  }

  /// VoiceOver hears a move of about 6 dB. The meter also exposes the exact
  /// value while it is focused, so every frame is not spoken.
  private func noteLevelAnnouncement() {
    let shown = levelDB <= -100 ? -100 : Int(levelDB.rounded())
    if lastAnnouncedLevel == Int.min {
      lastAnnouncedLevel = shown
      return
    }
    if abs(shown - lastAnnouncedLevel) < 6 { return }
    lastAnnouncedLevel = shown
    if shown <= -100 {
      announce("Input level, silent")
    } else {
      announce("Input level \(shown) dB")
    }
  }

  private func tick() {
    now = Date()
    if case .live = phase {
      silenceWatch.update(decibels: controller.recentCaptureDecibels(), now: now)
      noSignal = silenceWatch.showing
    } else {
      silenceWatch.reset()
      noSignal = false
    }
    if isBroadcasting {
      onBattery = PowerStatus.runningOnBattery()
    }
  }

  private func refreshDevices(startMeter: Bool = true) {
    let found = AudioDeviceList.inputs()
    let notices = adoptDeviceList(found)
    if !notices.isEmpty {
      noteSettings(notices)
    }
    let remembered = settings.inputDeviceUID.flatMap { uid in found.first { $0.id == uid } }
    if let remembered {
      lastDeviceName = remembered.name
    }
    if isBroadcasting {
      if settings.inputDeviceUID == nil {
        noteFeedingDevice(selectedDevice?.name)
        controller.deviceChanged(
          name: selectedDevice?.name, deviceID: selectedDevice?.deviceID,
          present: selectedDevice != nil)
      } else {
        noteFeedingDevice(remembered?.name ?? lastDeviceName)
        controller.deviceChanged(
          name: remembered?.name ?? lastDeviceName, deviceID: remembered?.deviceID,
          present: remembered != nil)
      }
    }
    if startMeter {
      restartMeter()
    }
  }

  private func refreshNetwork() {
    networks = InterfaceEnumerator.candidates()
    knownSSID = InterfaceEnumerator.currentSSID()
    let ip = selectedIP
    let reachable = rankedNetworks.contains(where: \.isUp) && ip != nil
    if isBroadcasting {
      if let hadReachableLAN {
        if hadReachableLAN && !reachable {
          BroadcastNotifier.wifiLost()
          health = "Wi-Fi was lost. Broadcasting will resume when the network returns."
        } else if !hadReachableLAN && reachable {
          BroadcastNotifier.wifiRestored()
        }
      }
      hadReachableLAN = reachable
    } else {
      hadReachableLAN = nil
    }
    if let lastAnnouncedIP, let ip, lastAnnouncedIP != ip, isBroadcasting {
      health = "Address changed to \(ip). Listeners need the new link."
    }
    lastAnnouncedIP = ip
    refreshQR()
  }

  private func refreshQR() {
    guard let listenerURL else {
      qrImage = nil
      return
    }
    qrImage = QRCodeMaker.image(text: listenerURL, side: 512)
  }

  /// Stores one row per device. A Bluetooth headset that appears twice during
  /// the call-mode switch keeps a single row, and its selection stays put
  /// when that row disappears for a moment. Does not start the broadcast.
  private var headsetHold = HeadsetSelectionHold()

  private func adoptDeviceList(_ found: [AudioInputDevice]) -> [String] {
    let previous = devices.first { $0.id == settings.inputDeviceUID }
    let listed = found.map {
      ListedInput(
        uid: $0.id,
        name: $0.name,
        isBuiltIn: $0.isBuiltIn,
        inputChannels: $0.inputChannels,
        isBluetooth: $0.isBluetooth
      )
    }
    if settings.inputDeviceUID == nil {
      headsetHold = HeadsetSelectionHold()
    } else if let previous {
      headsetHold.observe(Self.listed(previous))
    }
    let selectedName =
      headsetHold.holds(settings.inputDeviceUID)
      ? (previous?.name ?? headsetHold.name) : previous?.name
    let stable = InputDeviceList.stabilize(
      devices: listed,
      selectedUID: settings.inputDeviceUID,
      selectedName: selectedName)
    devices = Self.pickDevices(found, visible: stable.devices)
    if let uid = stable.selectedUID, uid != settings.inputDeviceUID,
      devices.contains(where: { $0.id == uid })
    {
      settings.inputDeviceUID = uid
      store.save(settings)
    }
    if let current = devices.first(where: { $0.id == settings.inputDeviceUID }) {
      headsetHold.observe(Self.listed(current))
    }
    guard !isBroadcasting else { return [] }
    var notices: [String] = []
    let holdBluetooth = headsetHold.holds(settings.inputDeviceUID)
    if InputDeviceList.shouldForget(
      rememberedUID: settings.inputDeviceUID,
      visibleUIDs: devices.map(\.id),
      holdBluetooth: holdBluetooth
    ), let missing = clearMissingDevice() {
      notices.append(missing)
    }
    if let channel = clampChannelToSelectedDevice() {
      notices.append(channel)
    }
    return notices
  }

  private static func listed(_ device: AudioInputDevice) -> ListedInput {
    ListedInput(
      uid: device.id,
      name: device.name,
      isBuiltIn: device.isBuiltIn,
      inputChannels: device.inputChannels,
      isBluetooth: device.isBluetooth
    )
  }

  /// Keeps the row with the most input channels when one UID was listed twice.
  private static func pickDevices(_ found: [AudioInputDevice], visible: [ListedInput])
    -> [AudioInputDevice]
  {
    visible.compactMap { item in
      found.filter { $0.id == item.uid }.max { $0.inputChannels < $1.inputChannels }
    }
  }

  private func clearMissingDevice() -> String? {
    guard
      DeviceSelection.isMissing(rememberedUID: settings.inputDeviceUID, devices: deviceCandidates)
    else { return nil }
    settings.inputDeviceUID = nil
    store.save(settings)
    return SettingsRepair.missingDeviceNotice
  }

  private func clampChannelToSelectedDevice() -> String? {
    guard let device = selectedDevice, device.inputChannels > 0 else { return nil }
    guard !SettingsRepair.channelFits(settings.inputChannel, inputCount: device.inputChannels)
    else {
      return nil
    }
    let was = settings.inputChannel
    settings.inputChannel = 1
    store.save(settings)
    return SettingsRepair.channelNotice(was: was)
  }

  private var deviceCandidates: [DeviceCandidate] {
    devices.map {
      DeviceCandidate(
        uid: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn, inputChannels: $0.inputChannels)
    }
  }

  private func noteSettings(_ notices: [String]) {
    let text = notices.filter { !$0.isEmpty }.joined(separator: " ")
    guard !text.isEmpty else { return }
    if case .live = phase { return }
    if case .starting = phase { return }
    if case .waitingForDevice = phase { return }
    phase = .blocked(text)
    health = text
  }

  private func restartMeter() {
    guard !captureOwnsInput else {
      meter.stop()
      return
    }
    meter.setGainDB(settings.inputGainDB)
    meter.start(deviceID: selectedDevice?.deviceID)
  }

  private func appendLog(_ line: String) {
    logLines.append(line)
    if logLines.count > 2_000 {
      logLines.removeFirst(logLines.count - 2_000)
    }
  }

  private func noteFeedingDevice(_ name: String?) {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return }
    feedingDeviceName = trimmed
    lastDeviceName = trimmed
  }

  private func elapsed(since: Date) -> String {
    let interval = max(0, Int(now.timeIntervalSince(since)))
    return String(format: "%02d:%02d:%02d", interval / 3600, (interval / 60) % 60, interval % 60)
  }

  private static let firstRunKey = "roomcast.didFinishFirstRun"
  private static let firewallKey = "roomcast.didExplainFirewall"
  static weak var shared: AppModel?
}
