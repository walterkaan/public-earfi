import Foundation

public enum ChannelMode: String, Codable, CaseIterable, Equatable {
  case mono
  case stereo
}

public enum QualityPreset: String, Codable, CaseIterable, Equatable {
  case speech
  case standard
  case music
  case custom
}

public enum NetworkMode: String, Codable, CaseIterable, Equatable {
  case auto
  case udpOnly
  case tcpOnly
}

public enum URLStyle: String, Codable, CaseIterable, Equatable {
  case ip
  case localHostname
}

public enum LogLevel: String, Codable, CaseIterable, Equatable {
  case error
  case warn
  case info
  case debug
}

public struct AppSettings: Codable, Equatable {
  public var inputDeviceUID: String?
  public var channelMode: ChannelMode
  public var inputChannel: Int
  /// Live boost in dB. Not part of the broadcast signature: it applies
  /// without restarting ffmpeg.
  public var inputGainDB: Double
  public var quality: QualityPreset
  public var customBitrateKbps: Int
  public var streamName: String
  /// Empty means the listener page uses "<App name> Broadcast".
  public var broadcastTitle: String
  public var listenerPort: Int
  public var icePort: Int
  public var networkMode: NetworkMode
  public var advertisedAddress: String?
  public var urlStyle: URLStyle
  public var maxListeners: Int
  public var keepAwake: Bool
  public var launchAtLogin: Bool
  public var startWhenAppOpens: Bool
  public var logLevel: LogLevel
  public var posterHeader: String
  public var posterDescription: String
  public var posterShowInstructions: Bool
  public var posterInstructions: String
  public var posterNetworkName: String
  public var posterWiFiSecurity: WiFiSecurity
  public var posterWiFiHidden: Bool
  public var posterPaperSize: PaperSize?
  public var posterUseFooter: Bool

  public init(
    inputDeviceUID: String? = nil,
    channelMode: ChannelMode = .stereo,
    inputChannel: Int = 1,
    inputGainDB: Double = InputGain.defaultDB,
    quality: QualityPreset = .music,
    customBitrateKbps: Int = 96,
    streamName: String = "live",
    broadcastTitle: String = "",
    listenerPort: Int = 8889,
    icePort: Int = 8189,
    networkMode: NetworkMode = .auto,
    advertisedAddress: String? = nil,
    urlStyle: URLStyle = .ip,
    maxListeners: Int = 0,
    keepAwake: Bool = true,
    launchAtLogin: Bool = false,
    startWhenAppOpens: Bool = false,
    logLevel: LogLevel = .info,
    posterHeader: String = PosterBuilder.defaultHeader,
    posterDescription: String = "",
    posterShowInstructions: Bool = true,
    posterInstructions: String = PosterBuilder.defaultInstructions,
    posterNetworkName: String = "",
    posterWiFiSecurity: WiFiSecurity = .wpa,
    posterWiFiHidden: Bool = false,
    posterPaperSize: PaperSize? = nil,
    posterUseFooter: Bool = true
  ) {
    self.inputDeviceUID = inputDeviceUID
    self.channelMode = channelMode
    self.inputChannel = inputChannel
    self.inputGainDB = inputGainDB
    self.quality = quality
    self.customBitrateKbps = customBitrateKbps
    self.streamName = streamName
    self.broadcastTitle = broadcastTitle
    self.listenerPort = listenerPort
    self.icePort = icePort
    self.networkMode = networkMode
    self.advertisedAddress = advertisedAddress
    self.urlStyle = urlStyle
    self.maxListeners = maxListeners
    self.keepAwake = keepAwake
    self.launchAtLogin = launchAtLogin
    self.startWhenAppOpens = startWhenAppOpens
    self.logLevel = logLevel
    self.posterHeader = posterHeader
    self.posterDescription = posterDescription
    self.posterShowInstructions = posterShowInstructions
    self.posterInstructions = posterInstructions
    self.posterNetworkName = posterNetworkName
    self.posterWiFiSecurity = posterWiFiSecurity
    self.posterWiFiHidden = posterWiFiHidden
    self.posterPaperSize = posterPaperSize
    self.posterUseFooter = posterUseFooter
  }

  public static var defaults: AppSettings {
    AppSettings()
  }

