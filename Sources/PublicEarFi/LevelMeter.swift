import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

final class LevelMeter {
  private let engine = AVAudioEngine()
  private var running = false
  var onLevel: ((Double, Double) -> Void)?

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
    guard let samples = buffer.floatChannelData?[0] else { return }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }
    var sum: Float = 0
    for index in 0..<frames {
      let sample = samples[index]
      sum += sample * sample
    }
    let rms = sqrt(sum / Float(frames))
    let decibels = Double(20 * log10(max(rms, 1e-7)))
    let fraction = min(1, max(0, (decibels + 60) / 60))
    onLevel?(decibels, fraction)
  }
}
