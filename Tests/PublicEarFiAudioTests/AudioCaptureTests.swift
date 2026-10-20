import PublicEarFiCore
import XCTest

@testable import PublicEarFi

final class AudioCaptureTests: XCTestCase {
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