  public var opusChannelCount: Int {
    channelMode == .mono ? 1 : 2
  }

  public var resolvedBitrateKbps: Int {
    switch quality {
    case .speech:
      return 32
    case .standard:
      return 64
    case .music:
      // Matches the Music 96k label for both mono and stereo.
      return 96
    case .custom:
      return min(256, max(16, customBitrateKbps))
    }
  }

  public var opusApplication: String {
    quality == .speech ? "voip" : "audio"
  }

  /// Live interpreter: about 30 phones on venue Wi-Fi. The bandwidth hint uses this.
  public static let listenerTarget = 30

  /// Speech is the interpreter preset: mono, 32 kbps. The encode rate stays 48 kHz.
  public mutating func applyPreset(_ preset: QualityPreset) {
    quality = preset
    if preset == .speech {
      channelMode = .mono
    }
  }

  public func estimatedMegabits(listeners: Int) -> Double {
    Double(resolvedBitrateKbps * listeners) / 1000
  }

  public var qualityLabel: String {
    switch quality {
    case .speech:
      return "Speech"
    case .standard:
      return "Standard"
    case .music:
      return "Music"
    case .custom:
      return "Custom"
    }
  }

  /// One line for the selected quality: name, bitrate, and about 30 phones.
  public var bandwidthHint: String {
    let phones = Self.listenerTarget
    let text = formatMbps(estimatedMegabits(listeners: phones))
    return "\(qualityLabel) · \(resolvedBitrateKbps) kbps · about \(phones) phones ≈ \(text) Mbps"
  }

  public func resolvedPaperSize(regionCode: String?, measurementSystemIsUS: Bool) -> PaperSize {
    posterPaperSize
      ?? PaperSize.preferred(
        regionCode: regionCode,
        measurementSystemIsUS: measurementSystemIsUS
      )
  }
}

public struct BroadcastSignature: Equatable {
  public var inputDeviceUID: String?
  public var channelMode: ChannelMode
  public var inputChannel: Int
  public var quality: QualityPreset
  public var customBitrateKbps: Int
  public var streamName: String
  public var listenerPort: Int
  public var icePort: Int
  public var networkMode: NetworkMode
  public var advertisedAddress: String?
  public var maxListeners: Int
  public var logLevel: LogLevel

  public init(_ settings: AppSettings) {
    inputDeviceUID = settings.inputDeviceUID
    channelMode = settings.channelMode
    inputChannel = settings.inputChannel
    quality = settings.quality
    customBitrateKbps = settings.customBitrateKbps
    streamName = settings.streamName
    listenerPort = settings.listenerPort
    icePort = settings.icePort
    networkMode = settings.networkMode
    advertisedAddress = settings.advertisedAddress
    maxListeners = settings.maxListeners
    logLevel = settings.logLevel
  }
}

public struct SettingsIssue: Equatable {
  public var field: String
  public var message: String

  public init(field: String, message: String) {
    self.field = field
    self.message = message
  }
}

public func isValidStreamName(_ name: String) -> Bool {
  guard (1...32).contains(name.count) else { return false }
  return name.allSatisfy { character in
    (character >= "a" && character <= "z") || (character >= "0" && character <= "9")
      || character == "-"
  }
}

public func validate(_ settings: AppSettings) -> [SettingsIssue] {
  var issues: [SettingsIssue] = []
  if !isValidStreamName(settings.streamName) {
    issues.append(
      SettingsIssue(
        field: "streamName",
        message: "Stream name must be 1–32 characters: a–z, 0–9, or hyphen."
      )
    )
  }
  issues += portIssues(settings.listenerPort, field: "listenerPort", label: "Listener port")
  issues += portIssues(settings.icePort, field: "icePort", label: "ICE port")
  if settings.listenerPort == settings.icePort {
    issues.append(
      SettingsIssue(field: "icePort", message: "ICE port must be different from the listener port.")
    )
  }
  if settings.quality == .custom && !(16...256).contains(settings.customBitrateKbps) {
    issues.append(
      SettingsIssue(
        field: "customBitrateKbps", message: "Custom bitrate must be between 16 and 256 kbps.")
    )
  }
  if !(0...500).contains(settings.maxListeners) {
    issues.append(
      SettingsIssue(
        field: "maxListeners", message: "Max listeners must be between 0 (unlimited) and 500.")
    )
  }
  if settings.inputChannel < 1 {
    issues.append(
      SettingsIssue(field: "inputChannel", message: "Input channel must be 1 or higher."))
  }
  return issues
}

