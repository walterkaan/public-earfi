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

public enum ListenerLink {
  public static func make(
    style: URLStyle,
    ipAddress: String?,
    localHostname: String,
    port: Int,
    streamName: String
  ) -> String? {
    let host: String
    switch style {
    case .ip:
      guard let ipAddress, !ipAddress.isEmpty else { return nil }
      host = ipAddress
    case .localHostname:
      host = normalizeLocalHostname(localHostname)
    }
    return "http://\(host):\(port)/\(streamName)"
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
    if previousURL == currentURL { return nil }
    let previous = displayAddress(previousURL)
    let current = displayAddress(currentURL)
    let message =
      "Your address changed since the poster was made (was \(previous), now \(current)). Reprint the poster, or set a fixed IP."
    return StaleAddress(previous: previous, current: current, message: message)
  }
}
