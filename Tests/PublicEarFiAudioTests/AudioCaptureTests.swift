import PublicEarFiCore
import XCTest

@testable import PublicEarFi

final class AudioCaptureTests: XCTestCase {
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
    Thread.sleep(forTimeInterval: 0.2)
    capture.setGainDB(-3)
    capture.stop()
    capture.stop()
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

  private static func floatBuffer(
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
}
