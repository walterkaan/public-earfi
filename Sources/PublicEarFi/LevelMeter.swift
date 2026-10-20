import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import PublicEarFiCore

final class LevelMeter {
  private let engine = AVAudioEngine()
  private var running = false
  private let gainLock = NSLock()
  private var gainDB = InputGain.defaultDB
  var onLevel: ((Double, Double) -> Void)?

  func setGainDB(_ db: Double) {
    gainLock.lock()
    gainDB = InputGain.clamped(db)
    gainLock.unlock()
  }

  func start(deviceID: AudioDeviceID?) {
    stop()
    if let deviceID {
      guard AudioDeviceList.isAlive(deviceID) else { return }
    } else if AudioDeviceList.inputs().isEmpty {
      return
    }
    let input = engine.inputNode
    if let deviceID, let audioUnit = input.audioUnit {
      var identifier = deviceID
      AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &identifier,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      )
    }
    let hardware = input.outputFormat(forBus: 0)
    guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return }
    input.installTap(onBus: 0, bufferSize: 1_024, format: hardware) { [weak self] buffer, _ in
      self?.measure(buffer)
    }
    do {
      engine.prepare()
      try engine.start()
      running = true
    } catch {
      input.removeTap(onBus: 0)
      running = false
    }
  }

  func stop() {
    guard running else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    running = false
  }

  private func measure(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frames > 0, channelCount > 0 else { return }
    var interleaved = [Float](repeating: 0, count: frames * channelCount)
    for channel in 0..<channelCount {
      for frame in 0..<frames {
        interleaved[frame * channelCount + channel] = channels[channel][frame]
      }
    }
    let gain = currentGain()
    let rendered = InputGain.render(
      interleaved: interleaved,
      channelCount: channelCount,
      downmixToMono: true,
      gainDB: gain
    )
    let decibels = SignalLevel.decibels(rendered)
    let fraction = min(1, max(0, (decibels + 60) / 60))
    onLevel?(decibels, fraction)
  }

  private func currentGain() -> Double {
    gainLock.lock()
    defer { gainLock.unlock() }
    return gainDB
  }
}