private func portIssues(_ port: Int, field: String, label: String) -> [SettingsIssue] {
  var issues: [SettingsIssue] = []
  if !(1024...65535).contains(port) {
    issues.append(SettingsIssue(field: field, message: "\(label) must be between 1024 and 65535."))
  }
  if port == 8554 || port == 9997 {
    issues.append(
      SettingsIssue(
        field: field,
        message: "\(label) \(port) is reserved for the local RTSP or API listener."
      )
    )
  }
  return issues
}

public func formatMbps(_ value: Double) -> String {
  let hundredths = (value * 100).rounded() / 100
  let tenths = (hundredths * 10).rounded() / 10
  if abs(hundredths - tenths) < 0.001 {
    return String(format: "%.1f", tenths)
  }
  return String(format: "%.2f", hundredths)
}

public struct DeviceCandidate: Equatable, Identifiable {
  public var uid: String
  public var name: String
  public var isBuiltIn: Bool
  public var inputChannels: Int

  public var id: String { uid }

  public init(uid: String, name: String, isBuiltIn: Bool, inputChannels: Int) {
    self.uid = uid
    self.name = name
    self.isBuiltIn = isBuiltIn
    self.inputChannels = inputChannels
  }
}

public enum DeviceSelection {
  public static func preferred(devices: [DeviceCandidate], rememberedUID: String?)
    -> DeviceCandidate?
  {
    let inputs = devices.filter { $0.inputChannels > 0 }
    if let rememberedUID, let match = inputs.first(where: { $0.uid == rememberedUID }) {
      return match
    }
    if let external = inputs.first(where: { !$0.isBuiltIn }) {
      return external
    }
    return inputs.first
  }

  /// True when Settings still names a device that is not in the current list.
  /// Zero channels still counts as present. A Bluetooth headset reports that
  /// for a moment while macOS switches it to call mode.
  public static func isMissing(rememberedUID: String?, devices: [DeviceCandidate]) -> Bool {
    guard let rememberedUID else { return false }
    let uid = rememberedUID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !uid.isEmpty else { return false }
    return !devices.contains { $0.uid == uid }
  }
}

/// One input row before the menu is built. Bluetooth headsets can appear
/// twice while macOS switches between music and call mode.
public struct ListedInput: Equatable, Identifiable, Sendable {
  public var uid: String
  public var name: String
  public var isBuiltIn: Bool
  public var inputChannels: Int
  public var isBluetooth: Bool

  public var id: String { uid }

  public init(
    uid: String, name: String, isBuiltIn: Bool, inputChannels: Int, isBluetooth: Bool
  ) {
    self.uid = uid
    self.name = name
    self.isBuiltIn = isBuiltIn
    self.inputChannels = inputChannels
    self.isBluetooth = isBluetooth
  }
}

public enum InputDeviceList {
  /// One row per UID. A second Bluetooth row with the same name is the
  /// profile-switch ghost: the row with no channels is hidden, and if several
  /// still have channels the selected UID stays. When that UID has gone and
  /// one Bluetooth row still has the same name, the selection follows it.
  public static func stabilize(
    devices: [ListedInput], selectedUID: String?, selectedName: String?
  ) -> (devices: [ListedInput], selectedUID: String?) {
    let unique = uniqueUIDs(devices)
    let visible = hideBluetoothTwins(unique, selectedUID: normalized(selectedUID))
    let selected = normalized(selectedUID)
    if let selected, visible.contains(where: { $0.uid == selected }) {
      return (visible, selected)
    }
    let name = normalized(selectedName) ?? ""
    if !name.isEmpty {
      let same = visible.filter {
        $0.isBluetooth && sameName($0.name, name) && $0.inputChannels > 0
      }
      if same.count == 1, let only = same.first {
        return (visible, only.uid)
      }
    }
    return (visible, selected)
  }

