import CoreAudio
import Darwin
import Foundation
import PublicEarFiCore

enum BroadcastPhase: Equatable {
  case stopped
  case starting
  case live(since: Date)
  case waitingForDevice(String)
  case problem(String)
  /// A port is taken, or a leftover helper is still running. Not retrying.
  case blocked(String)
}

struct BroadcastLaunch {
  var settings: AppSettings
  var deviceName: String?
  var deviceID: AudioDeviceID?
  var devicePresent: Bool
  var advertisedHost: String?
  var helpers: HelperLocations
  var home: URL
  var prepareAudio: () -> String?
}

final class BroadcastController {
  var onPhase: ((BroadcastPhase) -> Void)?
  var onListeners: ((Int) -> Void)?
  var onHealth: ((String) -> Void)?
  var onLog: ((String) -> Void)?
  var onStray: ((StrayHelper?) -> Void)?

  private let queue = DispatchQueue(label: "earfi.supervisor")
  private let haltLock = NSLock()
  private var halt = false
  private var desired = false
  private var stopping = false
  private var mediamtx: Process?
  private var ffmpeg: Process?
  private var ignoredPIDs = Set<Int32>()
  private var failures = 0
  private var stableSince: Date?
  private var stall = StallDetector()
  private var poller: DispatchSourceTimer?
  private var pendingRestart: DispatchWorkItem?
  private var launch: BroadcastLaunch?
  private let logger: FileLogger
  private var frameDrops = 0
  /// Serializes helper stdout/stderr. The file-handle callback is a different
  /// queue, and the supervisor queue is blocked during the ready wait.
  private let outputQueue = DispatchQueue(label: "earfi.output")
  private let epochLock = NSLock()
  private var ffmpegEpoch = 0
  private var mediamtxEpoch = 0
  private var lastFFmpegError: String?
  private var ffmpegOutput = ProcessOutputBuffer()
  private var mediamtxOutput = ProcessOutputBuffer()
  private var ffmpegLog: FileHandle?
  private var ffmpegAttemptClosed = false
  private let capture = CapturePipe()
  private let formatWatch = AudioFormatWatch()
  private var pendingFormat: DispatchWorkItem?
  private var lastFormatSummary = ""
  private var formatBudget = FormatRebuildBudget(limit: CaptureFormatPlan.formatRebuildLimit)
  private var inputSettleAttempts = 0
  private var deviceWentQuiet = false
  /// Device id last seen on Bluetooth. Kept so a brief dropout, when the
  /// transport can no longer be read, is still retried. A different device
  /// clears it.
  private var bluetoothDeviceID: AudioDeviceID = 0
  private var nextLevelLog = Date.distantPast
  private var ffmpegInput: Pipe?
  private var helperPaths: [String] = []
  private var mediamtxLog: FileHandle?

  init(logger: FileLogger) {
    self.logger = logger
  }

  func setInputGain(_ db: Double) {
    capture.setGainDB(db)
  }

  func recentCaptureDecibels() -> Double {
    capture.recentDecibels()
  }

  func start(_ launch: BroadcastLaunch) {
    queue.async {
      self.clearHalt()
      self.pendingRestart?.cancel()
      self.launch = launch
      self.helperPaths = [launch.helpers.mediamtx.path, launch.helpers.ffmpeg.path]
      self.desired = true
      self.stopping = false
      self.failures = 0
      self.frameDrops = 0
      self.stall.reset()
      self.pendingFormat?.cancel()
      self.pendingFormat = nil
      self.formatBudget = FormatRebuildBudget(limit: CaptureFormatPlan.formatRebuildLimit)
      self.inputSettleAttempts = 0
      self.deviceWentQuiet = false
      self.bluetoothDeviceID = 0
      self.lastFormatSummary = ""
      self.launchPipeline()
    }
  }

