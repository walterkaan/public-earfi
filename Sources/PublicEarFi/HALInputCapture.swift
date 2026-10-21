import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import PublicEarFiCore

/// One open of one device. A Start, a device change, and the level meter each
/// build a new session and destroy the previous one. Nothing here is an
/// `AVAudioEngine`, so a failed open cannot leave a stale 1-channel input node
/// for the next device.
protocol DeviceInputSession: AnyObject {
  var isRunning: Bool { get }
  func start(
    deviceID: AudioDeviceID,
    onBuffer: @escaping (AVAudioPCMBuffer) -> Void
  ) -> Result<CaptureStreamDescription, String>
  func stop()
}

/// Captures the chosen HAL device with `AudioDeviceCreateIOProcIDWithBlock`.
/// The device id is the device. The input format is read from that device
/// before the IOProc starts. The client format is never rewritten.
final class HALDeviceInputSession: DeviceInputSession {
  private let lock = NSLock()
  private var deviceID: AudioDeviceID = 0
  private var procID: AudioDeviceIOProcID?
  private var running = false

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  func start(
    deviceID: AudioDeviceID,
    onBuffer: @escaping (AVAudioPCMBuffer) -> Void
  ) -> Result<CaptureStreamDescription, String> {
    stop()
    guard AudioDeviceList.isAlive(deviceID) else {
      return .failure("The selected audio device is not connected.")
    }
    guard let nominal = Self.inputFormat(deviceID: deviceID) else {
      return .failure(CaptureFormatPlan.notReadyMessage(deviceName: ""))
    }
    let configured = AudioDeviceList.inputChannelCount(deviceID)
    let channels = max(Int(nominal.mChannelsPerFrame), configured)
    let described = Self.describe(nominal, channels: channels)
    guard let bound = CaptureDeviceBinding.bound(device: described, staleChannels: 0) else {
      if AudioDeviceList.isAlive(deviceID) {
        return .failure(CaptureFormatPlan.notReadyMessage(deviceName: ""))
      }
      return .failure(CaptureFormatPlan.impossibleMessage(deviceName: "", stream: described))
    }
    guard nominal.mFormatID == 0 || nominal.mFormatID == kAudioFormatLinearPCM else {
      return .failure(CaptureFormatPlan.impossibleMessage(deviceName: "", stream: bound))
    }
    var created: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&created, deviceID, nil) {
      _, inputData, _, _, _ in
      guard let buffer = DeviceBufferAdapter.pcmBuffer(list: inputData, nominal: nominal) else {
        return
      }
      onBuffer(buffer)
    }
    guard status == noErr, let created else {
      return .failure(Self.openFailure)
    }
    let started = AudioDeviceStart(deviceID, created)
    if started != noErr {
      AudioDeviceDestroyIOProcID(deviceID, created)
      return .failure(Self.openFailure)
    }
    lock.lock()
    self.deviceID = deviceID
    procID = created
    running = true
    lock.unlock()
    return .success(bound)
  }

  func stop() {
    let device: AudioDeviceID
    let proc: AudioDeviceIOProcID?
    lock.lock()
    device = deviceID
    proc = procID
    deviceID = 0
    procID = nil
    running = false
    lock.unlock()
    guard let proc, device != 0 else { return }
    AudioDeviceStop(device, proc)
    AudioDeviceDestroyIOProcID(device, proc)
  }

  private static let openFailure =
    "Could not open the selected audio device. Allow the microphone in System Settings, and check the selected device."

  private static func inputFormat(deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var description = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &description) == noErr
    else { return nil }
    guard description.mSampleRate > 0 || description.mChannelsPerFrame > 0 else { return nil }
    return description
  }

  private static func describe(_ description: AudioStreamBasicDescription, channels: Int)
    -> CaptureStreamDescription
  {
    let flags = description.mFormatFlags
    return CaptureStreamDescription(
      sampleRate: description.mSampleRate,
      channelCount: channels,
      bitsPerChannel: Int(description.mBitsPerChannel),
      isFloat: (flags & kAudioFormatFlagIsFloat) != 0,
      isInterleaved: (flags & kAudioFormatFlagIsNonInterleaved) == 0
    )
  }
}