  /// A missing USB device is cleared. A missing Bluetooth headset is kept so
  /// a brief profile switch does not move the menu onto the built-in mic.
  public static func shouldForget(
    rememberedUID: String?, visibleUIDs: [String], holdBluetooth: Bool
  ) -> Bool {
    guard let uid = normalized(rememberedUID) else { return false }
    if visibleUIDs.contains(uid) { return false }
    if holdBluetooth { return false }
    return true
  }

  private static func uniqueUIDs(_ devices: [ListedInput]) -> [ListedInput] {
    var order: [String] = []
    var byUID: [String: ListedInput] = [:]
    for device in devices {
      guard let uid = normalized(device.uid) else { continue }
      var copy = device
      copy.uid = uid
      if let existing = byUID[uid] {
        if copy.inputChannels > existing.inputChannels {
          byUID[uid] = copy
        }
        continue
      }
      byUID[uid] = copy
      order.append(uid)
    }
    return order.compactMap { byUID[$0] }
  }

  private static func hideBluetoothTwins(_ devices: [ListedInput], selectedUID: String?)
    -> [ListedInput]
  {
    var drop = Set<String>()
    let names = Set(devices.filter(\.isBluetooth).map { normalized($0.name) ?? "" })
    for name in names where !name.isEmpty {
      let group = devices.filter { $0.isBluetooth && sameName($0.name, name) }
      guard group.count > 1 else { continue }
      let withChannels = group.filter { $0.inputChannels > 0 }
      if withChannels.isEmpty {
        let keep = group.first { $0.uid == selectedUID }?.uid ?? group[0].uid
        for device in group where device.uid != keep {
          drop.insert(device.uid)
        }
        continue
      }
      for device in group where device.inputChannels == 0 {
        drop.insert(device.uid)
      }
      guard withChannels.count > 1 else { continue }
      let keep: String
      if let selectedUID, withChannels.contains(where: { $0.uid == selectedUID }) {
        keep = selectedUID
      } else {
        keep =
          withChannels.reduce(withChannels[0]) { best, next in
            next.inputChannels > best.inputChannels ? next : best
          }.uid
      }
      for device in withChannels where device.uid != keep {
        drop.insert(device.uid)
      }
    }
    return devices.filter { !drop.contains($0.uid) }
  }

  private static func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func sameName(_ left: String, _ right: String) -> Bool {
    let lhs = normalized(left) ?? ""
    let rhs = normalized(right) ?? ""
    return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
  }
}

/// Remembers the Bluetooth row the menu is holding. The row is gone on the
/// next device-list refresh, and that refresh still has to keep the selection
/// instead of treating the headset like an unplugged USB device.
public struct HeadsetSelectionHold: Equatable, Sendable {
  public var uid: String?
  public var name: String?

  public init(uid: String? = nil, name: String? = nil) {
    self.uid = uid
    self.name = name
  }

  /// A Bluetooth row is remembered. A non-Bluetooth row clears the memory.
  /// `nil` means the selection is not in this refresh, and the memory stays.
  public mutating func observe(_ selected: ListedInput?) {
    guard let selected else { return }
    if selected.isBluetooth {
      uid = selected.uid
      name = selected.name
      return
    }
    uid = nil
    name = nil
  }

  public func holds(_ rememberedUID: String?) -> Bool {
    guard let uid else { return false }
    let trimmed = rememberedUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !trimmed.isEmpty && trimmed == uid
  }
}

/// Whether teardown may call into a device that might already be gone.
public enum DeviceProcTeardown {
  /// `AudioDeviceStop` and `AudioDeviceDestroyIOProcID` crash on a device
  /// the HAL has already removed.
  public static func shouldStopIOProc(isInDeviceList: Bool, isAlive: Bool) -> Bool {
    isInDeviceList && isAlive
  }

  /// Remove listeners only while the object is still in the device list.
  public static func shouldRemoveListeners(isInDeviceList: Bool) -> Bool {
    isInDeviceList
  }
}

public struct StoredSettingsLoad: Equatable {
  public var settings: AppSettings
  public var notice: String?

  public init(settings: AppSettings, notice: String?) {
    self.settings = settings
    self.notice = notice
  }
}

