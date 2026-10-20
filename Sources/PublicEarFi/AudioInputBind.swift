import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import PublicEarFiCore

/// Binds one HAL device to an AVAudioEngine input before the unit is initialized.
/// Setting `kAudioOutputUnitProperty_CurrentDevice` on an already initialized
/// unit leaves the previous device in place, so the selected USB input stays silent.
enum AudioInputBind {
  struct Prepared {
    var audioUnit: AudioUnit
    var format: AVAudioFormat
    var native: CaptureStreamDescription
    var engine: CaptureStreamDescription
    /// HAL input channels. The tap should deliver all of them.
    var deviceChannels: Int
  }

  enum StartOutcome {
    case ready(AVAudioFormat)
    case failed(String)
  }

  enum Outcome {
    case ready(Prepared)
    case failed(String)
  }

  static func prepare(engine: AVAudioEngine, deviceID: AudioDeviceID) -> Outcome {
    let input = engine.inputNode
    guard let audioUnit = input.audioUnit else {
      return .failed("The audio engine has no input.")
    }
    guard bind(audioUnit, deviceID: deviceID) else {
      return .failed("Could not open the selected audio device.")
    }
    let nativeStreamDescription = nativeStream(deviceID: deviceID)
    let wanted = deviceChannelCount(
      deviceID: deviceID, audioUnit: audioUnit, native: nativeStreamDescription)
    let rate = clientSampleRate(
      audioUnit: audioUnit, native: nativeStreamDescription, input: input)
    if wanted > 0, rate > 0 {
      _ = applyClientFormat(
        audioUnit: audioUnit, deviceID: deviceID, sampleRate: rate, channels: wanted)
    }
    let format = input.outputFormat(forBus: 0)
    guard currentDevice(audioUnit) == deviceID else {
      return .failed("The selected audio device did not open. Pick it again in Settings.")
    }
    let engineDescription = describe(format)
    let native = nativeStreamDescription ?? engineDescription
    guard format.sampleRate > 0, format.channelCount > 0 else {
      return .failed(CaptureFormatPlan.impossibleMessage(deviceName: "", stream: native))
    }
    return .ready(
      Prepared(
        audioUnit: audioUnit,
        format: format,
        native: native,
        engine: engineDescription,
        deviceChannels: max(wanted, Int(format.channelCount))
      )
    )
  }

