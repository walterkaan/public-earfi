import Foundation

public struct WatchedPort: Equatable {
  public var port: Int
  public var changeable: Bool
  public var tcp: Bool
  public var udp: Bool
  public var localhostOnly: Bool

  public init(port: Int, changeable: Bool, tcp: Bool, udp: Bool, localhostOnly: Bool) {
    self.port = port
    self.changeable = changeable
    self.tcp = tcp
    self.udp = udp
    self.localhostOnly = localhostOnly
  }
}

public enum BindCheck {
  /// TCP probes set SO_REUSEADDR. A listener that has just exited leaves the
  /// port in TIME_WAIT, and without this flag bind reports it as busy for
  /// half a minute. An active listener still fails the bind. UDP must not
  /// set the flag: on macOS it would hide a live ICE socket on 8189.
  public static func reuseAddress(tcp: Bool) -> Bool {
    tcp
  }
}

public enum WatchedPorts {
  public static let rtsp = 8554
  public static let api = 9997

  /// Listener, ICE, RTSP, and the local API. RTSP and the API are fixed.
  public static func all(settings: AppSettings) -> [WatchedPort] {
    let iceTCP: Bool
    let iceUDP: Bool
    switch settings.networkMode {
    case .auto:
      iceTCP = true
      iceUDP = true
    case .tcpOnly:
      iceTCP = true
      iceUDP = false
    case .udpOnly:
      iceTCP = false
      iceUDP = true
    }
    return [
      WatchedPort(
        port: settings.listenerPort, changeable: true, tcp: true, udp: false, localhostOnly: false),
      WatchedPort(
        port: settings.icePort, changeable: true, tcp: iceTCP, udp: iceUDP, localhostOnly: false),
      WatchedPort(port: rtsp, changeable: false, tcp: true, udp: false, localhostOnly: true),
      WatchedPort(port: api, changeable: false, tcp: true, udp: false, localhostOnly: true),
    ]
  }
}

public struct StrayHelper: Equatable {
  public var pid: Int32
  public var processName: String
  public var executablePath: String
  public var port: Int

  public init(pid: Int32, processName: String, executablePath: String, port: Int) {
    self.pid = pid
    self.processName = processName
    self.executablePath = executablePath
    self.port = port
  }
}

public struct PortConflict: Equatable {
  public var port: Int
  public var message: String
  public var stray: StrayHelper?

  public init(port: Int, message: String, stray: StrayHelper?) {
    self.port = port
    self.message = message
    self.stray = stray
  }
}

public enum PortConflictText {
  public static func message(
    port: Int,
    processName: String?,
    pid: Int32?,
    changeable: Bool,
    ours: Bool
  ) -> String {
    if ours, let processName, let pid {
      return
        "port \(port) is in use by a leftover \(processName) (pid \(pid)). Stop it, then press Start again."
    }
    if let processName, let pid {
      let who = "\(processName) (pid \(pid))"
      if changeable {
        return "port \(port) is in use by \(who). Quit that app, or change the port in Settings."
      }
      return "port \(port) is in use by \(who). Quit that app."
    }
    if changeable {
      return "port \(port) is in use. Quit the other app, or change the port in Settings."
    }
    return "port \(port) is in use. Quit the other app."
  }

  public static func fromLog(_ text: String, listenerPort: Int, icePort: Int) -> PortConflict {
    let port = BindFailure.mentionedPort(text) ?? listenerPort
    let changeable = port == listenerPort || port == icePort
    return PortConflict(
      port: port,
      message: message(port: port, processName: nil, pid: nil, changeable: changeable, ours: false),
      stray: nil
    )
  }
}

public enum BindFailure {
  public static func isAddressInUse(_ text: String) -> Bool {
    text.lowercased().contains("address already in use")
  }

  /// The port in a line such as `listen tcp :8889: bind: address already in use`.
  public static func mentionedPort(_ text: String) -> Int? {
    for line in text.split(whereSeparator: \.isNewline) {
      let row = String(line)
      if isAddressInUse(row), let port = firstPort(in: row) {
        return port
      }
    }
    guard isAddressInUse(text) else { return nil }
    return firstPort(in: text)
  }

  private static func firstPort(in text: String) -> Int? {
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      if characters[index] == ":" {
        var end = index + 1
        var digits = ""
        while end < characters.count, characters[end].isNumber {
          digits.append(characters[end])
          end += 1
        }
        if let value = Int(digits), (1...65_535).contains(value), !digits.isEmpty {
          return value
        }
        index = end
      } else {
        index += 1
      }
    }
    return nil
  }
}

public enum RestartPolicy {
  public static func retries(detail: String, logExcerpt: String) -> Bool {
    !BindFailure.isAddressInUse(detail) && !BindFailure.isAddressInUse(logExcerpt)
  }
}

public struct LsofRecord: Equatable {
  public var pid: Int32
  public var command: String
  public var names: [String]

  public init(pid: Int32, command: String, names: [String]) {
    self.pid = pid
    self.command = command
    self.names = names
  }
}

public enum LsofText {
  public static func records(from text: String) -> [LsofRecord] {
    var records: [LsofRecord] = []
    var current: LsofRecord?
    func flush() {
      if let current, current.pid > 0 {
        records.append(current)
      }
    }
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = String(raw)
      guard let kind = line.first else { continue }
      let value = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
      switch kind {
      case "p":
        flush()
        current = LsofRecord(pid: Int32(value) ?? -1, command: "", names: [])
      case "c":
        current?.command = value
      case "n":
        current?.names.append(value)
      default:
        break
      }
    }
    flush()
    return records
  }

  /// True when the local side of an lsof name is this port.
  public static func matches(name: String, port: Int) -> Bool {
    let local = name.split(separator: "->", maxSplits: 1).first.map(String.init) ?? name
    let trimmed = local.trimmingCharacters(in: .whitespaces)
    guard let colon = trimmed.lastIndex(of: ":") else { return false }
    let suffix = trimmed[trimmed.index(after: colon)...]
    let digits = suffix.prefix { $0.isNumber }
    return String(digits) == String(port)
  }
}

public enum HelperIdentity {
  /// True for this app's mediamtx or ffmpeg, including an older copy still
  /// inside Public EarFi.app. A Homebrew or hand-run mediamtx is not ours.
  public static func isBundledHelper(executablePath: String?, knownHelperPaths: [String] = [])
    -> Bool
  {
    guard let executablePath, !executablePath.isEmpty else { return false }
    let standard = standardize(executablePath)
    if knownHelperPaths.contains(where: { standardize($0) == standard }) {
      return true
    }
    let parts = standard.split(separator: "/").map(String.init)
    guard
      let appIndex = parts.lastIndex(where: {
        $0.caseInsensitiveCompare("Public EarFi.app") == .orderedSame
      })
    else { return false }
    let rest = Array(parts[(appIndex + 1)...])
    guard rest.count == 3 else { return false }
    guard rest[0].caseInsensitiveCompare("Contents") == .orderedSame,
      rest[1].caseInsensitiveCompare("Helpers") == .orderedSame
    else { return false }
    let tool = rest[2].lowercased()
    return tool == "mediamtx" || tool == "ffmpeg"
  }

  private static func standardize(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