  /// A bundled helper still holding a port after a crash. Foreign processes
  /// are reported only when Start is pressed.
  func bundledConflict(settings: AppSettings, helperPaths: [String]) -> PortConflict? {
    queue.sync {
      self.helperPaths = helperPaths
      guard let found = PortProbe.conflict(settings: settings, helperPaths: helperPaths),
        found.stray != nil
      else { return nil }
      return found
    }
  }

  func stopStray(_ helper: StrayHelper, done: @escaping (Bool) -> Void) {
    queue.async {
      let stopped = self.terminateStray(helper)
      DispatchQueue.main.async {
        done(stopped)
      }
    }
  }

  func stop() {
    requestHalt()
    queue.async {
      self.finish(reportStopped: true)
    }
  }

  func stopAndWait() {
    requestHalt()
    queue.sync {
      self.finish(reportStopped: true)
    }
  }

  func deviceChanged(name: String?, deviceID: AudioDeviceID?, present: Bool) {
    queue.async {
      guard var launch = self.launch else { return }
      let changed = launch.deviceID != deviceID || launch.devicePresent != present
      launch.deviceName = name
      launch.deviceID = deviceID
      launch.devicePresent = present
      self.launch = launch
      guard self.desired, !self.stopping, !self.isHalted() else { return }
      if !present {
        self.stopCapture()
        self.stopProcess(self.ffmpeg)
        self.ffmpeg = nil
        self.stall.reset()
        let label = (name?.isEmpty == false ? name : nil) ?? "audio interface"
        self.publish(.waitingForDevice(label))
        self.publishHealth(HealthText.waiting(deviceName: label))
      } else if changed || self.ffmpeg?.isRunning != true {
        self.startFFmpeg()
      }
    }
  }

  func reapStaleChildren(settings: AppSettings, helperPaths: [String]) {
    queue.sync {
      self.helperPaths = helperPaths
      self.reapRecorded()
      if let found = PortProbe.conflict(settings: settings, helperPaths: helperPaths),
        let stray = found.stray
      {
        _ = self.terminateStray(stray)
      }
    }
  }

  private func launchPipeline() {
    guard desired, !stopping, !isHalted(), let launch else { return }
    resetMediaMTXLog()
    publish(.starting)
    guard FileManager.default.isExecutableFile(atPath: launch.helpers.mediamtx.path),
      FileManager.default.isExecutableFile(atPath: launch.helpers.ffmpeg.path)
    else {
      desired = false
      publish(
        .problem(
          "Bundled mediamtx or ffmpeg is missing. Run scripts/build-helpers.sh, then scripts/build-app.sh."
        ))
      return
    }
    let issues = validate(launch.settings)
    if let issue = issues.first {
      desired = false
      publish(.problem(issue.message))
      return
    }
    let yaml = MediaMTXConfigWriter.yaml(
      settings: launch.settings, advertisedHost: launch.advertisedHost)
    let configURL = AppPaths.configFile(home: launch.home)
    do {
      try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    } catch {
      noteFailure(component: "mediamtx", detail: "could not write mediamtx.yml")
      return
    }
    stopChildren()
    if let conflict = PortProbe.conflict(settings: launch.settings, helperPaths: helperPaths) {
      halt(conflict)
      return
    }
    guard startMediaMTX(configURL: configURL, launch: launch) else {
      noteFailure(component: "mediamtx", detail: "mediamtx did not start")
      return
    }
    guard waitForAPI() else {
      drainMediaMTXLog()
      if let conflict = bindConflict() {
        halt(conflict)
        return
      }
      noteFailure(component: "mediamtx", detail: "the local API did not answer within 5 s")
      return
    }
    startFFmpeg()
  }

