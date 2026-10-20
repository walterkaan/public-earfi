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
  }

  static func prepare(engine: AVAudioEngine, deviceID: AudioDeviceID) -> Result<Prepared, String> {
    let input = engine.inputNode
    guard let audioUnit = input.audioUnit else {
      return .failure("The audio engine has no input.")
    }
    guard bind(audioUnit, deviceID: deviceID) else {
      return .failure("Could not open the selected audio device.")
    }
    let format = input.outputFormat(forBus: 0)
    guard currentDevice(audioUnit) == deviceID else {
      return .failure("The selected audio device did not open. Pick it again in Settings.")
    }
    let engineDescription = describe(format)
    let native = nativeStream(deviceID: deviceID) ?? engineDescription
    guard format.sampleRate > 0, format.channelCount > 0 else {
      return .failure(CaptureFormatPlan.impossibleMessage(deviceName: "", stream: native))
    }
    return .success(
      Prepared(
        audioUnit: audioUnit,
        format: format,
        native: native,
        engine: engineDescription
      )
    )
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
