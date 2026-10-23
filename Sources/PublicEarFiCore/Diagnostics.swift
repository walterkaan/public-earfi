import Foundation

public enum AppPaths {
  public static let folderName = "RoomCast"

  public static func supportDirectory(home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/\(folderName)", isDirectory: true)
  }

  public static func logDirectory(home: URL) -> URL {
    home.appendingPathComponent("Library/Logs/\(folderName)", isDirectory: true)
  }

  public static func configFile(home: URL) -> URL {
    supportDirectory(home: home).appendingPathComponent("mediamtx.yml")
  }

  public static func pidFile(home: URL) -> URL {
    supportDirectory(home: home).appendingPathComponent("supervised-pids.json")
  }

  /// Replaced each time Open PDF QR Poster is used.
  public static func posterFile(home: URL) -> URL {
    supportDirectory(home: home).appendingPathComponent("RoomCast poster.pdf")
  }
}

public struct SupervisedPIDs: Codable, Equatable {
  public var mediamtx: Int32?
  public var ffmpeg: Int32?
  public var mediamtxGroup: Int32?
  public var ffmpegGroup: Int32?
  public var mediamtxExecutable: String?
  public var ffmpegExecutable: String?

  public init(
    mediamtx: Int32? = nil,
    ffmpeg: Int32? = nil,
    mediamtxGroup: Int32? = nil,
    ffmpegGroup: Int32? = nil,
    mediamtxExecutable: String? = nil,
    ffmpegExecutable: String? = nil
  ) {
    self.mediamtx = mediamtx
    self.ffmpeg = ffmpeg
    self.mediamtxGroup = mediamtxGroup
    self.ffmpegGroup = ffmpegGroup
    self.mediamtxExecutable = mediamtxExecutable
    self.ffmpegExecutable = ffmpegExecutable
  }
}

public enum DiagnosticsReport {
  public static func make(
    appVersion: String,
    systemDescription: String,
    settings: AppSettings,
    appName: String = BroadcastTitle.fallbackAppName,
    listenerURL: String,
    helperSummary: String,
    logLines: [String],
    logLimit: Int = 200
  ) -> String {
    let tail = Array(logLines.suffix(logLimit))
    let summary = settingsSummary(settings, appName: appName)
    return """
      RoomCast \(appVersion)
      \(systemDescription)
      Listener URL: \(listenerURL)
      \(helperSummary)

      Settings:
      \(summary)

      Recent log (\(tail.count) lines):
      \(tail.joined(separator: "\n"))
      """
  }

  /// Poster Wi-Fi name and security only. The password is never a settings field
  /// and must not be passed into this report.
  public static func settingsSummary(
    _ settings: AppSettings, appName: String = BroadcastTitle.fallbackAppName
  ) -> String {
    let posterNetwork = settings.posterNetworkName.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return [
      "device UID: \(settings.inputDeviceUID ?? "(auto)")",
      "channels: \(settings.channelMode == .mono ? "mono (all inputs summed)" : "stereo from input \(settings.inputChannel)")",
      "volume: \(InputGain.label(settings.inputGainDB))",
      "quality: \(settings.quality.rawValue) \(settings.resolvedBitrateKbps) kbps \(settings.opusApplication)",
      "sample rate: \(FFmpegCommand.sampleRate) Hz, \(FFmpegCommand.frameDurationMilliseconds) ms frames",
      "stream: \(settings.streamName)",
      "broadcast title: \(BroadcastTitle.resolved(stored: settings.broadcastTitle, appName: appName))",
      "listener port: \(settings.listenerPort)",
      "ICE port: \(settings.icePort)",
      "network mode: \(settings.networkMode.rawValue)",
      "advertised address: \(settings.advertisedAddress ?? "(auto)")",
      "URL style: \(settings.urlStyle.rawValue)",
      "max listeners: \(settings.maxListeners)",
      "keep awake: \(settings.keepAwake)",
      "log level: \(settings.logLevel.rawValue)",
      "poster Wi-Fi: \(posterNetwork.isEmpty ? "(not set)" : posterNetwork)",
      "poster Wi-Fi security: \(settings.posterWiFiSecurity.rawValue)",
      "poster Wi-Fi hidden: \(settings.posterWiFiHidden)",
      "poster Wi-Fi password: not included",
      "saved in: ~/Library/Preferences/\(SettingsRepair.defaultsDomain).plist key \(SettingsStore.storageKey)",
    ].joined(separator: "\n")
  }
}
