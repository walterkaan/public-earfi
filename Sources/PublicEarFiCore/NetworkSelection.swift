import Foundation

public enum InterfaceKind: Int, Codable, Equatable {
  case ethernet = 0
  case wifi = 1
  case other = 2
}

public struct NetworkCandidate: Equatable, Identifiable {
  public var name: String
  public var address: String
  public var kind: InterfaceKind
  public var isUp: Bool

  public var id: String { "\(name)/\(address)" }

  public init(name: String, address: String, kind: InterfaceKind, isUp: Bool) {
    self.name = name
    self.address = address
    self.kind = kind
    self.isUp = isUp
  }
}

public enum NetworkSelection {
  public static func isExcluded(name: String, address: String) -> Bool {
    if name == "lo" || name.hasPrefix("lo") { return true }
    if name.hasPrefix("utun") || name.hasPrefix("bridge") { return true }
    if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("ap") { return true }
    if name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("gif")
      || name.hasPrefix("stf")
    {
      return true
    }
    if address.hasPrefix("127.") || address.hasPrefix("169.254.") { return true }
    return false
  }

  public static func isIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      guard let number = Int(part), (0...255).contains(number), !part.isEmpty else { return false }
      return true
    }
  }

  public static func isEligible(_ candidate: NetworkCandidate) -> Bool {
    candidate.isUp
      && candidate.name.hasPrefix("en")
      && !isExcluded(name: candidate.name, address: candidate.address)
      && isIPv4(candidate.address)
  }

  public static func ranked(_ candidates: [NetworkCandidate]) -> [NetworkCandidate] {
    candidates.filter(isEligible).sorted { lhs, rhs in
      if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.address < rhs.address
    }
  }

  public static func best(_ candidates: [NetworkCandidate]) -> NetworkCandidate? {
    ranked(candidates).first
  }
}
