import Foundation

public struct StaleAddress: Equatable {
  public var previous: String
  public var current: String
  public var message: String

  public init(previous: String, current: String, message: String) {
    self.previous = previous
    self.current = current
    self.message = message
  }
}

/// The name phones show for the listener page. An empty saved value follows
/// the app name, so a rename becomes "<App name> Broadcast" without a stored
/// string to edit.
public enum BroadcastTitle {
  public static let fallbackAppName = "RoomCast"
  public static let maximumLength = 80

  public static func resolved(stored: String, appName: String) -> String {
    let custom = sanitize(stored)
    if !custom.isEmpty { return custom }
    let name = sanitize(appName)
    let base = name.isEmpty ? fallbackAppName : name
    return "\(base) Broadcast"
  }

  /// Drops control characters and trims. Used when a saved value is repaired
  /// and when the listener URL is built.
  public static func sanitize(_ raw: String) -> String {
    var collapsed = ""
    var pendingSpace = false
    for character in raw {
      let blocked = character.unicodeScalars.contains { scalar in
        scalar.value < 32 || scalar.value == 127
      }
      if blocked || character.isNewline || character.isWhitespace {
        pendingSpace = !collapsed.isEmpty
        continue
      }
      if pendingSpace {
        collapsed.append(" ")
        pendingSpace = false
      }
      collapsed.append(character)
      if collapsed.count >= maximumLength { break }
    }
    return collapsed
  }

  /// Length cap for the Settings field. Spaces the user just typed are kept.
  public static func limited(_ raw: String) -> String {
    var result = ""
    for character in raw {
      let blocked = character.unicodeScalars.contains { scalar in
        scalar.value < 32 || scalar.value == 127
      }
      if blocked { continue }
      result.append(character)
      if result.count >= maximumLength { break }
    }
    return result
  }
}

public enum ListenerLink {
  /// `http://<host>:<port>/`. The broadcast title and the stream name are not
  /// part of the link. The page at `/` reads the title from the app.
  public static func make(
    style: URLStyle,
    ipAddress: String?,
    localHostname: String,
    port: Int
  ) -> String? {
    let host: String
    switch style {
    case .ip:
      guard let ipAddress, !ipAddress.isEmpty else { return nil }
      host = ipAddress
    case .localHostname:
      host = normalizeLocalHostname(localHostname)
    }
    return "http://\(host):\(port)/"
  }

  /// Host and port, ignoring path and `?title=`. An old poster that still
  /// says `/live` is the same listener as `/`.
  public static func endpoint(_ urlString: String) -> String? {
    guard let components = URLComponents(string: urlString),
      let host = components.host?.lowercased(), !host.isEmpty,
      let port = components.port
    else { return nil }
    return "\(host):\(port)"
  }

  /// Address checks ignore the page title, so renaming the broadcast does
  /// not tell the organiser to reprint.
  public static func withoutTitleQuery(_ urlString: String) -> String {
    guard var components = URLComponents(string: urlString) else { return urlString }
    let kept = components.queryItems?.filter { $0.name != "title" } ?? []
    components.queryItems = kept.isEmpty ? nil : kept
    return components.string ?? urlString
  }

  public static func normalizeLocalHostname(_ raw: String) -> String {
    var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while host.hasSuffix(".") {
      host.removeLast()
    }
    if host.isEmpty { return "mac.local" }
    if host.lowercased().hasSuffix(".local") { return host }
    if let dot = host.firstIndex(of: ".") {
      host = String(host[..<dot])
    }
    return host + ".local"
  }

  public static func displayAddress(_ urlString: String) -> String {
    if let host = URL(string: urlString)?.host, !host.isEmpty {
      return host
    }
    return urlString
  }

  public static func staleWarning(previousURL: String?, currentURL: String?) -> StaleAddress? {
    guard let previousURL, !previousURL.isEmpty, let currentURL, !currentURL.isEmpty else {
      return nil
    }
    if let previous = endpoint(previousURL), let current = endpoint(currentURL) {
      if previous == current { return nil }
    } else if withoutTitleQuery(previousURL) == withoutTitleQuery(currentURL) {
      return nil
    }
    let previous = displayAddress(previousURL)
    let current = displayAddress(currentURL)
    let message =
      "Your address changed since the poster was made (was \(previous), now \(current)). Reprint the poster, or set a fixed IP."
    return StaleAddress(previous: previous, current: current, message: message)
  }
}
