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
  @Published var showCredits = false
  @Published var showFirstRun = false
  @Published var showFirewall = false
  @Published var showWhy = false
  @Published var showQR = false
  @Published var onBattery = false
  @Published var knownSSID: String?
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
  private var silenceSince: Date?
  private var runningSignature: BroadcastSignature?
  private var didAutoStart = false
  private var lastAnnouncedIP: String?
  private var lastDeviceName = "audio interface"
  private var timer: Timer?
  private var meterTimer: Timer?

  init() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    logger = FileLogger(directory: AppPaths.logDirectory(home: home))
    controller = BroadcastController(logger: logger)
    store = SettingsStore()
    let resolved = store.loadResolved()
    settings = resolved.settings
    credits = BundledResources.credits()
    controller.onPhase = { [weak self] phase in
      Task { @MainActor in self?.apply(phase: phase) }
    }
    controller.onHealth = { [weak self] line in
      Task { @MainActor in self?.health = line }
    }
    controller.onListeners = { [weak self] count in
      Task { @MainActor in self?.listeners = count }
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
    knownSSID = InterfaceEnumerator.currentSSID()
  }

  var isBroadcasting: Bool {
    switch phase {
    case .stopped, .blocked:
      return false
    default:
      return true
    }
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

  var listenerURL: String? {
    ListenerLink.make(
      style: settings.urlStyle,
      ipAddress: selectedIP,
      localHostname: hostname,
      port: settings.listenerPort,
      streamName: settings.streamName
    )
  }

  var secondaryURL: String? {
    guard settings.urlStyle == .ip else { return nil }
    return ListenerLink.make(
      style: .localHostname,
      ipAddress: nil,
      localHostname: hostname,
      port: settings.listenerPort,
      streamName: settings.streamName
    )
  }

  var staleAddress: StaleAddress? {
    ListenerLink.staleWarning(previousURL: store.posterStamp()?.url, currentURL: listenerURL)
  }

  var versionLabel: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    let build = info?["CFBundleVersion"] as? String ?? "0"
    let commit = info?["PublicEarFiCommit"] as? String ?? "dev"
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
      return "Stopped"
    case .starting:
      return "Starting…"
    case .waitingForDevice(let name):
      return "Problem: Audio interface unplugged, waiting for \(name)…"
    case .problem(let reason), .blocked(let reason):
      return "Problem: \(reason)"
    case .live(let since):
      return "Live · \(elapsed(since: since)) · \(levelDB < -50 ? "quiet" : "audio healthy")"
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

  func finishFirstRun() {
    UserDefaults.standard.set(true, forKey: Self.firstRunKey)
    showFirstRun = false
    AVCaptureDevice.requestAccess(for: .audio) { _ in
      Task { @MainActor in
        self.refreshDevices()
        self.restartMeter()
      }
    }
  }

  func toggleBroadcast() {
    if isBroadcasting {
      controller.stop()
      return
    }
    if !UserDefaults.standard.bool(forKey: Self.firewallKey) {
      showFirewall = true
      return
    }
    beginBroadcast()
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
    if settings.launchAtLogin {
      do {
        try LoginItemController.apply(true)
        loginItemMessage = nil
      } catch {
        loginItemMessage =
          "Launch at login needs the installed Public EarFi.app (\(error.localizedDescription))."
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
    let text = credits?.plainText() ?? "Public EarFi\nCopyright (c) 2026 Walter Kaan. MIT License."
    NSApp.orderFrontStandardAboutPanel(options: [
      .credits: NSAttributedString(string: text)
    ])
  }

  func openGitHub() {
    if let url = URL(string: "https://github.com/walterkaan/public-earfi") {
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
      if settings.inputDeviceUID == nil {
        settings.inputDeviceUID = device.id
        store.save(settings)
      }
    }
    let snapshot = settings
    let host = snapshot.advertisedAddress
    runningSignature = BroadcastSignature(snapshot)
    restartMeter()
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
        }
      )
    )
  }

  private func apply(phase: BroadcastPhase) {
    self.phase = phase
    if case .stopped = phase {
      listeners = 0
      runningSignature = nil
    }
    if case .blocked = phase {
      listeners = 0
      runningSignature = nil
    }
    updateSleepAssertion()
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
    let reading = meter.latest()
    levelDB = reading.decibels
    levelFraction = reading.fraction
  }

  private func tick() {
    now = Date()
    if case .live = phase, controller.recentCaptureDecibels() < CaptureFormatPlan.silenceDB {
      if silenceSince == nil { silenceSince = now }
      noSignal =
        now.timeIntervalSince(silenceSince ?? now) >= CaptureFormatPlan.silenceWarningSeconds
    } else {
      silenceSince = nil
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
        controller.deviceChanged(
          name: selectedDevice?.name, deviceID: selectedDevice?.deviceID,
          present: selectedDevice != nil)
      } else {
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
    let ip = selectedIP
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

  /// Stores the device list and clears a remembered device or channel that
  /// cannot be used. Does not start the broadcast.
  private func adoptDeviceList(_ found: [AudioInputDevice]) -> [String] {
    devices = found
    guard !isBroadcasting else { return [] }
    var notices: [String] = []
    if let missing = clearMissingDevice() {
      notices.append(missing)
    }
    if let channel = clampChannelToSelectedDevice() {
      notices.append(channel)
    }
    return notices
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
    guard let device = selectedDevice else { return nil }
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
    meter.setGainDB(settings.inputGainDB)
    meter.start(deviceID: selectedDevice?.deviceID)
  }

  private func appendLog(_ line: String) {
    logLines.append(line)
    if logLines.count > 2_000 {
      logLines.removeFirst(logLines.count - 2_000)
    }
  }

  private func elapsed(since: Date) -> String {
    let interval = max(0, Int(now.timeIntervalSince(since)))
    return String(format: "%02d:%02d:%02d", interval / 3600, (interval / 60) % 60, interval % 60)
  }

  private static let firstRunKey = "publicEarfi.didFinishFirstRun"
  private static let firewallKey = "publicEarfi.didExplainFirewall"
  static weak var shared: AppModel?
}
