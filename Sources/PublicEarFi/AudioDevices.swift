import CoreAudio
import Foundation
import PublicEarFiCore

struct AudioInputDevice: Identifiable, Equatable {
  var id: String
  var name: String
  var inputChannels: Int
  var isBuiltIn: Bool
  var isBluetooth: Bool
  var deviceID: AudioDeviceID
}

enum AudioDeviceList {
  static func inputs() -> [AudioInputDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var identifiers = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &identifiers) == noErr else {
      return []
    }
    return identifiers.compactMap(makeDevice)
  }

  /// False for a missing or unplugged device. Call this before touching
  /// AVAudioEngine, which can abort if the device id is stale.
  static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
    guard deviceID != 0, deviceID != AudioObjectID(kAudioObjectUnknown) else { return false }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr else {
      return false
    }
    return alive != 0
  }

  /// Changes the hardware clock. Broadcasting must not call this.
  /// The app captures at the device's own rate and converts to 48 kHz.
  static func setNominalSampleRate(deviceID: AudioDeviceID, rate: Double) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<Float64>.size)
    var current = Float64(0)
    if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &current) == noErr,
      abs(current - rate) < 1
    {
      return true
    }
    var requested = Float64(rate)
    size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &requested) == noErr
  }

  static func transportDescription(_ deviceID: AudioDeviceID) -> String {
    AudioTransportLabel.describe(transport(deviceID))
  }

  static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
    let raw = transport(deviceID)
    return raw == kAudioDeviceTransportTypeBluetooth || AudioTransportLabel.isBluetooth(raw)
  }

  private static func makeDevice(_ deviceID: AudioDeviceID) -> AudioInputDevice? {
    let channels = inputChannelCount(deviceID)
    let rawTransport = transport(deviceID)
    let bluetooth =
      rawTransport == kAudioDeviceTransportTypeBluetooth
      || AudioTransportLabel.isBluetooth(rawTransport)
    // Output-only devices stay hidden. A Bluetooth headset can report no
    // inputs for a moment while macOS switches it to call mode.
    guard channels > 0 || (bluetooth && isAlive(deviceID)) else { return nil }
    let uid = copyString(deviceID, kAudioDevicePropertyDeviceUID) ?? "device-\(deviceID)"
    let name = copyString(deviceID, kAudioObjectPropertyName) ?? uid
    return AudioInputDevice(
      id: uid,
      name: name,
      inputChannels: channels,
      isBuiltIn: rawTransport == kAudioDeviceTransportTypeBuiltIn,
      isBluetooth: bluetooth,
      deviceID: deviceID
    )
  }

  private static func transport(_ deviceID: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
      return 0
    }
    return value
  }

  static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0
    else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
      return 0
    }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func copyString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0
    else { return nil }
    var value: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return value as String
  }
}

final class AudioHotplug {
  private var block: AudioObjectPropertyListenerBlock?
  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

  func start(_ handler: @escaping () -> Void) {
    let listener: AudioObjectPropertyListenerBlock = { _, _ in
      handler()
    }
    block = listener
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
  }

  func stop() {
    guard let block else { return }
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    self.block = nil
  }
}
