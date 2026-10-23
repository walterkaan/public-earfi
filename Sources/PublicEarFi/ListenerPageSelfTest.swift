import Darwin
import Foundation
import PublicEarFiCore

/// Serves one listener page from this .app and exits. Used by the build
/// scripts. It does not open a window.
enum ListenerPageSelfTest {
  static func run() -> Int32 {
    let title = "RoomCast Broadcast"
    let html = ListenerPage.html(title: title)
    if !html.contains("<title>\(title)</title>") {
      return fail("listener page is missing its title")
    }
    if !html.contains("rel=\"icon\"") || !html.contains("data:image/png;base64,") {
      return fail("listener page is missing the favicon")
    }
    if !html.contains("The listener page could not load.") {
      return fail("listener page strings did not load")
    }
    if !html.contains("Powered by RoomCast") || !html.contains("https://roomcast.channel") {
      return fail("listener page is missing the footer")
    }
    if !html.contains("Waiting for the host to start…") || html.contains("location.reload") {
      return fail("listener page is missing the waiting state")
    }
    let server = ListenerHTTPServer(
      port: 0,
      upstreamPort: 9,
      title: title,
      streamName: "live",
      bindAddress: "127.0.0.1"
    )
    do {
      try server.start()
    } catch {
      return fail("listener server did not start: \(error)")
    }
    defer { server.stop() }
    guard let response = fetchHomePage(port: server.boundPort) else {
      return fail("listener page request failed")
    }
    if !response.contains("200") || !response.contains("<title>\(title)</title>") {
      return fail("listener page response was not the broadcast page")
    }
    if !response.contains("data:image/png;base64,") {
      return fail("served listener page is missing the favicon")
    }
    if !response.contains("Powered by RoomCast") {
      return fail("served listener page is missing the footer")
    }
    if !response.contains("Waiting for the host to start…") {
      return fail("served listener page is missing the waiting state")
    }
    fputs("listener page ok\n", stdout)
    return 0
  }

  private static func fail(_ message: String) -> Int32 {
    fputs("\(message)\n", stderr)
    return 1
  }

  private static func fetchHomePage(port: Int) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)
    var noSignal: Int32 = 1
    _ = setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return nil }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected != 0 { return nil }
    let request = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
    guard writeAll(fd, request) else { return nil }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while body.count < 2_000_000 {
      let count = recv(fd, &buffer, buffer.count, 0)
      if count < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if count == 0 { break }
      body.append(buffer, count: count)
    }
    return String(data: body, encoding: .utf8)
  }

  private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
      var sent = 0
      while sent < raw.count {
        let count = send(fd, base.advanced(by: sent), raw.count - sent, 0)
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        if count == 0 { return false }
        sent += count
      }
      return true
    }
  }
}
