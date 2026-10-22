import AVFoundation
import AudioToolbox
import Darwin
import PublicEarFiCore
import XCTest

@testable import PublicEarFi

final class AudioCaptureTests: XCTestCase {
  override func setUp() {
    super.setUp()
    // The capture writer blocks SIGPIPE on its own thread. A write from this
    // process on any other thread still uses the default action and kills
    // xctest with signal 13. Ignore it so write returns EPIPE.
    _ = signal(SIGPIPE, SIG_IGN)
  }

  /// The Start failure path used to call `terminationStatus` while ffmpeg was
  /// still running, which raises NSInvalidArgumentException. `/bin/sleep`
  /// stands in for that still-running ffmpeg.
  func testStartFFmpegDoesNotReadStatusWhileFFmpegIsRunning() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "earfi-exit-\(UUID().uuidString)", isDirectory: true)
    let controller = BroadcastController(logger: FileLogger(directory: directory))
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
      }
      process.waitUntilExit()
      try? FileManager.default.removeItem(at: directory)
    }
    XCTAssertTrue(process.isRunning)
    XCTAssertEqual(
      controller.startFFmpegExitDetail(process: process, launched: true),
      "the stream was not ready within 5 s"
    )
    XCTAssertTrue(process.isRunning)
    process.terminate()
    process.waitUntilExit()
    XCTAssertFalse(process.isRunning)
    let exited = controller.startFFmpegExitDetail(process: process, launched: true)
    XCTAssertTrue(exited.hasPrefix("exited with status "))
    XCTAssertEqual(
      controller.startFFmpegExitDetail(process: process, launched: false),
      "the stream was not ready within 5 s"
    )
  }

  func testMeterReadingIsSampledWithoutACallback() {
    let meter = LevelMeter()
    let initial = meter.latest()
    XCTAssertEqual(initial.decibels, -120, accuracy: 0.001)
    XCTAssertEqual(initial.fraction, 0, accuracy: 0.001)
    meter.stop()
    let still = meter.latest()
    XCTAssertEqual(still.decibels, -120, accuracy: 0.001)
    XCTAssertEqual(still.fraction, 0, accuracy: 0.001)
  }

  func testCaptureStartsAndStopsOnAStereoInput() throws {
    let inputs = AudioDeviceList.inputs()
    guard let device = inputs.first(where: { $0.inputChannels >= 2 }) ?? inputs.first else {
      throw XCTSkip("No audio input device is connected.")
    }
    let meter = LevelMeter()
    meter.setGainDB(0)
    meter.start(deviceID: device.deviceID)
    Thread.sleep(forTimeInterval: 0.2)
    let reading = meter.latest()
    XCTAssertGreaterThanOrEqual(reading.fraction, 0)
    XCTAssertLessThanOrEqual(reading.fraction, 1)
    meter.stop()
    meter.start(deviceID: device.deviceID)
    meter.stop()
    XCTAssertEqual(meter.latest().fraction, 0, accuracy: 0.001)

    let pipe = Pipe()
    let drain = pipe.fileHandleForReading
    drain.readabilityHandler = { handle in
      _ = handle.availableData
    }
    defer { drain.readabilityHandler = nil }
    let capture = CapturePipe()
    capture.setGainDB(6)
    let problem = capture.start(
      deviceID: device.deviceID,
      channelMode: .mono,
      inputChannel: 1,
      output: pipe.fileHandleForWriting
    )
    if let problem {
      capture.stop()
      throw XCTSkip("Capture did not start (\(problem)).")
    }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline && capture.bytesWritten() == 0 && capture.delivery().callbacks == 0 {
      Thread.sleep(forTimeInterval: 0.05)
    }
    let delivery = capture.delivery()
    let summary = capture.openedFormatSummary
    capture.setGainDB(-3)
    if delivery.callbacks > 0 {
      XCTAssertGreaterThan(
        delivery.bytesWritten, 0,
        "tap callbacks wrote no stdin bytes for \(device.name): \(summary); \(delivery.line)"
      )
      XCTAssertGreaterThan(delivery.framesOut, 0)
      XCTAssertTrue(summary.contains("native capture"), summary)
      XCTAssertFalse(summary.contains("widen"), summary)
      if device.inputChannels >= 2 {
        XCTAssertGreaterThanOrEqual(capture.openedNativeDescription.channelCount, 2, summary)
        XCTAssertFalse(summary.contains("1 channel"), summary)
      }
      capture.stop()
      let reopened = Pipe()
      let rereading = reopened.fileHandleForReading
      rereading.readabilityHandler = { handle in
        _ = handle.availableData
      }
      defer { rereading.readabilityHandler = nil }
      let second = capture.start(
        deviceID: device.deviceID,
        channelMode: .mono,
        inputChannel: 1,
        output: reopened.fileHandleForWriting,
        deviceName: device.name
      )
      XCTAssertNil(second, second ?? "")
      let again = Date().addingTimeInterval(2)
      while Date() < again && capture.delivery().callbacks == 0 {
        Thread.sleep(forTimeInterval: 0.05)
      }
      XCTAssertGreaterThan(capture.delivery().callbacks, 0, capture.openedFormatSummary)
      XCTAssertGreaterThan(capture.bytesWritten(), 0)
    } else if ProcessInfo.processInfo.environment["CI"] == "true" {
      capture.stop()
      throw XCTSkip(
        "Opened \(device.name) (\(summary)) on the real device path, but it delivered no callbacks in 2 s."
      )
    } else {
      XCTFail("No tap callbacks in 2 s for \(device.name). \(summary); \(delivery.line)")
    }
    XCTAssertFalse(summary.isEmpty)
    capture.stop()
    capture.stop()
  }

  /// A failed open used to leave the shared engine running, so the next device
  /// also produced no callbacks. A is torn down. B then gets callbacks.
  func testFailedStartIsTornDownBeforeTheNextDevice() throws {
    let ledger = SessionLedger()
    let specs: [(AudioDeviceID, Int, Bool)] = [(41, 2, true), (42, 1, false)]
    var index = 0
    var made: [ScriptedInputSession] = []
    let capture = CapturePipe {
      let spec = specs[index]
      index += 1
      let session = ScriptedInputSession(
        deviceID: spec.0,
        channels: spec.1,
        fails: spec.2,
        staleDefaultChannels: 1,
        ledger: ledger
      )
      made.append(session)
      return session
    }
    let blocked = Pipe()
    let problem = capture.start(
      deviceID: 41,
      channelMode: .mono,
      inputChannel: 1,
      output: blocked.fileHandleForWriting,
      deviceName: "BlackHole 2ch"
    )
    XCTAssertNotNil(problem)
    XCTAssertEqual(made.count, 1)
    XCTAssertFalse(made[0].isRunning)
    XCTAssertEqual(ledger.disposed, 1)
    XCTAssertEqual(capture.delivery().callbacks, 0)
    XCTAssertFalse(capture.captureIsRunning)

    let next = Pipe()
    let reading = next.fileHandleForReading
    reading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    defer { reading.readabilityHandler = nil }
    let opened = capture.start(
      deviceID: 42,
      channelMode: .mono,
      inputChannel: 1,
      output: next.fileHandleForWriting,
      deviceName: "MacBook Microphone"
    )
    XCTAssertNil(opened)
    try waitForStdin(capture)
    XCTAssertEqual(made.count, 2)
    XCTAssertTrue(made[1].isRunning)
    XCTAssertEqual(ledger.created, 2)
    XCTAssertEqual(ledger.disposed, 1)
    XCTAssertEqual(ledger.openedChannels, [1])
    capture.stop()
    XCTAssertEqual(ledger.disposed, 2)
    XCTAssertFalse(made[1].isRunning)
    XCTAssertFalse(capture.captureIsRunning)
  }

  /// AirPods can vanish while macOS changes profile. Stopping that proc must
  /// return, and the next device must still deliver callbacks.
  func testSwitchingAwayFromARemovedDeviceStillStartsTheNextOne() throws {
    let watch = AudioFormatWatch()
    watch.start(deviceID: AudioDeviceID(0x7FFF_0001), queue: .main) {}
    watch.stop()
    watch.stop()
    HALDeviceInputSession().stop()

    let ledger = SessionLedger()
    let specs: [(AudioDeviceID, Int, Bool)] = [(81, 1, false), (82, 1, false)]
    var index = 0
    var made: [ScriptedInputSession] = []
    let capture = CapturePipe {
      let spec = specs[index]
      index += 1
      let session = ScriptedInputSession(
        deviceID: spec.0,
        channels: spec.1,
        fails: spec.2,
        staleDefaultChannels: 1,
        ledger: ledger
      )
      made.append(session)
      return session
    }
    let airpods = Pipe()
    let airpodsReading = airpods.fileHandleForReading
    airpodsReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    defer { airpodsReading.readabilityHandler = nil }
    XCTAssertNil(
      capture.start(
        deviceID: 81,
        channelMode: .mono,
        inputChannel: 1,
        output: airpods.fileHandleForWriting,
        deviceName: "AirPods"
      )
    )
    try waitForStdin(capture)
    XCTAssertEqual(made.count, 1)
    made[0].markRemoved()

    let mic = Pipe()
    let micReading = mic.fileHandleForReading
    micReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    defer { micReading.readabilityHandler = nil }
    XCTAssertNil(
      capture.start(
        deviceID: 82,
        channelMode: .mono,
        inputChannel: 1,
        output: mic.fileHandleForWriting,
        deviceName: "MacBook Microphone"
      )
    )
    try waitForStdin(capture)
    XCTAssertEqual(ledger.disposed, 1)
    XCTAssertTrue(made[0].wasRemovedWhenStopped)
    XCTAssertEqual(made.count, 2)
    XCTAssertTrue(made[1].isRunning)
    XCTAssertGreaterThan(capture.delivery().callbacks, 0)
    capture.stop()
    XCTAssertEqual(ledger.disposed, 2)
  }

  /// The system default mic is 1 channel. The chosen device is 2. The open
  /// uses the chosen device, and the log does not say the client format was widened.
  func testTwoChannelDeviceOpensWhileTheDefaultMicIsOneChannel() throws {
    let ledger = SessionLedger()
    let capture = CapturePipe {
      ScriptedInputSession(
        deviceID: 7,
        channels: 2,
        fails: false,
        staleDefaultChannels: 1,
        ledger: ledger
      )
    }
    let pipe = Pipe()
    let reading = pipe.fileHandleForReading
    reading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    defer { reading.readabilityHandler = nil }
    let problem = capture.start(
      deviceID: 7,
      channelMode: .mono,
      inputChannel: 1,
      output: pipe.fileHandleForWriting,
      deviceName: "USB PnP Audio Device"
    )
    XCTAssertNil(problem)
    try waitForStdin(capture)
    XCTAssertEqual(ledger.openedChannels, [2])
    let summary = capture.openedFormatSummary
    XCTAssertTrue(summary.contains("native capture, 2 channels"), summary)
    XCTAssertTrue(summary.contains("2 channels, interleaved"), summary)
    XCTAssertFalse(summary.contains("widen"), summary)
    XCTAssertFalse(summary.contains("1 channel"), summary)
    capture.stop()
    XCTAssertEqual(ledger.disposed, 1)
  }

  func testInterleavedStereoBufferStaysTwoChannels() {
    let frames = 16
    let channels = 2
    var samples = [Float](repeating: 0.5, count: frames * channels)
    samples.withUnsafeMutableBufferPointer { pointer in
      let audio = AudioBuffer(
        mNumberChannels: UInt32(channels),
        mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(pointer.baseAddress)
      )
      var list = AudioBufferList(mNumberBuffers: 1, mBuffers: audio)
      let nominal = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
      )
      let pcm = withUnsafePointer(to: &list) {
        DeviceBufferAdapter.pcmBuffer(list: $0, nominal: nominal)
      }
      XCTAssertEqual(pcm?.format.channelCount, 2)
      XCTAssertEqual(Int(pcm?.frameLength ?? 0), frames)
      let floats = pcm.flatMap { CapturePCM.interleavedFloats(from: $0) }
      XCTAssertEqual(floats?.count, frames * channels)
    }
  }

  /// 48 kHz stereo is the BlackHole / USB path (no rate converter). 24 kHz
  /// mono is the Bluetooth hands-free path. Both have to put bytes on the
  /// pipe ffmpeg reads as stdin.
  func testStereo48kAndMono24kReachFFmpegStdin() throws {
    try assertPipeReceives(
      sampleRate: 48_000, channels: 2, frames: 960, interleaved: true, pushes: 2)
    try assertPipeReceives(
      sampleRate: 48_000, channels: 2, frames: 960, interleaved: false, pushes: 2)
    try assertPipeReceives(
      sampleRate: 24_000, channels: 1, frames: 480, interleaved: true, pushes: 8)
  }

  private func waitForStdin(_ capture: CapturePipe) throws {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline && capture.bytesWritten() == 0 {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertGreaterThan(capture.delivery().callbacks, 0, capture.delivery().line)
    XCTAssertGreaterThan(capture.bytesWritten(), 0, capture.delivery().line)
  }

  private func assertPipeReceives(
    sampleRate: Double,
    channels: Int,
    frames: AVAudioFrameCount,
    interleaved: Bool,
    pushes: Int
  ) throws {
    let pipe = Pipe()
    let capture = CapturePipe()
    let reading = pipe.fileHandleForReading
    let received = NSLock()
    var data = Data()
    let arrived = DispatchSemaphore(value: 0)
    reading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      received.lock()
      data.append(chunk)
      received.unlock()
      arrived.signal()
    }
    capture.startPipe(
      output: pipe.fileHandleForWriting,
      channelMode: .mono,
      inputChannel: 1,
      deliveringChannels: channels
    )
    defer { capture.stop() }
    for index in 0..<pushes {
      let buffer = try XCTUnwrap(
        Self.floatBuffer(
          sampleRate: sampleRate,
          channels: channels,
          frames: frames,
          interleaved: interleaved,
          amplitude: 0.25 + Float(index) * 0.01
        )
      )
      capture.push(buffer)
    }
    let wait = arrived.wait(timeout: .now() + 2)
    received.lock()
    let bytes = data.count
    received.unlock()
    XCTAssertEqual(wait, .success, "no stdin bytes at \(sampleRate) Hz, \(channels) ch")
    XCTAssertGreaterThan(bytes, 0)
    XCTAssertGreaterThan(capture.bytesWritten(), 0)
  }

  fileprivate static func floatBuffer(
    sampleRate: Double,
    channels: Int,
    frames: AVAudioFrameCount,
    interleaved: Bool,
    amplitude: Float
  ) -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels),
        interleaved: interleaved
      ),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
    else { return nil }
    buffer.frameLength = frames
    if interleaved || buffer.floatChannelData == nil {
      guard let raw = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }
      let samples = raw.bindMemory(to: Float.self, capacity: Int(frames) * channels)
      for index in 0..<(Int(frames) * channels) {
        samples[index] = amplitude
      }
      return buffer
    }
    guard let channelsData = buffer.floatChannelData else { return nil }
    for channel in 0..<channels {
      for frame in 0..<Int(frames) {
        channelsData[channel][frame] = amplitude
      }
    }
    return buffer
  }

  func testHeroMotionMatchesTheWebsiteTiming() {
    XCTAssertEqual(HeroMotion.unit(time: 0, duration: 2.4, delay: 0), 0, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.unit(time: 2.4, duration: 2.4, delay: 0), 0, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.unit(time: 1.2, duration: 2.4, delay: 0), 0.5, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.unit(time: 0.8, duration: 2.4, delay: 0.8), 0, accuracy: 0.0001)
    XCTAssertEqual(
      HeroMotion.unit(time: 1.6, duration: 2.4, delay: 0.8), 1.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.unit(time: 0, duration: 3, delay: 1), 2.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.waveScale(progress: 0), 1, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.waveScale(progress: 1), 2.2, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.ringScale(progress: 0), 0.5, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.ringScale(progress: 1), 6, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.ringOpacity(progress: 0), 0.7, accuracy: 0.0001)
    XCTAssertEqual(HeroMotion.ringOpacity(progress: 1), 0, accuracy: 0.0001)
    XCTAssertGreaterThan(HeroMotion.fade(progress: 0), HeroMotion.fade(progress: 0.5))
    XCTAssertGreaterThan(HeroMotion.presence(live: true), HeroMotion.presence(live: false))
    let loud = HeroMotion.barScale(time: 0.4, index: 2, live: true, level: 1)
    let quiet = HeroMotion.barScale(time: 0.4, index: 2, live: true, level: 0)
    let stopped = HeroMotion.barScale(time: 0.4, index: 2, live: false, level: 1)
    XCTAssertGreaterThan(loud, quiet)
    XCTAssertGreaterThan(quiet, stopped)
    XCTAssertEqual(HeroMotion.arcCount, 3)
    XCTAssertEqual(HeroMotion.ringCount, 3)
  }
}