  private func startFFmpeg() {
    guard desired, !stopping, let launch else { return }
    guard launch.devicePresent, let name = launch.deviceName, !name.isEmpty else {
      let label =
        (launch.deviceName?.isEmpty == false ? launch.deviceName : nil) ?? "audio interface"
      publish(.waitingForDevice(label))
      publishHealth(HealthText.waiting(deviceName: label))
      return
    }
    if let warning = launch.prepareAudio() {
      logger.log("audio", warning)
      publishLog("audio", warning)
    }
    stopCapture()
    stopProcess(ffmpeg)
    ffmpeg = nil
    ffmpegAttemptClosed = false
    resetFFmpegErrors()
    guard let deviceID = launch.deviceID else {
      stopWithProblem("No input device is available.")
      return
    }
    if AudioDeviceList.isBluetooth(deviceID) {
      bluetoothDeviceID = deviceID
    } else if bluetoothDeviceID != deviceID {
      bluetoothDeviceID = 0
    }
    guard AudioDeviceList.isAlive(deviceID) else {
      if bluetoothDeviceID == deviceID {
        retrySettlingInput(CaptureFormatPlan.notReadyMessage(deviceName: name))
      } else {
        stopWithProblem("The selected audio device is not connected.")
      }
      return
    }
    let pipe = Pipe()
    ffmpegInput = pipe
    let process = Process()
    process.executableURL = launch.helpers.ffmpeg
    process.arguments = FFmpegCommand.arguments(settings: launch.settings)
    attach(process, source: "ffmpeg")
    process.standardInput = pipe
    do {
      try runInOwnGroup(process)
    } catch {
      noteFailure(component: "ffmpeg", detail: "ffmpeg failed to launch")
      return
    }
    if let problem = capture.start(
      deviceID: deviceID,
      channelMode: launch.settings.channelMode,
      inputChannel: launch.settings.inputChannel,
      output: pipe.fileHandleForWriting,
      deviceName: name
    ) {
      stopCapture()
      abandon(process)
      if CaptureFormatPlan.isInputSettling(problem) {
        retrySettlingInput(problem)
      } else if CaptureFormatPlan.shouldRetry(message: problem) {
        noteFailure(component: "audio", detail: problem)
      } else {
        stopWithProblem(problem)
      }
      return
    }
    ffmpeg = process
    writePIDs()
    inputSettleAttempts = 0
    lastFormatSummary = capture.openedNativeSummary
    nextLevelLog = Date().addingTimeInterval(4)
    let transport = AudioDeviceList.transportDescription(deviceID)
    if AudioDeviceList.isBluetooth(deviceID) {
      bluetoothDeviceID = deviceID
    }
    logger.log(
      "audio",
      "opened \(name): transport \(transport); \(capture.openedFormatSummary); sending 48 kHz \(capture.openedMixNote) float"
    )
    logger.log(
      "ffmpeg",
      "started pid \(process.processIdentifier), Core Audio \(name)"
    )
    formatWatch.start(deviceID: deviceID, queue: queue) { [weak self] in
      self?.scheduleFormatRebuild()
    }
    guard waitUntilReady(stream: launch.settings.streamName) else {
      let stillRunning = process.isRunning
      let status = process.terminationStatus
      stopCapture()
      abandon(process)
      ffmpeg = nil
      let detail =
        stillRunning
        ? "the stream was not ready within 5 s"
        : "exited with status \(status)"
      noteFailure(component: "ffmpeg", detail: detail)
      return
    }
    becameLive()
  }

  private func startMediaMTX(configURL: URL, launch: BroadcastLaunch) -> Bool {
    let process = Process()
    process.executableURL = launch.helpers.mediamtx
    process.arguments = [configURL.path]
    process.currentDirectoryURL = configURL.deletingLastPathComponent()
    attach(process, source: "mediamtx")
    do {
      try runInOwnGroup(process)
    } catch {
      return false
    }
    mediamtx = process
    writePIDs()
    logger.log("mediamtx", "started pid \(process.processIdentifier)")
    return true
  }

