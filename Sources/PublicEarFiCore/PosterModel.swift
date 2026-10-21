import Foundation

public enum PaperSize: String, Codable, CaseIterable, Equatable {
  case a4
  case letter

  public var widthPoints: Double {
    switch self {
    case .a4: return 595
    case .letter: return 612
    }
  }

  public var heightPoints: Double {
    switch self {
    case .a4: return 842
    case .letter: return 792
    }
  }

  public var label: String {
    switch self {
    case .a4: return "A4"
    case .letter: return "Letter"
    }
  }

  public static func preferred(regionCode: String?, measurementSystemIsUS: Bool = false)
    -> PaperSize
  {
    switch regionCode?.uppercased() {
    case "US", "CA":
      return .letter
    case nil, "":
      return measurementSystemIsUS ? .letter : .a4
    default:
      return .a4
    }
  }
}

public enum WiFiSecurity: String, Codable, CaseIterable, Equatable {
  case wpa
  case wep
  case none

  /// Token used by the standard WIFI: QR payload. Open networks are `nopass`.
  public var qrType: String {
    switch self {
    case .wpa: return "WPA"
    case .wep: return "WEP"
    case .none: return "nopass"
    }
  }

  public var menuLabel: String {
    switch self {
    case .wpa: return "WPA/WPA2/WPA3"
    case .wep: return "WEP"
    case .none: return "None"
    }
  }
}

public enum WiFiQRCode {
  /// Escapes `\ ; , : "` the way a WIFI: QR payload requires.
  public static func escape(_ value: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(value.count)
    for character in value {
      switch character {
      case "\\", ";", ",", ":", "\"":
        escaped.append("\\")
        escaped.append(character)
      default:
        escaped.append(character)
      }
    }
    return escaped
  }

  /// `WIFI:T:<type>;S:<ssid>;P:<password>;H:<true|false>;;`
  /// An open network sends an empty password even if one was typed.
  public static func payload(
    ssid: String, password: String, security: WiFiSecurity, hidden: Bool
  ) -> String {
    let secret = security == .none ? "" : password
    let hiddenFlag = hidden ? "true" : "false"
    return
      "WIFI:T:\(security.qrType);S:\(escape(ssid));P:\(escape(secret));H:\(hiddenFlag);;"
  }
}

public struct QuickPosterPlan: Equatable {
  public struct Code: Equatable {
    public var label: String
    public var payload: String
    public var lines: [String]

    public init(label: String, payload: String, lines: [String]) {
      self.label = label
      self.payload = payload
      self.lines = lines
    }
  }

  public var steps: [String]
  public var codes: [Code]
  public var closing: String

  public init(steps: [String], codes: [Code], closing: String) {
    self.steps = steps
    self.codes = codes
    self.closing = closing
  }

  /// True when the page leads with a Wi-Fi join code, then the listener code.
  public var includesWiFiCode: Bool {
    codes.count > 1
  }
}

public enum PosterBuilder {
  public static let footer = "Public EarFi: free and open source"
  public static let poweredBy = "Powered by Public EarFi"
  public static let joinWiFi = "Join the Wi-Fi"
  public static let openBroadcast = "Open the broadcast"
  public static let tapPlay = "Tap play; use your own earphones"
  public static let defaultHeader = "Listen live on your phone"
  public static let defaultInstructions = """
    Join the Wi-Fi network {network}
    Scan the QR code or type the address below.
    Tap ▶ to start, and keep your screen on (locking may pause audio).
    No sound? Tap the speaker/mute icon on the player or in your browser tab, and turn up your phone volume.
    """

  public static func steps(instructions: String, show: Bool, networkName: String) -> [String] {
    guard show else { return [] }
    let network = networkName.trimmingCharacters(in: .whitespacesAndNewlines)
    var result: [String] = []
    for raw in instructions.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if network.isEmpty && line.contains("{network}") { continue }
      result.append(line.replacingOccurrences(of: "{network}", with: network))
    }
    return result
  }

  /// The three steps on the main-window poster. An unknown network name
  /// leaves a line to write in by hand.
  public static func quickSteps(networkName: String) -> [String] {
    let network = networkName.trimmingCharacters(in: .whitespacesAndNewlines)
    let join =
      network.isEmpty
      ? "Join Wi-Fi ____________________"
      : "Join Wi-Fi \(network)"
    return [
      join,
      "Scan the QR code with your phone camera",
      "Tap play; use your own earphones",
    ]
  }

  /// Main-window poster. A network name adds a Wi-Fi join code before the
  /// listener code. The password is printed on that page and is not stored here.
  public static func quickPlan(
    networkName: String,
    password: String,
    security: WiFiSecurity,
    hidden: Bool,
    listenerURL: String
  ) -> QuickPosterPlan {
    let network = networkName.trimmingCharacters(in: .whitespacesAndNewlines)
    if network.isEmpty {
      return QuickPosterPlan(
        steps: quickSteps(networkName: ""),
        codes: [
          QuickPosterPlan.Code(label: "", payload: listenerURL, lines: [listenerURL])
        ],
        closing: ""
      )
    }
    var networkLines = [network]
    if security == .none {
      networkLines.append("No password")
    } else if password.isEmpty {
      networkLines.append("Password:")
    } else {
      networkLines.append("Password: \(password)")
    }
    if hidden {
      networkLines.append("Hidden network")
    }
    return QuickPosterPlan(
      steps: [],
      codes: [
        QuickPosterPlan.Code(
          label: "1. \(joinWiFi)",
          payload: WiFiQRCode.payload(
            ssid: network, password: password, security: security, hidden: hidden),
          lines: networkLines
        ),
        QuickPosterPlan.Code(
          label: "2. \(openBroadcast)",
          payload: listenerURL,
          lines: [listenerURL]
        ),
      ],
      closing: "3. \(tapPlay)"
    )
  }
}
