import Foundation

public enum AppPaths {
  public static let folderName = "Public EarFi"

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
}

public struct SupervisedPIDs: Codable, Equatable {
  public var mediamtx: Int32?
  public var ffmpeg: Int32?
  public var mediamtxExecutable: String?
  public var ffmpegExecutable: String?

  public init(
    mediamtx: Int32? = nil,
    ffmpeg: Int32? = nil,
    mediamtxExecutable: String? = nil,
    ffmpegExecutable: String? = nil
  ) {
    self.mediamtx = mediamtx
    self.ffmpeg = ffmpeg
    self.mediamtxExecutable = mediamtxExecutable
    self.ffmpegExecutable = ffmpegExecutable
  }
}

public enum DiagnosticsReport {
  public static func make(
    appVersion: String,
    systemDescription: String,
    settings: AppSettings,
    listenerURL: String,
    helperSummary: String,
    logLines: [String],
    logLimit: Int = 200
  ) -> String {
    let tail = Array(logLines.suffix(logLimit))
    let summary = settingsSummary(settings)
    return """
      Public EarFi \(appVersion)
      \(systemDescription)
      Listener URL: \(listenerURL)
      \(helperSummary)

      Settings:
      \(summary)

      Recent log (\(tail.count) lines):
      \(tail.joined(separator: "\n"))
      """
  }

  public static func settingsSummary(_ settings: AppSettings) -> String {
    [
      "device UID: \(settings.inputDeviceUID ?? "(auto)")",
      "channels: \(settings.channelMode.rawValue) from input \(settings.inputChannel)",
      "quality: \(settings.quality.rawValue) \(settings.resolvedBitrateKbps) kbps \(settings.opusApplication)",
      "sample rate: \(FFmpegCommand.sampleRate) Hz, \(FFmpegCommand.frameDurationMilliseconds) ms frames",
      "stream: \(settings.streamName)",
      "listener port: \(settings.listenerPort)",
      "ICE port: \(settings.icePort)",
      "network mode: \(settings.networkMode.rawValue)",
      "advertised address: \(settings.advertisedAddress ?? "(auto)")",
      "URL style: \(settings.urlStyle.rawValue)",
      "max listeners: \(settings.maxListeners)",
      "keep awake: \(settings.keepAwake)",
      "log level: \(settings.logLevel.rawValue)",
    ].joined(separator: "\n")
  }
}