  private func attach(_ process: Process, source: String) {
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    let reading = pipe.fileHandleForReading
    if source == "ffmpeg" {
      ffmpegLog = reading
    }
    if source == "mediamtx" {
      mediamtxLog = reading
      resetMediaMTXLog()
    }
    let epoch = beginEpoch(source)
    reading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      self?.outputQueue.async {
        guard let self, self.epochMatches(source, epoch) else { return }
        self.consume(data, source: source)
      }
    }
    process.terminationHandler = { [weak self] process in
      self?.queue.async {
        self?.handleExit(process, source: source)
      }
    }
  }

  /// Runs on `outputQueue`. Line breaks are bytes, so a chunk that ends on
  /// `\n` or a `\r` progress line cannot trip `String.index(after:)`.
  private func consume(_ data: Data, source: String) {
    let lines: [String]
    if source == "ffmpeg" {
      lines = ffmpegOutput.append(data)
    } else {
      lines = mediamtxOutput.append(data)
    }
    for line in lines {
      accept(line, source: source)
    }
  }

  private func accept(_ line: String, source: String) {
    logger.log(source, line)
    publishLog(source, line)
    guard source == "ffmpeg" else { return }
    rememberFailure(line)
    guard StreamLog.isFrameDrop(line) else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.frameDrops += 1
      self.publishHealth("\(self.clock(Date())) frame drops: \(self.frameDrops)")
    }
  }

  private func resetFFmpegErrors() {
    ffmpegLog?.readabilityHandler = nil
    _ = beginEpoch("ffmpeg")
    outputQueue.sync {
      self.lastFFmpegError = nil
      self.ffmpegOutput.reset()
    }
  }

  private func rememberFailure(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if StreamLog.isFailure(trimmed) {
      lastFFmpegError = trimmed
    }
  }

  private func ffmpegErrorLine() -> String? {
    outputQueue.sync {
      self.rememberFailure(self.ffmpegOutput.remainder)
      return self.lastFFmpegError
    }
  }

  private func beginEpoch(_ source: String) -> Int {
    epochLock.lock()
    defer { epochLock.unlock() }
    if source == "ffmpeg" {
      ffmpegEpoch += 1
      return ffmpegEpoch
    }
    mediamtxEpoch += 1
    return mediamtxEpoch
  }

  private func epochMatches(_ source: String, _ epoch: Int) -> Bool {
    epochLock.lock()
    defer { epochLock.unlock() }
    let current = source == "ffmpeg" ? ffmpegEpoch : mediamtxEpoch
    return current == epoch
  }

  private func handleExit(_ process: Process, source: String) {
    if ignoredPIDs.contains(process.processIdentifier) {
      ignoredPIDs.remove(process.processIdentifier)
      return
    }
    if process.processIdentifier == mediamtx?.processIdentifier {
      mediamtx = nil
    }
    if process.processIdentifier == ffmpeg?.processIdentifier {
      ffmpeg = nil
      stopCapture()
      drainFFmpegLog()
    }
    guard desired, !stopping, !isHalted() else { return }
    let status = process.terminationStatus
    logger.log(source, "exited with status \(status)")
    if source == "mediamtx" {
      drainMediaMTXLog()
      if let conflict = bindConflict() {
        halt(conflict)
        return
      }
      noteFailure(component: "mediamtx", detail: "mediamtx exited with status \(status)")
    } else {
      noteFailure(component: "ffmpeg", detail: "exited with status \(status)")
    }
  }

  private func drainFFmpegLog() {
    guard let handle = ffmpegLog else { return }
    handle.readabilityHandler = nil
    let data = handle.availableData
    guard !data.isEmpty else { return }
    outputQueue.sync {
      self.consume(data, source: "ffmpeg")
    }
  }

  private func abandon(_ process: Process?) {
    guard let process else { return }
    signalAndWait([process])
    drainFFmpegLog()
  }

  private func becameLive() {
    stableSince = Date()
    stall.reset()
    publishStray(nil)
    publish(.live(since: stableSince ?? Date()))
    publishHealth("\(clock(Date())) audio healthy")
    startPoller()
  }

  /// Leaves a problem on screen and does not schedule another Start.
  private func stopWithProblem(_ message: String) {
    desired = false
    pendingRestart?.cancel()
    stopPoller()
    stopChildren()
    logger.log("audio", message)
    publish(.blocked(message))
    publishHealth(message)
  }

  /// Stops the restart loop and leaves the port message on screen.
  private func halt(_ conflict: PortConflict) {
    desired = false
    pendingRestart?.cancel()
    stopPoller()
    stopChildren()
    logger.log("mediamtx", conflict.message)
    publish(.blocked(conflict.message))
    publishHealth(conflict.message)
    publishStray(conflict.stray)
  }

  private func bindConflict() -> PortConflict? {
    let excerpt = mediamtxExcerpt()
    guard !RestartPolicy.retries(detail: excerpt, logExcerpt: excerpt),
      let settings = launch?.settings
    else { return nil }
    return PortProbe.conflict(settings: settings, helperPaths: helperPaths)
      ?? PortConflictText.fromLog(
        excerpt, listenerPort: settings.listenerPort, icePort: settings.icePort)
  }

  private func terminateStray(_ helper: StrayHelper) -> Bool {
    guard helper.pid > 1 else { return false }
    let path = ProcessPath.executablePath(pid: helper.pid)
    guard path == helper.executablePath,
      HelperIdentity.isBundledHelper(executablePath: path, knownHelperPaths: helperPaths)
    else {
      logger.log("supervisor", "refused to stop pid \(helper.pid); it is not a Public EarFi helper")
      return false
    }
    let target = ChildStop.Target(pid: helper.pid, group: getpgid(helper.pid))
    kill(target.signalTarget, ChildStop.termSignal)
    let grace = Date().addingTimeInterval(ChildStop.grace)
    while processIsAlive(helper.pid) && Date() < grace {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if processIsAlive(helper.pid) {
      kill(target.signalTarget, ChildStop.killSignal)
      let hard = Date().addingTimeInterval(1)
      while processIsAlive(helper.pid) && Date() < hard {
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    let stopped = !processIsAlive(helper.pid)
    if stopped {
      logger.log("supervisor", "stopped leftover \(helper.processName) pid \(helper.pid)")
      publishStray(nil)
    }
    return stopped
  }

  private func processIsAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
  }

  private func resetMediaMTXLog() {
    mediamtxLog?.readabilityHandler = nil
    _ = beginEpoch("mediamtx")
    outputQueue.sync {
      self.mediamtxOutput.reset()
    }
  }

  private func mediamtxExcerpt() -> String {
    outputQueue.sync {
      self.mediamtxOutput.excerpt
    }
  }

  private func drainMediaMTXLog() {
    guard let handle = mediamtxLog else { return }
    handle.readabilityHandler = nil
    let data = handle.availableData
    guard !data.isEmpty else { return }
    outputQueue.sync {
      self.consume(data, source: "mediamtx")
    }
  }

  private func noteFailure(component: String, detail: String) {
    guard desired, !stopping, !isHalted() else { return }
    if component == "mediamtx", let conflict = bindConflict() {
      halt(conflict)
      return
    }
    if component == "ffmpeg" {
      if ffmpegAttemptClosed { return }
      ffmpegAttemptClosed = true
    }
    failures += 1
    stableSince = nil
    stopPoller()
    logger.log(component, detail)
    let time = clock(Date())
    let health = HealthText.retrying(
      component: component,
      detail: detail,
      count: failures,
      limit: RestartBackoff.problemAfter,
      time: time,
      extra: component == "ffmpeg" ? ffmpegErrorLine() : nil
    )
    let status =
      RestartBackoff.showsProblem(failureCount: failures)
      ? HealthText.problem(component: component) : detail
    publish(.problem(status))
    publishHealth(health)
    let delay = RestartBackoff.delay(forFailureCount: failures)
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.desired, !self.stopping, !self.isHalted() else { return }
      if component == "ffmpeg", self.mediamtx?.isRunning == true {
        self.startFFmpeg()
      } else {
        self.launchPipeline()
      }
    }
    pendingRestart?.cancel()
    pendingRestart = work
    queue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func startPoller() {
    stopPoller()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler { [weak self] in
      self?.poll()
    }
    poller = timer
    timer.resume()
  }

  private func stopPoller() {
    poller?.cancel()
    poller = nil
  }

  private func poll() {
    guard desired, !stopping, !isHalted(), let settings = launch?.settings else { return }
    if let problem = capture.takeConversionProblem() {
      stopWithProblem(problem)
      return
    }
    if Date() >= nextLevelLog {
      nextLevelLog = Date().addingTimeInterval(4)
      let decibels = capture.recentDecibels()
      let peak = decibels <= -100 ? "silent" : String(format: "%.0f dB", decibels)
      logger.log("audio", "\(capture.openedFormatSummary); peak \(peak)")
    }
    guard let data = httpGet(MediaMTXAPI.pathGetPath(streamName: settings.streamName)),
      let snapshot = try? MediaMTXAPI.parsePath(data)
    else {
      publishHealth("\(clock(Date())) mediamtx API is not answering")
      return
    }
    DispatchQueue.main.async {
      self.onListeners?(snapshot.webrtcListeners)
    }
    if stall.observe(bytes: snapshot.bytesReceived, now: Date()) {
      publishHealth(HealthText.stalled(time: clock(Date())))
      logger.log("ffmpeg", "audio stalled (\(snapshot.bytesReceived) bytes)")
      noteFailure(component: "ffmpeg", detail: "audio stalled")
      return
    }
    if let stableSince,
      RestartBackoff.shouldResetCounter(stableFor: Date().timeIntervalSince(stableSince)),
      failures != 0
    {
      failures = 0
      publishHealth("\(clock(Date())) audio healthy")
    }
  }

  private func waitForAPI() -> Bool {
    waitUntil(timeout: 5) {
      self.httpGet(MediaMTXAPI.pathListPath) != nil
    }
  }

  private func waitUntilReady(stream: String) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if !desired || stopping || isHalted() { return false }
      if ffmpeg?.isRunning != true { return false }
      if pathIsReady(stream) { return true }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return ffmpeg?.isRunning == true && pathIsReady(stream)
  }

  private func pathIsReady(_ stream: String) -> Bool {
    guard let data = httpGet(MediaMTXAPI.pathGetPath(streamName: stream)),
      let snapshot = try? MediaMTXAPI.parsePath(data)
    else { return false }
    return snapshot.ready
  }

  private func waitUntil(timeout: TimeInterval, _ probe: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !desired || stopping || isHalted() { return false }
      if probe() { return true }
      Thread.sleep(forTimeInterval: 0.2)
    }
    if !desired || stopping || isHalted() { return false }
    return probe()
  }

  private func httpGet(_ path: String) -> Data? {
    guard let url = URL(string: "http://127.0.0.1:9997\(path)") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 1.2)
    request.httpMethod = "GET"
    let semaphore = DispatchSemaphore(value: 0)
    var payload: Data?
    URLSession.shared.dataTask(with: request) { data, response, _ in
      if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
        payload = data
      }
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 2)
    return payload
  }

  private func finish(reportStopped: Bool) {
    desired = false
    stopping = true
    pendingRestart?.cancel()
    stopPoller()
    stopChildren()
    let home = launch?.home ?? FileManager.default.homeDirectoryForCurrentUser
    if ffmpeg == nil && mediamtx == nil {
      try? FileManager.default.removeItem(at: AppPaths.pidFile(home: home))
    } else {
      writePIDs()
    }
    if reportStopped {
      publish(.stopped)
    }
  }

  private func stopCapture() {
    pendingFormat?.cancel()
    pendingFormat = nil
    formatWatch.stop()
    capture.stop()
    ffmpegInput = nil
  }

  /// A few tries while a headset finishes switching to call mode, then a
  /// plain error. This does not use the general restart loop.
  private func retrySettlingInput(_ problem: String) {
    guard desired, !stopping, !isHalted() else { return }
    inputSettleAttempts += 1
    let transport = launch?.deviceID.map { AudioDeviceList.transportDescription($0) } ?? "Unknown"
    logger.log("audio", "\(problem) Transport \(transport).")
    if inputSettleAttempts >= CaptureFormatPlan.inputSettleRetries {
      stopWithProblem(CaptureFormatPlan.inputGaveUpMessage(deviceName: launch?.deviceName ?? ""))
      return
    }
    publish(.problem(problem))
    publishHealth(problem)
    pendingFormat?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.desired, !self.stopping, !self.isHalted() else { return }
      if self.mediamtx?.isRunning == true {
        self.startFFmpeg()
      } else {
        self.launchPipeline()
      }
    }
    pendingFormat = work
    queue.asyncAfter(deadline: .now() + CaptureFormatPlan.formatSettleSeconds, execute: work)
  }

  private func scheduleFormatRebuild() {
    guard desired, !stopping, !isHalted() else { return }
    pendingFormat?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.reopenAfterFormatChange()
    }
    pendingFormat = work
    queue.asyncAfter(deadline: .now() + CaptureFormatPlan.formatSettleSeconds, execute: work)
  }

  /// Reopens after the device's own format, channel layout, or alive state
  /// changes. A moment with no channels is not final. The hardware rate is
  /// not changed.
  private func reopenAfterFormatChange() {
    guard desired, !stopping, !isHalted(), let deviceID = launch?.deviceID else { return }
    let transport = AudioDeviceList.transportDescription(deviceID)
    let bluetooth = AudioDeviceList.isBluetooth(deviceID) || bluetoothDeviceID == deviceID
    if bluetooth { bluetoothDeviceID = deviceID }
    formatBudget.limit = CaptureFormatPlan.rebuildLimit(bluetooth: bluetooth)
    let alive = AudioDeviceList.isAlive(deviceID)
    let native = alive ? AudioInputBind.nativeDescription(deviceID: deviceID) : nil
    let ready = alive && native?.canOpen == true
    if !ready {
      deviceWentQuiet = true
      guard formatBudget.allow(at: Date()) else {
        stopWithProblem(CaptureFormatPlan.inputGaveUpMessage(deviceName: launch?.deviceName ?? ""))
        return
      }
      logger.log(
        "audio",
        "input not ready yet; transport \(transport). Waiting for the device to settle."
      )
      scheduleFormatRebuild()
      return
    }
    let summary = native?.summary ?? ""
    if summary == lastFormatSummary && !deviceWentQuiet { return }
    deviceWentQuiet = false
    guard formatBudget.allow(at: Date()) else {
      stopWithProblem(
        "The audio device keeps changing format. Public EarFi left its sample rate unchanged. Pick the device again, or set its format in Audio MIDI Setup."
      )
      return
    }
    let previous = lastFormatSummary.isEmpty ? "unread" : lastFormatSummary
    logger.log(
      "audio",
      "input format changed from \(previous) to \(summary); transport \(transport). Reopening."
    )
    startFFmpeg()
  }

  private func stopChildren() {
    stopCapture()
    ffmpegLog?.readabilityHandler = nil
    mediamtxLog?.readabilityHandler = nil
    signalAndWait([ffmpeg, mediamtx].compactMap { $0 })
    if ffmpeg?.isRunning != true { ffmpeg = nil }
    if mediamtx?.isRunning != true { mediamtx = nil }
  }

  private func stopProcess(_ process: Process?) {
    guard let process else { return }
    signalAndWait([process])
  }

  /// SIGTERM the helper and its process group, then SIGKILL if it is still
  /// alive. The group is signaled only when the helper leads it.
  private func signalAndWait(_ processes: [Process]) {
    let live = processes.filter { $0.processIdentifier > 1 }
    for process in live {
      ignoredPIDs.insert(process.processIdentifier)
      let target = ChildStop.Target(
        pid: process.processIdentifier, group: getpgid(process.processIdentifier))
      kill(target.signalTarget, ChildStop.termSignal)
    }
    let deadline = Date().addingTimeInterval(ChildStop.grace)
    while Date() < deadline && live.contains(where: { $0.isRunning }) {
      Thread.sleep(forTimeInterval: 0.05)
    }
    for process in live where process.isRunning {
      let target = ChildStop.Target(
        pid: process.processIdentifier, group: getpgid(process.processIdentifier))
      kill(target.signalTarget, ChildStop.killSignal)
    }
    for process in live where process.isRunning {
      process.waitUntilExit()
    }
  }

  private func runInOwnGroup(_ process: Process) throws {
    try process.run()
    let pid = process.processIdentifier
    if pid > 1 {
      _ = setpgid(pid, pid)
    }
  }

  private func requestHalt() {
    haltLock.lock()
    halt = true
    haltLock.unlock()
  }

  private func clearHalt() {
    haltLock.lock()
    halt = false
    haltLock.unlock()
  }

  private func isHalted() -> Bool {
    haltLock.lock()
    defer { haltLock.unlock() }
    return halt
  }

  private func writePIDs() {
    guard let launch else { return }
    let recorded = SupervisedPIDs(
      mediamtx: mediamtx?.isRunning == true ? mediamtx?.processIdentifier : nil,
      ffmpeg: ffmpeg?.isRunning == true ? ffmpeg?.processIdentifier : nil,
      mediamtxGroup: recordedGroup(mediamtx),
      ffmpegGroup: recordedGroup(ffmpeg),
      mediamtxExecutable: launch.helpers.mediamtx.path,
      ffmpegExecutable: launch.helpers.ffmpeg.path
    )
    let url = AppPaths.pidFile(home: launch.home)
    if let data = try? JSONEncoder().encode(recorded) {
      try? data.write(to: url)
    }
  }

  private func recordedGroup(_ process: Process?) -> Int32? {
    guard let process, process.isRunning else { return nil }
    let pid = process.processIdentifier
    let group = getpgid(pid)
    return group == pid ? group : nil
  }

  private func reapRecorded() {
    let url = AppPaths.pidFile(home: FileManager.default.homeDirectoryForCurrentUser)
    guard let data = try? Data(contentsOf: url),
      let recorded = try? JSONDecoder().decode(SupervisedPIDs.self, from: data)
    else { return }
    let stopped = recorded.reapTargets.allSatisfy { target in
      reap(pid: target.pid, group: target.group, expected: target.executable)
    }
    if stopped {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func reap(pid: Int32, group: Int32, expected: String?) -> Bool {
    let path = ProcessPath.executablePath(pid: pid)
    guard ChildStop.shouldReap(pid: pid, actualPath: path, expectedPath: expected) else {
      return true
    }
    let target = ChildStop.Target(pid: pid, group: group)
    kill(target.signalTarget, ChildStop.termSignal)
    let deadline = Date().addingTimeInterval(ChildStop.grace)
    while Date() < deadline && processIsAlive(pid) {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if processIsAlive(pid) {
      kill(target.signalTarget, ChildStop.killSignal)
      let hard = Date().addingTimeInterval(1)
      while Date() < hard && processIsAlive(pid) {
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    let stopped = !processIsAlive(pid)
    if stopped {
      logger.log("supervisor", "cleared stale process \(pid)")
    }
    return stopped
  }

  private func publish(_ phase: BroadcastPhase) {
    DispatchQueue.main.async {
      self.onPhase?(phase)
    }
  }

  private func publishHealth(_ line: String) {
    DispatchQueue.main.async {
      self.onHealth?(line)
    }
  }

  private func publishLog(_ source: String, _ line: String) {
    let rendered = "[\(source)] \(line)"
    DispatchQueue.main.async {
      self.onLog?(rendered)
    }
  }

  private func publishStray(_ stray: StrayHelper?) {
    DispatchQueue.main.async {
      self.onStray?(stray)
    }
  }

  private func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}