  /// Installs a tap on the input and starts the engine. The client format is
  /// widened to every HAL input channel before the tap, and checked again
  /// after start. A format that is still short is tapped as it is: the mix
  /// then sums the channels that actually arrived.
  static func startEngine(
    engine: AVAudioEngine,
    prepared: Prepared,
    deviceID: AudioDeviceID,
    bufferSize: AVAudioFrameCount,
    onBuffer: @escaping (AVAudioPCMBuffer) -> Void
  ) -> StartOutcome {
    let input = engine.inputNode
    let initial = tapFormat(input, preferredChannels: prepared.deviceChannels)
    input.installTap(onBus: 0, bufferSize: bufferSize, format: initial) { buffer, _ in
      onBuffer(buffer)
    }
    do {
      engine.prepare()
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      if engine.isRunning { engine.stop() }
      return .failed(startFailure(error))
    }
    if let problem = confirm(prepared, deviceID: deviceID) {
      input.removeTap(onBus: 0)
      engine.stop()
      return .failed(problem)
    }
    let live = input.outputFormat(forBus: 0)
    let narrowed =
      Int(live.channelCount) < prepared.deviceChannels
      || Int(live.channelCount) != Int(initial.channelCount)
    if !narrowed {
      if !engine.isRunning {
        do { try engine.start() } catch {
          input.removeTap(onBus: 0)
          return .failed(startFailure(error))
        }
      }
      return .ready(live.channelCount > 0 ? live : initial)
    }
    input.removeTap(onBus: 0)
    engine.stop()
    let rate = live.sampleRate > 0 ? live.sampleRate : prepared.format.sampleRate
    _ = applyClientFormat(
      audioUnit: prepared.audioUnit,
      deviceID: deviceID,
      sampleRate: rate,
      channels: prepared.deviceChannels
    )
    let widened = tapFormat(input, preferredChannels: prepared.deviceChannels)
    guard widened.sampleRate > 0, widened.channelCount > 0 else {
      return .failed(
        CaptureFormatPlan.impossibleMessage(deviceName: "", stream: prepared.native))
    }
    input.installTap(onBus: 0, bufferSize: bufferSize, format: widened) { buffer, _ in
      onBuffer(buffer)
    }
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      if engine.isRunning { engine.stop() }
      return .failed(startFailure(error))
    }
    if let problem = confirm(prepared, deviceID: deviceID) {
      input.removeTap(onBus: 0)
      engine.stop()
      return .failed(problem)
    }
    if !engine.isRunning {
      do { try engine.start() } catch {
        input.removeTap(onBus: 0)
        return .failed(startFailure(error))
      }
    }
    let delivering = input.outputFormat(forBus: 0)
    return .ready(delivering.channelCount > 0 ? delivering : widened)
  }

  /// Called after `engine.start()`. A start can initialize the unit again and
  /// drop the device that was set above.
  static func confirm(_ prepared: Prepared, deviceID: AudioDeviceID) -> String? {
    if currentDevice(prepared.audioUnit) == deviceID { return nil }
    guard bind(prepared.audioUnit, deviceID: deviceID),
      currentDevice(prepared.audioUnit) == deviceID
    else {
      return "The selected audio device did not open. Pick it again in Settings."
    }
    return nil
  }

  static func summary(native: CaptureStreamDescription, engine: CaptureStreamDescription) -> String
  {
    "native \(native.summary); engine \(engine.summary)"
  }

  static func floatFormat(sampleRate: Double, channels: Int, interleaved: Bool) -> AVAudioFormat? {
    guard sampleRate > 0, channels > 0 else { return nil }
    let count = AVAudioChannelCount(channels)
    if let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: count,
      interleaved: interleaved
    ) {
      return format
    }
    var flags: UInt32 = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if !interleaved {
      flags |= kAudioFormatFlagIsNonInterleaved
    }
    let bytesPerFrame: UInt32 = interleaved ? UInt32(channels) * 4 : 4
    var description = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: flags,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 32,
      mReserved: 0
    )
    return AVAudioFormat(streamDescription: &description)
  }

  /// Float at the device rate, with one client channel per device input.
  /// The hardware clock is not changed. The channel map is identity, so the
  /// unit cannot keep channel 0 and drop the rest before our mix.
  /// Uninitialize can drop the selected device, so the device is set again.
  @discardableResult
  static func applyClientFormat(
    audioUnit: AudioUnit, deviceID: AudioDeviceID, sampleRate: Double, channels: Int
  ) -> AVAudioFormat? {
    guard channels > 0, sampleRate > 0, deviceID != 0 else { return nil }
    AudioUnitUninitialize(audioUnit)
    var identifier = deviceID
    guard
      AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &identifier,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      ) == noErr
    else { return nil }
    for interleaved in CaptureFormatPlan.interleavedChoices(channelCount: channels) {
      guard
        let format = floatFormat(
          sampleRate: sampleRate, channels: channels, interleaved: interleaved)
      else { continue }
      var description = format.streamDescription.pointee
      let status = AudioUnitSetProperty(
        audioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        1,
        &description,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      )
      if status == noErr {
        setIdentityChannelMap(audioUnit: audioUnit, channels: channels)
        return format
      }
    }
    return nil
  }

  private static func deviceChannelCount(
    deviceID: AudioDeviceID, audioUnit: AudioUnit, native: CaptureStreamDescription?
  ) -> Int {
    let hal = AudioDeviceList.inputChannelCount(deviceID)
    let unit = Int(unitStreamFormat(audioUnit)?.mChannelsPerFrame ?? 0)
    let described = native?.channelCount ?? 0
    return max(hal, unit, described)
  }

  private static func clientSampleRate(
    audioUnit: AudioUnit, native: CaptureStreamDescription?, input: AVAudioInputNode
  ) -> Double {
    if let unit = unitStreamFormat(audioUnit), unit.mSampleRate > 0 {
      return unit.mSampleRate
    }
    if let native, native.sampleRate > 0 {
      return native.sampleRate
    }
    return input.inputFormat(forBus: 0).sampleRate
  }

  private static func unitStreamFormat(_ audioUnit: AudioUnit) -> AudioStreamBasicDescription? {
    var description = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioUnitGetProperty(
      audioUnit,
      kAudioUnitProperty_StreamFormat,
      kAudioUnitScope_Input,
      1,
      &description,
      &size
    )
    guard status == noErr, description.mSampleRate > 0 || description.mChannelsPerFrame > 0 else {
      return nil
    }
    return description
  }

  private static func setIdentityChannelMap(audioUnit: AudioUnit, channels: Int) {
    guard channels > 0 else { return }
    var map = CaptureFormatPlan.identityChannelMap(channelCount: channels).map { Int32($0) }
    let size = UInt32(MemoryLayout<Int32>.size * map.count)
    _ = map.withUnsafeMutableBufferPointer { pointer in
      AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_ChannelMap,
        kAudioUnitScope_Output,
        1,
        pointer.baseAddress,
        size
      )
    }
  }

  private static func tapFormat(_ input: AVAudioInputNode, preferredChannels: Int) -> AVAudioFormat
  {
    let reported = input.outputFormat(forBus: 0)
    if reported.sampleRate > 0, reported.channelCount > 0 {
      return reported
    }
    let channels = max(preferredChannels, 1)
    let rate = reported.sampleRate > 0 ? reported.sampleRate : CaptureFormatPlan.encodeRate
    let interleaved = CaptureFormatPlan.interleavedChoices(channelCount: channels).first ?? false
    return floatFormat(sampleRate: rate, channels: channels, interleaved: interleaved) ?? reported
  }

  private static func startFailure(_ error: Error) -> String {
    "Could not start audio capture (\(error.localizedDescription)). Allow the microphone in System Settings, and check the selected device."
  }

  private static func bind(_ audioUnit: AudioUnit, deviceID: AudioDeviceID) -> Bool {
    AudioUnitUninitialize(audioUnit)
    var identifier = deviceID
    return AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &identifier,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    ) == noErr
  }

  private static func currentDevice(_ audioUnit: AudioUnit) -> AudioDeviceID? {
    var bound = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &bound,
      &size
    )
    guard status == noErr, bound != 0 else { return nil }
    return bound
  }

  static func nativeDescription(deviceID: AudioDeviceID) -> CaptureStreamDescription? {
    nativeStream(deviceID: deviceID)
  }

  private static func nativeStream(deviceID: AudioDeviceID) -> CaptureStreamDescription? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var description = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &description) == noErr
    else {
      return nil
    }
    let flags = description.mFormatFlags
    return CaptureStreamDescription(
      sampleRate: description.mSampleRate,
      channelCount: Int(description.mChannelsPerFrame),
      bitsPerChannel: Int(description.mBitsPerChannel),
      isFloat: (flags & kAudioFormatFlagIsFloat) != 0,
      isInterleaved: (flags & kAudioFormatFlagIsNonInterleaved) == 0
    )
  }

  private static func describe(_ format: AVAudioFormat) -> CaptureStreamDescription {
    let description = format.streamDescription.pointee
    let flags = description.mFormatFlags
    return CaptureStreamDescription(
      sampleRate: format.sampleRate,
      channelCount: Int(format.channelCount),
      bitsPerChannel: Int(description.mBitsPerChannel),
      isFloat: format.commonFormat == .pcmFormatFloat32 || (flags & kAudioFormatFlagIsFloat) != 0,
      isInterleaved: format.isInterleaved
    )
  }
}

/// Hears sample-rate and channel-layout changes on the open input and asks
/// capture to rebuild. The device clock is only observed, never changed.
final class AudioFormatWatch {
  private struct Listener {
    var address: AudioObjectPropertyAddress
    var block: AudioObjectPropertyListenerBlock
  }

  private var listeners: [Listener] = []
  private var deviceID: AudioDeviceID = 0

  func start(deviceID: AudioDeviceID, queue: DispatchQueue, handler: @escaping () -> Void) {
    stop()
    guard deviceID != 0 else { return }
    self.deviceID = deviceID
    let pairs: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
      (kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput),
      (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
      (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
    ]
    for (selector, scope) in pairs {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
      )
      let block: AudioObjectPropertyListenerBlock = { _, _ in
        handler()
      }
      guard AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr else {
        continue
      }
      listeners.append(Listener(address: address, block: block))
    }
  }

  func stop() {
    let deviceID = self.deviceID
    if deviceID != 0 {
      for index in listeners.indices {
        AudioObjectRemovePropertyListenerBlock(
          deviceID, &listeners[index].address, nil, listeners[index].block)
      }
    }
    listeners.removeAll()
    self.deviceID = 0
  }
}
