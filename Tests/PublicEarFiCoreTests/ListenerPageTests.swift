import Foundation
import XCTest

@testable import PublicEarFiCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class ListenerPageTests: XCTestCase {
  func testPublicLinkIsTheRootAndTitleStaysOffTheURL() {
    XCTAssertEqual(
      ListenerLink.make(
        style: .ip, ipAddress: "192.168.1.42", localHostname: "Hall-Mac.local", port: 8889),
      "http://192.168.1.42:8889/"
    )
    XCTAssertNil(
      ListenerLink.staleWarning(
        previousURL: "http://192.168.1.40:8889/live?title=Old",
        currentURL: "http://192.168.1.40:8889/"
      )
    )
  }

  func testPageRoutesAndOldLiveLinkRedirectsHome() {
    XCTAssertEqual(
      ListenerPage.action(method: "GET", requestTarget: "/", streamName: "live"), .page)
    XCTAssertEqual(
      ListenerPage.action(method: "GET", requestTarget: "/earfi.json", streamName: "live"),
      .titleJSON)
    XCTAssertEqual(
      ListenerPage.action(method: "GET", requestTarget: "/live", streamName: "live"),
      .redirectRoot)
    XCTAssertEqual(
      ListenerPage.action(method: "GET", requestTarget: "/live/?title=Old", streamName: "live"),
      .redirectRoot)
    XCTAssertEqual(
      ListenerPage.action(method: "GET", requestTarget: "/hall/", streamName: "hall"),
      .redirectRoot)
    XCTAssertEqual(
      ListenerPage.action(method: "GET", requestTarget: "/reader.js", streamName: "live"),
      .proxy(path: "/reader.js"))
    XCTAssertEqual(
      ListenerPage.action(method: "POST", requestTarget: "/whep", streamName: "hall"),
      .proxy(path: "/hall/whep"))
    XCTAssertEqual(
      ListenerPage.action(
        method: "POST", requestTarget: "/live/whep?x=1", streamName: "hall"),
      .proxy(path: "/hall/whep?x=1"))
    XCTAssertEqual(
      ListenerPage.action(
        method: "PATCH", requestTarget: "/whep/abc-123", streamName: "live"),
      .proxy(path: "/live/whep/abc-123"))
    XCTAssertEqual(
      ListenerPage.action(method: "GET", requestTarget: "/other", streamName: "live"),
      .notFound)
    XCTAssertEqual(
      ListenerPage.action(method: "POST", requestTarget: "/live", streamName: "live"),
      .notFound)
  }

  func testPageShowsTheBroadcastTitleInTheTabAndMediaSession() {
    let plain = ListenerPage.html(title: "Public EarFi Broadcast")
    XCTAssertTrue(plain.contains("<title>Public EarFi Broadcast</title>"))
    XCTAssertFalse(plain.contains("playerTitle"))
    XCTAssertFalse(plain.contains("status-label"))
    XCTAssertTrue(plain.contains("title=\"Public EarFi Broadcast\""))
    XCTAssertTrue(plain.contains("new MediaMetadata({title:title})"))
    XCTAssertFalse(plain.contains("get(\"title\")"))
    XCTAssertTrue(plain.contains("new URL(\"/whep\""))

    let awkward = ListenerPage.html(title: "A & B <live>")
    XCTAssertTrue(awkward.contains("<title>A &amp; B &lt;live&gt;</title>"))
    XCTAssertFalse(awkward.contains("playerTitle"))
    XCTAssertFalse(awkward.contains("<live>"))
    XCTAssertTrue(ListenerPage.jsonForScript(title: "A & B <live>").contains("\\u003c"))
    XCTAssertTrue(ListenerPage.json(title: "A & B").contains("\"title\":\"A & B\""))
  }

  func testListenerPageServesRootRedirectsLiveAndProxiesWHEP() throws {
    let upstream = try TestSocketServer()
    upstream.reply = """
      HTTP/1.0 201 Created\r
      Content-Type: application/sdp\r
      Location: /hall/whep/abc\r
      Content-Length: 3\r
      \r
      sdp
      """
    let server = ListenerHTTPServer(
      port: 0,
      upstreamPort: upstream.port,
      title: "Hall A",
      streamName: "hall",
      bindAddress: "127.0.0.1"
    )
    try server.start()
    defer {
      server.stop()
      upstream.stop()
    }

    let page = exchange(port: server.boundPort, request: "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    XCTAssertTrue(page.contains("200"))
    XCTAssertTrue(page.contains("<title>Hall A</title>"))
    XCTAssertFalse(page.contains("playerTitle"))

    let old = exchange(
      port: server.boundPort, request: "GET /live?title=Old HTTP/1.1\r\nHost: x\r\n\r\n")
    XCTAssertTrue(old.contains("302"))
    XCTAssertTrue(old.contains("Location: /"))

    let json = exchange(
      port: server.boundPort, request: "GET /earfi.json HTTP/1.1\r\nHost: x\r\n\r\n")
    XCTAssertTrue(json.contains("{\"title\":\"Hall A\"}"))

    server.update(title: "Hall B", streamName: "hall")
    let renamed = exchange(
      port: server.boundPort, request: "GET /earfi.json HTTP/1.1\r\nHost: x\r\n\r\n")
    XCTAssertTrue(renamed.contains("{\"title\":\"Hall B\"}"))

    let whep = exchange(
      port: server.boundPort,
      request:
        "POST /whep HTTP/1.1\r\nHost: x\r\nContent-Type: application/sdp\r\nContent-Length: 5\r\n\r\nv=0\r\n"
    )
    XCTAssertTrue(whep.contains("201"))
    XCTAssertTrue(whep.contains("Location: /hall/whep/abc"))
    XCTAssertTrue(whep.contains("sdp"))
    XCTAssertTrue(upstream.seen.contains("POST /hall/whep HTTP/1.0"))
    XCTAssertTrue(upstream.seen.contains("v=0"))
  }
}

/// One-connection stand-in for MediaMTX. Records the request and writes `reply`.
private final class TestSocketServer {
  let port: Int
  var reply = "HTTP/1.0 204 No Content\r\nContent-Length: 0\r\n\r\n"
  private(set) var seen = ""
  private let fd: Int32
  private let lock = NSLock()
  private var stopped = false

  init() throws {
    let fd = openStreamSocket()
    if fd < 0 { throw POSIXError(.ECONNREFUSED) }
    self.fd = fd
    var reuse: Int32 = 1
    _ = setsockopt(
      fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if bound != 0 || listen(fd, 8) != 0 {
      close(fd)
      throw POSIXError(.EADDRINUSE)
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    port = Int(UInt16(bigEndian: actual.sin_port))
    Thread.detachNewThread { [self] in
      self.acceptLoop()
    }
  }

  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
    _ = shutdown(fd, Int32(SHUT_RDWR))
    close(fd)
  }

  private func acceptLoop() {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 { break }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while data.count < 65_536 {
        let count = recv(client, &buffer, buffer.count, 0)
        if count <= 0 { break }
        data.append(buffer, count: count)
        if data.range(of: Data("\r\n\r\n".utf8)) != nil {
          let length = contentLength(data)
          let head = data.range(of: Data("\r\n\r\n".utf8))!
          if data.count >= head.upperBound + length { break }
        }
      }
      lock.lock()
      seen += String(data: data, encoding: .utf8) ?? ""
      let body = Data(reply.utf8)
      lock.unlock()
      body.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var sent = 0
        while sent < raw.count {
          let count = send(client, base.advanced(by: sent), raw.count - sent, 0)
          if count <= 0 { break }
          sent += count
        }
      }
      close(client)
    }
  }

  private func contentLength(_ data: Data) -> Int {
    guard let text = String(data: data, encoding: .utf8) else { return 0 }
    for line in text.components(separatedBy: "\r\n") {
      let lower = line.lowercased()
      if lower.hasPrefix("content-length:") {
        return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
          ?? 0
      }
    }
    return 0
  }
}

private func exchange(port: Int, request: String) -> String {
  let fd = openStreamSocket()
  precondition(fd >= 0)
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(UInt16(port).bigEndian)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  precondition(connected == 0)
  let bytes = Data(request.utf8)
  bytes.withUnsafeBytes { raw in
    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
    var sent = 0
    while sent < raw.count {
      let count = send(fd, base.advanced(by: sent), raw.count - sent, 0)
      if count <= 0 { break }
      sent += count
    }
  }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while data.count < 1_000_000 {
    let count = recv(fd, &buffer, buffer.count, 0)
    if count <= 0 { break }
    data.append(buffer, count: count)
  }
  return String(data: data, encoding: .utf8) ?? ""
}
