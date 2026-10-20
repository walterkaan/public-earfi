import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import PublicEarFiCore
import os

/// Input level for the main window. The audio callback only stores a
/// reading. The main thread polls `latest()`; the callback never hops to
/// the main actor.
final class LevelMeter {
  struct Reading {
    var decibels: Double
    var fraction: Double
  }

  private let engine = AVAudioEngine()
  private let reading = OSAllocatedUnfairLock(
    initialState: Reading(decibels: -120, fraction: 0))
  private let callbackLock = NSLock()
  private let gainLock = NSLock()
  private var gainDB = InputGain.defaultDB
  private var accepting = false
  private var inFlight = 0
  private var running = false
  private var tapInstalled = false

  func setGainDB(_ db: Double) {
    gainLock.lock()
    gainDB = InputGain.clamped(db)
    gainLock.unlock()
  }

  func latest() -> Reading {
    reading.withLock { $0 }
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
    tapInstalled = true
    do {
      engine.prepare()
      try engine.start()
      callbackLock.lock()
      accepting = true
      running = true
      callbackLock.unlock()
    } catch {
      stop()
    }
  }

  func stop() {
    callbackLock.lock()
    accepting = false
    let hadTap = tapInstalled
    let wasRunning = running
    tapInstalled = false
    running = false
    callbackLock.unlock()
    waitUntilIdle()
    if hadTap {
      engine.inputNode.removeTap(onBus: 0)
    }
    if wasRunning {
      engine.stop()
    }
    reading.withLock { state in
      state.decibels = -120
      state.fraction = 0
    }
  }

  private func measure(_ buffer: AVAudioPCMBuffer) {
    guard beginCallback() else { return }
    defer { endCallback() }
    guard let interleaved = CapturePCM.interleavedFloats(from: buffer) else { return }
    let channelCount = max(1, Int(buffer.format.channelCount))
    let rendered = InputGain.render(
      interleaved: interleaved,
      channelCount: channelCount,
      downmixToMono: true,
      gainDB: currentGain()
    )
    let decibels = SignalLevel.decibels(rendered)
    let fraction = min(1, max(0, (decibels + 60) / 60))
    reading.withLock { state in
      state.decibels = decibels
      state.fraction = fraction
    }
  }

  private func currentGain() -> Double {
    gainLock.lock()
    defer { gainLock.unlock() }
    return gainDB
  }

  private func beginCallback() -> Bool {
    callbackLock.lock()
    defer { callbackLock.unlock() }
    guard accepting else { return false }
    inFlight += 1
    return true
  }

  private func endCallback() {
    callbackLock.lock()
    inFlight -= 1
    callbackLock.unlock()
  }

  /// Returns once every callback that passed `beginCallback` has finished.
  /// The lock is not held, so the audio thread can leave.
  private func waitUntilIdle() {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      callbackLock.lock()
      let busy = inFlight
      callbackLock.unlock()
      if busy == 0 { return }
      Thread.sleep(forTimeInterval: 0.001)
    }
  }
}