public enum SettingsRepair {
  public static let maxInputChannel = 64
  /// UserDefaults domain for the signed app. The file is
  /// ~/Library/Preferences/channel.roomcast.app.plist
  public static let defaultsDomain = "channel.roomcast.app"

  public static let missingDeviceNotice =
    "The saved audio device is not connected. It was cleared. Choose a device in Settings, then press Start."

  public static let unreadableNotice =
    "Saved settings could not be read and were reset. Check Settings, then press Start."

  public static func channelNotice(was: Int) -> String {
    "Input \(was) is not on this device. Reset to Input 1. Press Start again."
  }

  public static func notice(for fields: [String]) -> String? {
    guard !fields.isEmpty else { return nil }
    return
      "Saved settings were invalid (\(fields.joined(separator: ", "))) and were reset. Check Settings, then press Start."
  }

  /// Replaces values that would crash a picker or the broadcast. Device
  /// presence is checked separately, because it depends on the live device list.
  public static func applying(_ original: AppSettings) -> (AppSettings, [String]) {
    var settings = original
    var fields: [String] = []
    if let uid = settings.inputDeviceUID {
      let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
      settings.inputDeviceUID = trimmed.isEmpty ? nil : trimmed
      if settings.inputDeviceUID != original.inputDeviceUID {
        fields.append("device")
      }
    }
    if !(1...maxInputChannel).contains(settings.inputChannel) {
      settings.inputChannel = 1
      fields.append("input channel")
    }
    if !settings.inputGainDB.isFinite
      || !(InputGain.minimumDB...InputGain.maximumDB).contains(settings.inputGainDB)
    {
      settings.inputGainDB = InputGain.defaultDB
      fields.append("volume")
    }
    if !(16...256).contains(settings.customBitrateKbps) {
      settings.customBitrateKbps = min(256, max(16, settings.customBitrateKbps))
      fields.append("bitrate")
    }
    if !isValidStreamName(settings.streamName) {
      settings.streamName = "live"
      fields.append("stream name")
    }
    let title = BroadcastTitle.sanitize(settings.broadcastTitle)
    if title != settings.broadcastTitle {
      settings.broadcastTitle = title
      fields.append("broadcast title")
    }
    if !isUsablePort(settings.listenerPort) {
      settings.listenerPort = 8889
      fields.append("listener port")
    }
    if !isUsablePort(settings.icePort) || settings.icePort == settings.listenerPort {
      settings.icePort = settings.listenerPort == 8189 ? 8190 : 8189
      fields.append("ICE port")
    }
    if !(0...500).contains(settings.maxListeners) {
      settings.maxListeners = 0
      fields.append("max listeners")
    }
    if let address = settings.advertisedAddress {
      let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || !isSafeAdvertised(trimmed) {
        settings.advertisedAddress = nil
        fields.append("address")
      } else if trimmed != address {
        settings.advertisedAddress = trimmed
      }
    }
    return (settings, fields)
  }

  public static func channelFits(_ channel: Int, inputCount: Int) -> Bool {
    (1...max(1, inputCount)).contains(channel)
  }

  public static func isUsablePort(_ port: Int) -> Bool {
    (1024...65535).contains(port) && port != 8554 && port != 9997
  }

  private static func isSafeAdvertised(_ host: String) -> Bool {
    host.allSatisfy { character in
      character.isLetter || character.isNumber || character == "." || character == "-"
        || character == ":"
    }
  }
}

private struct StoredSettings: Codable {
  var inputDeviceUID: String?
  var channelMode: ChannelMode?
  var inputChannel: Int?
  var inputGainDB: Double?
  var quality: QualityPreset?
  var customBitrateKbps: Int?
  var streamName: String?
  var broadcastTitle: String?
  var listenerPort: Int?
  var icePort: Int?
  var networkMode: NetworkMode?
  var advertisedAddress: String?
  var urlStyle: URLStyle?
  var maxListeners: Int?
  var keepAwake: Bool?
  var launchAtLogin: Bool?
  var startWhenAppOpens: Bool?
  var logLevel: LogLevel?
  var posterHeader: String?
  var posterDescription: String?
  var posterShowInstructions: Bool?
  var posterInstructions: String?
  var posterNetworkName: String?
  var posterWiFiSecurity: WiFiSecurity?
  var posterWiFiHidden: Bool?
  var posterPaperSize: PaperSize?
  var posterUseFooter: Bool?
}

