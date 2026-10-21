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
}
