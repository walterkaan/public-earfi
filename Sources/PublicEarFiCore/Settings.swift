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
  public var quality: QualityPreset
  public var customBitrateKbps: Int
  public var streamName: String
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
  public var posterPaperSize: PaperSize?
  public var posterUseFooter: Bool

  public init(
    inputDeviceUID: String? = nil,
    channelMode: ChannelMode = .mono,
    inputChannel: Int = 1,
    quality: QualityPreset = .speech,
    customBitrateKbps: Int = 64,
    streamName: String = "live",
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
    posterPaperSize: PaperSize? = nil,
    posterUseFooter: Bool = true
  ) {
    self.inputDeviceUID = inputDeviceUID
    self.channelMode = channelMode
    self.inputChannel = inputChannel
    self.quality = quality
    self.customBitrateKbps = customBitrateKbps
    self.streamName = streamName
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
      return channelMode == .stereo ? 128 : 96
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

  public var bandwidthHint: String {
    let listeners = Self.listenerTarget
    let text = formatMbps(estimatedMegabits(listeners: listeners))
    return "\(listeners) listeners ≈ \(text) Mbps"
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
}

private struct StoredSettings: Codable {
  var inputDeviceUID: String?
  var channelMode: ChannelMode?
  var inputChannel: Int?
  var quality: QualityPreset?
  var customBitrateKbps: Int?
  var streamName: String?
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
  var posterPaperSize: PaperSize?
  var posterUseFooter: Bool?
}

public struct SettingsStore {
  public static let storageKey = "publicEarfi.settings.v1"
  public static let posterURLKey = "publicEarfi.posterLastURL"
  public static let posterMadeAtKey = "publicEarfi.posterLastMadeAt"

  public var userDefaults: UserDefaults

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  public func load() -> AppSettings {
    guard let data = userDefaults.data(forKey: Self.storageKey),
      let stored = try? JSONDecoder().decode(StoredSettings.self, from: data)
    else {
      return .defaults
    }
    var settings = AppSettings.defaults
    settings.inputDeviceUID = stored.inputDeviceUID
    if let value = stored.channelMode { settings.channelMode = value }
    if let value = stored.inputChannel { settings.inputChannel = value }
    if let value = stored.quality { settings.quality = value }
    if let value = stored.customBitrateKbps { settings.customBitrateKbps = value }
    if let value = stored.streamName { settings.streamName = value }
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
    settings.posterPaperSize = stored.posterPaperSize
    if let value = stored.posterUseFooter { settings.posterUseFooter = value }
    return settings
  }

  public func save(_ settings: AppSettings) {
    if let data = try? JSONEncoder().encode(settings) {
      userDefaults.set(data, forKey: Self.storageKey)
    }
  }

  public func reset() -> AppSettings {
    let settings = AppSettings.defaults
    save(settings)
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