/// Copies one IOProc buffer list into an `AVAudioPCMBuffer` of the device's
/// own channel count. The list pointer is only valid inside the callback.
enum DeviceBufferAdapter {
  static func pcmBuffer(
    list: UnsafePointer<AudioBufferList>,
    nominal: AudioStreamBasicDescription
  ) -> AVAudioPCMBuffer? {
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    guard !source.isEmpty, nominal.mSampleRate > 0 else { return nil }
    let listed = source.reduce(0) { $0 + Int($1.mNumberChannels) }
    let channels = listed > 0 ? listed : Int(nominal.mChannelsPerFrame)
    guard channels > 0 else { return nil }
    let channelsInBuffer = listed > 0 ? Int(source[0].mNumberChannels) : channels
    let frames = frameCount(
      buffer: source[0], nominal: nominal, channelsInBuffer: channelsInBuffer)
    guard frames > 0 else { return nil }
    let isFloat32 =
      (nominal.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && nominal.mBitsPerChannel == 32
    if isFloat32 {
      return interleavedFloatBuffer(
        source: source, frames: frames, channels: channels, sampleRate: nominal.mSampleRate)
    }
    let severalBuffers = source.count > 1
    var asbd = nominal
    asbd.mFormatID = nominal.mFormatID == 0 ? kAudioFormatLinearPCM : nominal.mFormatID
    asbd.mChannelsPerFrame = UInt32(channels)
    asbd.mFramesPerPacket = 1
    let sampleBytes = UInt32(max(1, Int(nominal.mBitsPerChannel) / 8))
    if severalBuffers {
      asbd.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
      asbd.mBytesPerFrame = sampleBytes
      asbd.mBytesPerPacket = sampleBytes
    } else {
      asbd.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
      let frameBytes = sampleBytes * UInt32(channels)
      asbd.mBytesPerFrame = frameBytes
      asbd.mBytesPerPacket = frameBytes
    }
    guard let format = AVAudioFormat(streamDescription: &asbd),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    guard destination.count == source.count else { return nil }
    for index in 0..<source.count {
      guard let from = source[index].mData, let to = destination[index].mData else { return nil }
      let count = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
      guard count > 0 else { return nil }
      to.copyMemory(from: from, byteCount: count)
    }
    return buffer
  }

  /// Float devices are copied into one interleaved buffer at the device's
  /// channel count. A 2-channel device stays 2 channels here.
  private static func interleavedFloatBuffer(
    source: UnsafeMutableAudioBufferListPointer,
    frames: Int,
    channels: Int,
    sampleRate: Double
  ) -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels),
        interleaved: true
      ),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard let destination = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }
    let output = destination.bindMemory(to: Float.self, capacity: frames * channels)
    if source.count == 1, let raw = source[0].mData {
      let count = min(frames * channels, Int(source[0].mDataByteSize) / MemoryLayout<Float>.size)
      guard count > 0 else { return nil }
      let input = raw.bindMemory(to: Float.self, capacity: count)
      for index in 0..<count {
        output[index] = input[index]
      }
      return buffer
    }
    guard source.count == channels else { return nil }
    for channel in 0..<channels {
      guard let raw = source[channel].mData else { return nil }
      let input = raw.bindMemory(to: Float.self, capacity: frames)
      for frame in 0..<frames {
        output[frame * channels + channel] = input[frame]
      }
    }
    return buffer
  }

  private static func frameCount(
    buffer: AudioBuffer, nominal: AudioStreamBasicDescription, channelsInBuffer: Int
  ) -> Int {
    let bytes = Int(buffer.mDataByteSize)
    guard bytes > 0 else { return 0 }
    let sampleBytes = max(1, Int(nominal.mBitsPerChannel) / 8)
    let nonInterleaved = (nominal.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    if nonInterleaved || channelsInBuffer <= 1 {
      if nominal.mBytesPerFrame > 0, bytes % Int(nominal.mBytesPerFrame) == 0 {
        return bytes / Int(nominal.mBytesPerFrame)
      }
      return bytes / sampleBytes
    }
    if nominal.mBytesPerFrame > 0, bytes % Int(nominal.mBytesPerFrame) == 0 {
      return bytes / Int(nominal.mBytesPerFrame)
    }
    let frameBytes = sampleBytes * max(1, channelsInBuffer)
    guard frameBytes > 0, bytes >= frameBytes else { return 0 }
    return bytes / frameBytes
  }
}
