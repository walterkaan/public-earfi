import CoreWLAN
import Darwin
import Foundation
import Network
import PublicEarFiCore
import SystemConfiguration

enum InterfaceEnumerator {
  static func candidates() -> [NetworkCandidate] {
    let wifi = wifiNames()
    return ipv4Interfaces().map { interface in
      let kind: InterfaceKind
      if wifi.contains(interface.name) {
        kind = .wifi
      } else if interface.name.hasPrefix("en") {
        kind = .ethernet
      } else {
        kind = .other
      }
      return NetworkCandidate(
        name: interface.name, address: interface.address, kind: kind, isUp: interface.isUp)
    }
  }

  static func localHostname() -> String {
    if let copied = SCDynamicStoreCopyLocalHostName(nil) {
      let name = copied as String
      if !name.isEmpty {
        return ListenerLink.normalizeLocalHostname(name)
      }
    }
    return ListenerLink.normalizeLocalHostname(ProcessInfo.processInfo.hostName)
  }

  /// Friendly Mac name for "from <host>" on the listener page.
  static func computerName() -> String {
    if let copied = SCDynamicStoreCopyComputerName(nil, nil) as String? {
      let name = copied.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
    }
    let host = localHostname()
    if host.lowercased().hasSuffix(".local") {
      return String(host.dropLast(6))
    }
    return host
  }

  static func currentSSID() -> String? {
    guard let data = CWWiFiClient.shared().interface()?.ssidData() else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func wifiNames() -> Set<String> {
    Set(CWWiFiClient.shared().interfaces()?.compactMap(\.interfaceName) ?? [])
  }

  private static func ipv4Interfaces() -> [(name: String, address: String, isUp: Bool)] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var found: [(name: String, address: String, isUp: Bool)] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = cursor {
      cursor = interface.pointee.ifa_next
      guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(address.pointee.sa_len)
      guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let flags = Int32(interface.pointee.ifa_flags)
      let name = String(cString: interface.pointee.ifa_name)
      found.append((name, String(cString: host), (flags & IFF_UP) != 0))
    }
    return found
  }
}

final class PathWatcher {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "earfi.network")

  func start(_ handler: @escaping () -> Void) {
    monitor.pathUpdateHandler = { _ in handler() }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor.cancel()
  }
}
