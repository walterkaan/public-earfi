import Foundation

/// Host for anonymous install and run reports, and the macOS update check.
/// Change `base` to point every call at another server. The app does not
/// request location; the server derives a country from the connection IP.
public enum RoomCastAPI {
  public static let base = "https://roomcast.channel"

  public static var installURL: URL { url("api/roomcast/install") }
  public static var runURL: URL { url("api/roomcast/run") }
  public static var latestMacURL: URL { url("roomcast/mac/latest.json") }

  public static func url(_ path: String) -> URL {
    let root = base.hasSuffix("/") ? String(base.dropLast()) : base
    let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
    guard let url = URL(string: root + "/" + suffix) else {
      fatalError("RoomCastAPI.base is not a valid URL: \(base)")
    }
    return url
  }
}

public enum RoomCastTime {
  /// UTC timestamp such as `2026-11-19T19:20:00Z`. Always 20 characters, ending in `Z`.
  public static func iso8601(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
      parts.year ?? 0,
      parts.month ?? 0,
      parts.day ?? 0,
      parts.hour ?? 0,
      parts.minute ?? 0,
      parts.second ?? 0
    )
  }

  /// The form the server accepts: `yyyy-MM-dd'T'HH:mm:ssZ`.
  public static func isUTCTimestamp(_ value: String) -> Bool {
    guard value.count == 20, value.hasSuffix("Z") else { return false }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.isLenient = false
    guard let date = formatter.date(from: value) else { return false }
    return iso8601(date) == value
  }
}

public enum RoomCastSystem {
  /// `major.minor.patch` of the running OS. No build number and no location.
  public static var versionString: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }
}

public enum UsagePayload {
  public static let maxBodyBytes = 2048
  public static let maxAppVersionLength = 32
  public static let maxOSVersionLength = 64
  /// `UUID().uuidString`: 8-4-4-4-12 hex digits and hyphens.
  public static let serialLength = 36

  public static func clipAppVersion(_ value: String) -> String {
    String(value.prefix(maxAppVersionLength))
  }

  public static func clipOSVersion(_ value: String) -> String {
    String(value.prefix(maxOSVersionLength))
  }

  /// 36-character hyphenated UUID. Case is not changed; `UUID().uuidString` is uppercase.
  public static func isInstallationSerial(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    let counts = [8, 4, 4, 4, 12]
    guard value.count == serialLength, parts.count == counts.count else { return false }
    for (part, count) in zip(parts, counts) {
      guard part.count == count, part.allSatisfy(\.isHexDigit) else { return false }
    }
    return true
  }

  /// Install object. Exactly `serial`, `installed_at`, `app_version`, `os_version`.
  /// Nil when the serial or timestamp would be rejected, or the body exceeds 2 KB.
  public static func installJSON(
    serial: String, installedAt: String, appVersion: String, osVersion: String
  ) -> Data? {
    guard isInstallationSerial(serial), RoomCastTime.isUTCTimestamp(installedAt) else { return nil }
    return json(
      [
        "serial": serial,
        "installed_at": installedAt,
        "app_version": clipAppVersion(appVersion),
        "os_version": clipOSVersion(osVersion),
      ],
      keys: ["serial", "installed_at", "app_version", "os_version"]
    )
  }

  /// Run object. Exactly `serial`, `ran_at`, `app_version`.
  public static func runJSON(serial: String, ranAt: String, appVersion: String) -> Data? {
    guard isInstallationSerial(serial), RoomCastTime.isUTCTimestamp(ranAt) else { return nil }
    return json(
      [
        "serial": serial,
        "ran_at": ranAt,
        "app_version": clipAppVersion(appVersion),
      ],
      keys: ["serial", "ran_at", "app_version"]
    )
  }

  private static func json(_ object: [String: String], keys: Set<String>) -> Data? {
    guard Set(object.keys) == keys, JSONSerialization.isValidJSONObject(object) else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    guard data.count <= maxBodyBytes else { return nil }
    guard
      let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(decoded.keys) == keys,
      decoded.values.allSatisfy({ $0 is String })
    else { return nil }
    return data
  }
}

/// How to treat one install or run response. Runs are never queued for later.
public enum UsagePostOutcome: Equatable {
  /// 2xx. The install is registered.
  case registered
  /// 400, 413, or 415. Do not send this payload again.
  case rejected
  /// 429. Stop for this launch. The install is tried again next launch.
  case throttled
  /// 503, any other status, or no response. Retry the install next launch.
  case retryLater

  public init(statusCode: Int?) {
    guard let statusCode else {
      self = .retryLater
      return
    }
    if (200..<300).contains(statusCode) {
      self = .registered
    } else if statusCode == 400 || statusCode == 413 || statusCode == 415 {
      self = .rejected
    } else if statusCode == 429 {
      self = .throttled
    } else {
      self = .retryLater
    }
  }
}

public enum RoomCastRequest {
  /// POST JSON. The only header is `Content-Type: application/json`. No cookies.
  public static func post(url: URL, body: Data) -> URLRequest? {
    guard body.count <= UsagePayload.maxBodyBytes else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 6)
    request.httpMethod = "POST"
    request.httpBody = body
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  /// GET of the update feed. No body, no cookies, and no custom headers.
  /// The URL is the feed itself: it does not carry the serial.
  public static func updateCheck(url: URL) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: 6)
    request.httpMethod = "GET"
    request.httpBody = nil
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.allHTTPHeaderFields = [:]
    return request
  }
}

public struct UsageIdentity: Equatable {
  public var serial: String
  public var installedAt: String
  public var installAcknowledged: Bool

