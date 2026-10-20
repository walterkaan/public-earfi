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

public enum PosterBuilder {
  public static let footer = "Public EarFi: free and open source"
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
}
