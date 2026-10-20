import Darwin
import Foundation
import PublicEarFiCore

/// Sees whether MediaMTX's ports are free, and names the process that holds
/// one. A bundled helper can be stopped from the window. Anything else is
/// left running.
enum PortProbe {
  static func conflict(settings: AppSettings, helperPaths: [String]) -> PortConflict? {
    for watched in WatchedPorts.all(settings: settings) {
      let tcpBusy =
        watched.tcp && tcpInUse(port: watched.port, localhostOnly: watched.localhostOnly)
      let udpBusy =
        watched.udp && udpInUse(port: watched.port, localhostOnly: watched.localhostOnly)
      guard tcpBusy || udpBusy else { continue }
      return describe(
        port: watched.port,
        changeable: watched.changeable,
        tcp: tcpBusy,
        helperPaths: helperPaths
      )
    }
    return nil
  }

  private static func describe(
    port: Int,
    changeable: Bool,
    tcp: Bool,
    helperPaths: [String]
  ) -> PortConflict {
    let listed = LsofText.records(from: lsof(port: port, tcp: tcp))
    let match = listed.first { record in
      record.names.contains { LsofText.matches(name: $0, port: port) }
    }
    let path = match.flatMap { ProcessPath.executablePath(pid: $0.pid) }
    let ours = HelperIdentity.isBundledHelper(executablePath: path, knownHelperPaths: helperPaths)
    let processName = displayName(path: path, command: match?.command)
    let pid = match?.pid
    let message = PortConflictText.message(
      port: port,
      processName: processName,
      pid: pid,
      changeable: changeable,
      ours: ours
    )
    let stray: StrayHelper?
    if ours, let pid, let path, let processName, pid > 1 {
      stray = StrayHelper(pid: pid, processName: processName, executablePath: path, port: port)
    } else {
      stray = nil
    }
    return PortConflict(port: port, message: message, stray: stray)
  }

  private static func displayName(path: String?, command: String?) -> String? {
    if let path, !path.isEmpty {
      let base = URL(fileURLWithPath: path).lastPathComponent
      if !base.isEmpty { return base }
    }
    let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func tcpInUse(port: Int, localhostOnly: Bool) -> Bool {
    if localhostOnly {
      return bindFails(port: port, tcp: true, ipv6: false, localhost: true)
    }
    return bindFails(port: port, tcp: true, ipv6: false, localhost: false)
      || bindFails(port: port, tcp: true, ipv6: true, localhost: false)
  }

  private static func udpInUse(port: Int, localhostOnly: Bool) -> Bool {
    if localhostOnly {
      return bindFails(port: port, tcp: false, ipv6: false, localhost: true)
    }
    return bindFails(port: port, tcp: false, ipv6: false, localhost: false)
      || bindFails(port: port, tcp: false, ipv6: true, localhost: false)
  }

  /// True only when the address is already taken. Other errors are ignored
  /// so a check we cannot run does not block Start.
  private static func bindFails(port: Int, tcp: Bool, ipv6: Bool, localhost: Bool) -> Bool {
    let family: Int32 = ipv6 ? AF_INET6 : AF_INET
    let kind: Int32 = tcp ? SOCK_STREAM : SOCK_DGRAM
    let descriptor = socket(family, kind, 0)
    guard descriptor >= 0 else { return false }
    defer { _ = Darwin.close(descriptor) }
    if ipv6 {
      var only: Int32 = 1
      _ = setsockopt(
        descriptor,
        IPPROTO_IPV6,
        IPV6_V6ONLY,
        &only,
        socklen_t(MemoryLayout<Int32>.size)
      )
    }
    let result: Int32
    if ipv6 {
      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = in_port_t(UInt16(port)).bigEndian
      if localhost {
        address.sin6_addr = in6addr_loopback
      }
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
      }
    } else {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = in_port_t(UInt16(port)).bigEndian
      if localhost {
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
      }
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    return result != 0 && errno == EADDRINUSE
  }

  private static func lsof(port: Int, tcp: Bool) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    if tcp {
      process.arguments = ["-nP", "-Fpcn", "-iTCP:\(port)", "-sTCP:LISTEN"]
    } else {
      process.arguments = ["-nP", "-Fpcn", "-iUDP:\(port)"]
    }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return ""
    }
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      return ""
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
  }
}

enum ProcessPath {
  static func executablePath(pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: 4 * 1024)
    let length = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
      guard let base = pointer.baseAddress else { return 0 }
      return earfiProcPidPath(pid, base, UInt32(pointer.count))
    }
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }
}

@_silgen_name("proc_pidpath")
private func earfiProcPidPath(
  _ pid: Int32, _ buffer: UnsafeMutablePointer<UInt8>, _ buffersize: UInt32
) -> Int32