public struct SettingsStore {
  public static let storageKey = "roomcast.settings.v1"
  public static let posterURLKey = "roomcast.posterLastURL"
  public static let posterMadeAtKey = "roomcast.posterLastMadeAt"

  public var userDefaults: UserDefaults

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  public func load() -> AppSettings {
    loadResolved().settings
  }

  /// Reads saved settings. Invalid values are replaced with defaults and
  /// written back. A notice is set when anything was repaired.
  public func loadResolved() -> StoredSettingsLoad {
    guard let data = userDefaults.data(forKey: Self.storageKey) else {
      return StoredSettingsLoad(settings: .defaults, notice: nil)
    }
    guard let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
      let settings = AppSettings.defaults
      save(settings)
      return StoredSettingsLoad(settings: settings, notice: SettingsRepair.unreadableNotice)
    }
    let (repaired, fields) = SettingsRepair.applying(apply(stored))
    if !fields.isEmpty {
      save(repaired)
    }
    return StoredSettingsLoad(settings: repaired, notice: SettingsRepair.notice(for: fields))
  }

  public func save(_ settings: AppSettings) {
    if let data = try? JSONEncoder().encode(settings) {
      userDefaults.set(data, forKey: Self.storageKey)
    }
  }

  /// Deletes the saved blob and writes a complete default set.
  public func reset() -> AppSettings {
    userDefaults.removeObject(forKey: Self.storageKey)
    let settings = AppSettings.defaults
    save(settings)
    return load()
  }

  private func apply(_ stored: StoredSettings) -> AppSettings {
    var settings = AppSettings.defaults
    settings.inputDeviceUID = stored.inputDeviceUID
    if let value = stored.channelMode { settings.channelMode = value }
    if let value = stored.inputChannel { settings.inputChannel = value }
    if let value = stored.inputGainDB { settings.inputGainDB = value }
    if let value = stored.quality { settings.quality = value }
    if let value = stored.customBitrateKbps { settings.customBitrateKbps = value }
    if let value = stored.streamName { settings.streamName = value }
    if let value = stored.broadcastTitle { settings.broadcastTitle = value }
    if let value = stored.listenerPort { settings.listenerPort = value }
    if let value = stored.icePort { settings.icePort = value }
    if let value = stored.networkMode { settings.networkMode = value }
    settings.advertisedAddress = stored.advertisedAddress
    if let value = stored.urlStyle { settings.urlStyle = value }
    if let value = stored.maxListeners { settings.maxListeners = value }
    if let value = stored.keepAwake { settings.keepAwake = value }
    if let value = stored.launchAtLogin { settings.launchAtLogin = value }
    if let value = stored.startWhenAppOpens { settings.startWhenAppOpens = value }
    if let value = stored.logLevel { settings.logLevel = value }
    if let value = stored.posterHeader { settings.posterHeader = value }
    if let value = stored.posterDescription { settings.posterDescription = value }
    if let value = stored.posterShowInstructions { settings.posterShowInstructions = value }
    if let value = stored.posterInstructions { settings.posterInstructions = value }
    if let value = stored.posterNetworkName { settings.posterNetworkName = value }
    if let value = stored.posterWiFiSecurity { settings.posterWiFiSecurity = value }
    if let value = stored.posterWiFiHidden { settings.posterWiFiHidden = value }
    settings.posterPaperSize = stored.posterPaperSize
    if let value = stored.posterUseFooter { settings.posterUseFooter = value }
    return settings
  }

  public func posterStamp() -> (url: String, madeAt: Date)? {
    guard let url = userDefaults.string(forKey: Self.posterURLKey), !url.isEmpty else { return nil }
    let madeAt = userDefaults.object(forKey: Self.posterMadeAtKey) as? Date ?? Date()
    return (url, madeAt)
  }

  public func rememberPoster(url: String, madeAt: Date = Date()) {
    userDefaults.set(url, forKey: Self.posterURLKey)
    userDefaults.set(madeAt, forKey: Self.posterMadeAtKey)
  }
}
