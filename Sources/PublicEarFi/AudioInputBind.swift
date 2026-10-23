import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import PublicEarFiCore

/// Reads a HAL device's own input streams. Capture opens the device with a
/// fresh IOProc (`HALDeviceInputSession`), not with `AVAudioEngine`.
enum AudioInputBind {
  static func summary(native: CaptureStreamDescription, capture: CaptureStreamDescription) -> String
  {
    "native \(native.summary); capture \(capture.summary)"
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

  static func nativeDescription(deviceID: AudioDeviceID) -> CaptureStreamDescription? {
    nativeStream(deviceID: deviceID)
  }

  /// One line per input stream, so a multi-stream USB device can be compared
  /// with the single 48 kHz stream BlackHole exposes.
  static func inputStreamLines(deviceID: AudioDeviceID) -> [String] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0
    else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var identifiers = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &identifiers) == noErr
    else { return [] }
    return identifiers.enumerated().map { index, streamID in
      let summary = streamDescription(streamID)?.summary ?? "unread"
      return "stream \(index): \(summary)"
    }
  }

  private static func streamDescription(_ streamID: AudioObjectID) -> CaptureStreamDescription? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioStreamPropertyVirtualFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var description = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &description) == noErr
    else { return nil }
    return describeBasic(description)
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
    return describeBasic(description)
  }

  private static func describeBasic(_ description: AudioStreamBasicDescription)
    -> CaptureStreamDescription
  {
    let flags = description.mFormatFlags
    return CaptureStreamDescription(
      sampleRate: description.mSampleRate,
      channelCount: Int(description.mChannelsPerFrame),
      bitsPerChannel: Int(description.mBitsPerChannel),
      isFloat: (flags & kAudioFormatFlagIsFloat) != 0,
      isInterleaved: (flags & kAudioFormatFlagIsNonInterleaved) == 0
    )
  }
}

/// Hears sample-rate, channel-layout, and alive changes on the open input
/// and asks capture to rebuild. The device clock is only observed, never changed.
final class AudioFormatWatch {
  private struct Listener {
    var address: AudioObjectPropertyAddress
    var block: AudioObjectPropertyListenerBlock
  }

  private var listeners: [Listener] = []
  private var deviceID: AudioDeviceID = 0

  func start(deviceID: AudioDeviceID, queue: DispatchQueue, handler: @escaping () -> Void) {
    stop()
    guard deviceID != 0, AudioDeviceList.isPresent(deviceID) else { return }
    self.deviceID = deviceID
    let pairs: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
      (kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput),
      (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
      (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
      (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
    ]
    for (selector, scope) in pairs {
      guard AudioDeviceList.isPresent(deviceID) else { break }
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
      )
      let block: AudioObjectPropertyListenerBlock = { _, _ in
        guard AudioDeviceList.isPresent(deviceID) else { return }
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
    let pending = listeners
    listeners.removeAll()
    self.deviceID = 0
    guard deviceID != 0,
      DeviceProcTeardown.shouldRemoveListeners(isInDeviceList: AudioDeviceList.isPresent(deviceID))
    else { return }
    for listener in pending {
      var address = listener.address
      AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, listener.block)
    }
  }
}
