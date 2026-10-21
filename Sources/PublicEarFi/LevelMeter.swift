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
  private var watchedDevice: AudioDeviceID = 0
  private var settleAttempts = 0
  private var sawBluetooth = false
  private var lastNativeSummary = ""
  private var pendingOpen: DispatchWorkItem?
  private let formatWatch = AudioFormatWatch()

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
    guard let deviceID else { return }
    watchedDevice = deviceID
    settleAttempts = 0
    sawBluetooth = AudioDeviceList.isBluetooth(deviceID)
    open(deviceID)
  }

  func stop() {
    pendingOpen?.cancel()
    pendingOpen = nil
    watchedDevice = 0
    settleAttempts = 0
    sawBluetooth = false
    lastNativeSummary = ""
    formatWatch.stop()
    stopEngine()
    reading.withLock { state in
      state.decibels = -120
      state.fraction = 0
    }
  }

  /// Opens the meter. A Bluetooth headset can report no channels until macOS
  /// finishes switching it to call mode, so that failure is tried again.
  private func open(_ deviceID: AudioDeviceID) {
    stopEngine()
    guard watchedDevice == deviceID else { return }
    if AudioDeviceList.isBluetooth(deviceID) { sawBluetooth = true }
    guard AudioDeviceList.isAlive(deviceID) else {
      if sawBluetooth { scheduleSettle(deviceID) }
      return
    }
    let prepared: AudioInputBind.Prepared
    switch AudioInputBind.prepare(engine: engine, deviceID: deviceID) {
    case .ready(let value):
      prepared = value
    case .failed(let message):
      if CaptureFormatPlan.isInputSettling(message) { scheduleSettle(deviceID) }
      return
    }
    switch AudioInputBind.startEngine(
      engine: engine,
      prepared: prepared,
      deviceID: deviceID,
      bufferSize: 1_024,
      onBuffer: { [weak self] buffer in
        self?.measure(buffer)
      }
    ) {
    case .failed(let message):
      stopEngine()
      if CaptureFormatPlan.isInputSettling(message) { scheduleSettle(deviceID) }
      return
    case .ready:
      break
    }
    lastNativeSummary = prepared.native.summary
    settleAttempts = 0
    callbackLock.lock()
    accepting = true
    running = true
    tapInstalled = true
    callbackLock.unlock()
    formatWatch.start(deviceID: deviceID, queue: .main) { [weak self] in
      self?.noteDeviceChange(deviceID)
    }
  }

  private func noteDeviceChange(_ deviceID: AudioDeviceID) {
    guard watchedDevice == deviceID else { return }
    let native = AudioInputBind.nativeDescription(deviceID: deviceID)
    let ready = AudioDeviceList.isAlive(deviceID) && native?.canOpen == true
    if ready, native?.summary == lastNativeSummary { return }
    scheduleSettle(deviceID)
  }

  private func scheduleSettle(_ deviceID: AudioDeviceID) {
    guard watchedDevice == deviceID else { return }
    pendingOpen?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.watchedDevice == deviceID else { return }
      self.settleAttempts += 1
      guard self.settleAttempts <= CaptureFormatPlan.inputSettleRetries else { return }
      self.open(deviceID)
    }
    pendingOpen = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + CaptureFormatPlan.formatSettleSeconds, execute: work)
  }

  private func stopEngine() {
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