  public init(serial: String, installedAt: String, installAcknowledged: Bool) {
    self.serial = serial
    self.installedAt = installedAt
    self.installAcknowledged = installAcknowledged
  }
}

/// Anonymous serial and the first-launch timestamp. Stored beside the other
/// preferences, not inside the resettable settings blob, so Reset keeps them.
public struct UsageIdentityStore {
  public static let serialKey = "roomcast.telemetry.serial"
  public static let installedAtKey = "roomcast.telemetry.installedAt"
  public static let installAcknowledgedKey = "roomcast.telemetry.installAcknowledged"

  public var defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// Reuses a saved serial forever. The first launch stores `UUID().uuidString`
  /// and an ISO8601 UTC install time. A value that is not that shape is replaced
  /// so the server is not sent a payload it would reject with 400.
  public func loadOrCreate(
    now: Date = Date(), serial makeSerial: () -> String = { UUID().uuidString }
  ) -> UsageIdentity {
    let savedSerial =
      defaults.string(forKey: Self.serialKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let savedInstalled = defaults.string(forKey: Self.installedAtKey) ?? ""
    let serialIsValid = UsagePayload.isInstallationSerial(savedSerial)
    let serial = serialIsValid ? savedSerial : freshSerial(makeSerial)
    let installedAt =
      RoomCastTime.isUTCTimestamp(savedInstalled) ? savedInstalled : RoomCastTime.iso8601(now)
    if serial != savedSerial {
      defaults.set(serial, forKey: Self.serialKey)
    }
    if installedAt != savedInstalled {
      defaults.set(installedAt, forKey: Self.installedAtKey)
    }
    // A replaced serial has not been registered. Ask again on this launch.
    if !serialIsValid && !savedSerial.isEmpty {
      defaults.set(false, forKey: Self.installAcknowledgedKey)
    }
    return UsageIdentity(
      serial: serial,
      installedAt: installedAt,
      installAcknowledged: defaults.bool(forKey: Self.installAcknowledgedKey)
    )
  }

  private func freshSerial(_ makeSerial: () -> String) -> String {
    let proposed = makeSerial()
    if UsagePayload.isInstallationSerial(proposed) { return proposed }
    let fallback = UUID().uuidString
    if UsagePayload.isInstallationSerial(fallback) { return fallback }
    return "00000000-0000-0000-0000-000000000000"
  }

  public func markInstallAcknowledged() {
    defaults.set(true, forKey: Self.installAcknowledgedKey)
  }
}

public struct SemanticVersion: Equatable {
  public var parts: [Int]

  public init?(_ raw: String) {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("v") || text.hasPrefix("V") {
      text.removeFirst()
    }
    let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(pieces.count) else { return nil }
    var numbers: [Int] = []
    for piece in pieces {
      guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let number = Int(piece) else {
        return nil
      }
      numbers.append(number)
    }
    parts = numbers
  }

  /// Numeric major.minor.patch compare. Missing pieces are zero, so `1.0`
  /// equals `1.0.0`. Nil when either string is not a dotted version.
  public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
    guard let left = SemanticVersion(lhs), let right = SemanticVersion(rhs) else { return nil }
    let count = max(left.parts.count, right.parts.count)
    for index in 0..<count {
      let l = index < left.parts.count ? left.parts[index] : 0
      let r = index < right.parts.count ? right.parts[index] : 0
      if l < r { return .orderedAscending }
      if l > r { return .orderedDescending }
    }
    return .orderedSame
  }
}

public struct MacRelease: Equatable {
  public var version: String
  public var build: String
  public var url: String
  public var notes: String
  public var minOS: String

  public init(version: String, build: String, url: String, notes: String, minOS: String) {
    self.version = version
    self.build = build
    self.url = url
    self.notes = notes
    self.minOS = minOS
  }

  /// `{"version","build","url","notes","min_os"}`. Version and an http(s) url
  /// are required. The other fields may be missing.
  public static func parse(_ data: Data) -> MacRelease? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    guard let version = object["version"] as? String, SemanticVersion(version) != nil else {
      return nil
    }
    guard let url = object["url"] as? String, Self.isDownloadURL(url) else { return nil }
    return MacRelease(
      version: version,
      build: object["build"] as? String ?? "",
      url: url,
      notes: object["notes"] as? String ?? "",
      minOS: object["min_os"] as? String ?? ""
    )
  }

  public static func isDownloadURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
    guard scheme == "https" || scheme == "http" else { return false }
    let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !host.isEmpty
  }
}

public enum UpdateVerdict: Equatable {
  /// The running app is the same version or newer. The string is the running version.
  case upToDate(version: String)
  /// `minOS` is set when this Mac is older than the release's `min_os`.
  case available(version: String, notes: String, url: String, minOS: String?)
  case unreadable

  public static func decide(current: String, osVersion: String, payload: Data) -> UpdateVerdict {
    guard let release = MacRelease.parse(payload) else { return .unreadable }
    guard let order = SemanticVersion.compare(current, release.version) else { return .unreadable }
    if order != .orderedAscending {
      return .upToDate(version: current)
    }
    var required: String?
    let minimum = release.minOS.trimmingCharacters(in: .whitespacesAndNewlines)
    if !minimum.isEmpty, SemanticVersion(minimum) != nil,
      let osOrder = SemanticVersion.compare(osVersion, minimum), osOrder == .orderedAscending
    {
      required = minimum
    }
    return .available(
      version: release.version, notes: release.notes, url: release.url, minOS: required)
  }
}