final class SessionLedger {
  var created = 0
  var disposed = 0
  var openedChannels: [Int] = []
}

/// A stand-in for one HAL open. `staleDefaultChannels` is the system default
/// mic. The session reports `channels` from the chosen device instead.
final class ScriptedInputSession: DeviceInputSession {
  let deviceID: AudioDeviceID
  let channels: Int
  let fails: Bool
  let staleDefaultChannels: Int
  let ledger: SessionLedger
  private var running = false
  private var stopped = false
  private var removed = false
  private(set) var wasRemovedWhenStopped = false

  var isRunning: Bool { running }

  func markRemoved() {
    removed = true
  }

  init(
    deviceID: AudioDeviceID,
    channels: Int,
    fails: Bool,
    staleDefaultChannels: Int,
    ledger: SessionLedger
  ) {
    self.deviceID = deviceID
    self.channels = channels
    self.fails = fails
    self.staleDefaultChannels = staleDefaultChannels
    self.ledger = ledger
    ledger.created += 1
  }

  func start(
    deviceID: AudioDeviceID,
    onBuffer: @escaping (AVAudioPCMBuffer) -> Void
  ) -> DeviceInputOpen {
    guard deviceID == self.deviceID else {
      return .failed("Could not open the selected audio device.")
    }
    if fails {
      running = true
      return .failed("Could not open the selected audio device.")
    }
    let described = CaptureStreamDescription(
      sampleRate: 48_000,
      channelCount: channels,
      bitsPerChannel: 32,
      isFloat: true,
      isInterleaved: true
    )
    guard
      let bound = CaptureDeviceBinding.bound(
        device: described, staleChannels: staleDefaultChannels)
    else {
      return .failed(CaptureFormatPlan.notReadyMessage(deviceName: ""))
    }
    running = true
    ledger.openedChannels.append(bound.channelCount)
    if let buffer = AudioCaptureTests.floatBuffer(
      sampleRate: 48_000,
      channels: bound.channelCount,
      frames: 960,
      interleaved: true,
      amplitude: 0.2
    ) {
      onBuffer(buffer)
    }
    return .ready(bound)
  }

  func stop() {
    if stopped { return }
    stopped = true
    wasRemovedWhenStopped = removed
    running = false
    ledger.disposed += 1
  }
}
