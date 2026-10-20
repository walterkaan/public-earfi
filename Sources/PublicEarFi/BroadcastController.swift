import CoreAudio
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
  private let logLock = NSLock()
  private var lastFFmpegError: String?
  private var ffmpegPartial = ""
  private var ffmpegLog: FileHandle?
  private var ffmpegAttemptClosed = false
  private let capture = CapturePipe()
  private var ffmpegInput: Pipe?
  private var helperPaths: [String] = []
  private var mediamtxLog: FileHandle?
  private var mediamtxLogTail = ""

  init(logger: FileLogger) {
    self.logger = logger
  }

  func start(_ launch: BroadcastLaunch) {
    queue.async {
      self.pendingRestart?.cancel()
      self.launch = launch
      self.helperPaths = [launch.helpers.mediamtx.path, launch.helpers.ffmpeg.path]
      self.desired = true
      self.stopping = false
      self.failures = 0
      self.frameDrops = 0
      self.stall.reset()
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
    queue.async {
      self.finish(reportStopped: true)
    }
  }

  func stopAndWait() {
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
      guard self.desired, !self.stopping else { return }
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

  func reapStaleChildren() {
    queue.sync {
      let url = AppPaths.pidFile(home: FileManager.default.homeDirectoryForCurrentUser)
      guard let data = try? Data(contentsOf: url),
        let recorded = try? JSONDecoder().decode(SupervisedPIDs.self, from: data)
      else { return }
      reap(recorded.mediamtx, expected: recorded.mediamtxExecutable)
      reap(recorded.ffmpeg, expected: recorded.ffmpegExecutable)
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func launchPipeline() {
    guard desired, !stopping, let launch else { return }
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
    guard AudioDeviceList.isAlive(deviceID) else {
      stopWithProblem("The selected audio device is not connected.")
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
      try process.run()
    } catch {
      noteFailure(component: "ffmpeg", detail: "ffmpeg failed to launch")
      return
    }
    if let problem = capture.start(
      deviceID: deviceID,
      channelMode: launch.settings.channelMode,
      inputChannel: launch.settings.inputChannel,
      output: pipe.fileHandleForWriting
    ) {
      stopCapture()
      abandon(process)
      if problem == "The selected audio device is not connected."
        || problem == "Could not map the selected input channel."
        || problem == "Could not open the selected audio device."
      {
        stopWithProblem(problem)
      } else {
        noteFailure(component: "audio", detail: problem)
      }
      return
    }
    ffmpeg = process
    writePIDs()
    logger.log(
      "ffmpeg",
      "started pid \(process.processIdentifier), Core Audio \(name) at 48 kHz"
    )
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
      try process.run()
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
    if source == "ffmpeg" {
      ffmpegLog = pipe.fileHandleForReading
    }
    if source == "mediamtx" {
      mediamtxLog = pipe.fileHandleForReading
      resetMediaMTXLog()
    }
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      if source == "ffmpeg" {
        self?.noteFFmpegOutput(text)
      }
      if source == "mediamtx" {
        self?.rememberMediaMTX(text)
      }
      self?.queue.async {
        self?.ingest(text, source: source)
      }
    }
    process.terminationHandler = { [weak self] process in
      self?.queue.async {
        self?.handleExit(process, source: source)
      }
    }
  }

  private func ingest(_ text: String, source: String) {
    for raw in text.split(separator: "\n") {
      let line = String(raw)
      logger.log(source, line)
      publishLog(source, line)
      if source == "ffmpeg" && StreamLog.isFrameDrop(line) {
        frameDrops += 1
        publishHealth("\(clock(Date())) frame drops: \(frameDrops)")
      }
    }
  }

  private func resetFFmpegErrors() {
    logLock.lock()
    lastFFmpegError = nil
    ffmpegPartial = ""
    logLock.unlock()
  }

  /// Records ffmpeg failures as bytes arrive, including while the supervisor
  /// queue is blocked inside the 5 s ready wait.
  private func noteFFmpegOutput(_ text: String) {
    logLock.lock()
    defer { logLock.unlock() }
    ffmpegPartial += text
    while let newline = ffmpegPartial.firstIndex(of: "\n") {
      let line = String(ffmpegPartial[..<newline])
      ffmpegPartial.removeSubrange(...ffmpegPartial.index(after: newline))
      rememberFailure(line)
    }
  }

  private func rememberFailure(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if StreamLog.isFailure(trimmed) {
      lastFFmpegError = trimmed
    }
  }

  private func ffmpegErrorLine() -> String? {
    logLock.lock()
    defer { logLock.unlock() }
    rememberFailure(ffmpegPartial)
    return lastFFmpegError
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
    guard desired, !stopping else { return }
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
    let data = handle.availableData
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
    noteFFmpegOutput(text)
    ingest(text, source: "ffmpeg")
  }

  private func abandon(_ process: Process?) {
    guard let process else { return }
    ignoredPIDs.insert(process.processIdentifier)
    guard process.isRunning else { return }
    process.interrupt()
    let grace = Date().addingTimeInterval(3)
    while process.isRunning && Date() < grace {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
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
    kill(helper.pid, SIGTERM)
    let grace = Date().addingTimeInterval(2)
    while processIsAlive(helper.pid) && Date() < grace {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if processIsAlive(helper.pid) {
      kill(helper.pid, SIGKILL)
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

  private func rememberMediaMTX(_ text: String) {
    logLock.lock()
    mediamtxLogTail += text
    if mediamtxLogTail.count > 4_000 {
      mediamtxLogTail.removeFirst(mediamtxLogTail.count - 4_000)
    }
    logLock.unlock()
  }

  private func resetMediaMTXLog() {
    logLock.lock()
    mediamtxLogTail = ""
    logLock.unlock()
  }

  private func mediamtxExcerpt() -> String {
    logLock.lock()
    defer { logLock.unlock() }
    return mediamtxLogTail
  }

  private func drainMediaMTXLog() {
    guard let handle = mediamtxLog else { return }
    let data = handle.availableData
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
    rememberMediaMTX(text)
    ingest(text, source: "mediamtx")
  }

  private func noteFailure(component: String, detail: String) {
    guard desired, !stopping else { return }
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
      guard let self, self.desired, !self.stopping else { return }
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
    guard desired, !stopping, let settings = launch?.settings else { return }
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
      if !desired || stopping { return false }
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
      if !desired || stopping { return false }
      if probe() { return true }
      Thread.sleep(forTimeInterval: 0.2)
    }
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
    try? FileManager.default.removeItem(
      at: AppPaths.pidFile(home: launch?.home ?? FileManager.default.homeDirectoryForCurrentUser))
    if reportStopped {
      publish(.stopped)
    }
  }

  private func stopCapture() {
    capture.stop()
    ffmpegInput = nil
  }

  private func stopChildren() {
    stopCapture()
    stopProcess(ffmpeg)
    ffmpeg = nil
    stopProcess(mediamtx)
    mediamtx = nil
  }

  private func stopProcess(_ process: Process?) {
    guard let process, process.isRunning else { return }
    ignoredPIDs.insert(process.processIdentifier)
    process.interrupt()
    let grace = Date().addingTimeInterval(3)
    while process.isRunning && Date() < grace {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
  }

  private func writePIDs() {
    guard let launch else { return }
    let recorded = SupervisedPIDs(
      mediamtx: mediamtx?.isRunning == true ? mediamtx?.processIdentifier : nil,
      ffmpeg: ffmpeg?.isRunning == true ? ffmpeg?.processIdentifier : nil,
      mediamtxExecutable: launch.helpers.mediamtx.path,
      ffmpegExecutable: launch.helpers.ffmpeg.path
    )
    let url = AppPaths.pidFile(home: launch.home)
    if let data = try? JSONEncoder().encode(recorded) {
      try? data.write(to: url)
    }
  }

  private func reap(_ pid: Int32?, expected: String?) {
    guard let pid, pid > 0 else { return }
    let path = ProcessPath.executablePath(pid: pid)
    if let expected, let path, path != expected { return }
    if path == nil { return }
    kill(pid, SIGKILL)
    logger.log("supervisor", "cleared stale process \(pid)")
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
