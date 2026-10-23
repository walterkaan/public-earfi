import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum ListenerServerError: Error, Equatable {
  case addressInUse
  case failed(String)
}

/// Serves the listener page on the public port and forwards WHEP to MediaMTX
/// on loopback. One request per connection.
public final class ListenerHTTPServer: @unchecked Sendable {
  public private(set) var boundPort: Int

  private let bindAddress: String
  private let upstreamPort: Int
  private let lock = NSLock()
  private var title: String
  private var streamName: String
  private var listenFD: Int32 = -1
  private var running = false
  private let finished = DispatchSemaphore(value: 0)

  public init(
    port: Int,
    upstreamPort: Int,
    title: String,
    streamName: String,
    bindAddress: String = "0.0.0.0"
  ) {
    self.boundPort = port
    self.upstreamPort = upstreamPort
    self.title = title
    self.streamName = streamName
    self.bindAddress = bindAddress
  }

  deinit {
    stop()
  }

  public func update(title: String, streamName: String) {
    lock.lock()
    self.title = title
    self.streamName = streamName
    lock.unlock()
  }

  public func start() throws {
    lock.lock()
    let already = running
    lock.unlock()
    if already { return }

    let fd = openStreamSocket()
    if fd < 0 { throw ListenerServerError.failed(posixMessage("socket")) }
    setCloexec(fd)
    ignoreSigpipe(fd)
    var reuse: Int32 = 1
    _ = setsockopt(
      fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

    var address = sockaddr_in()
    #if os(macOS)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(boundPort).bigEndian)
    if inet_pton(AF_INET, bindAddress, &address.sin_addr) != 1 {
      close(fd)
      throw ListenerServerError.failed("listener address \(bindAddress) is not IPv4")
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if bound != 0 {
      let used = errno == EADDRINUSE
      let message = posixMessage("bind")
      close(fd)
      if used { throw ListenerServerError.addressInUse }
      throw ListenerServerError.failed(message)
    }
    if listen(fd, 64) != 0 {
      let message = posixMessage("listen")
      close(fd)
      throw ListenerServerError.failed(message)
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    if named == 0 {
      boundPort = Int(UInt16(bigEndian: UInt16(actual.sin_port)))
    }

    lock.lock()
    listenFD = fd
    running = true
    lock.unlock()
    Thread.detachNewThread { [self] in
      self.acceptLoop(fd)
      self.finished.signal()
    }
  }

  public func stop() {
    lock.lock()
    let shouldWait = running
    running = false
    let fd = listenFD
    listenFD = -1
    lock.unlock()
    guard shouldWait else { return }
    if fd >= 0 {
      _ = shutdown(fd, Int32(SHUT_RDWR))
      close(fd)
    }
    finished.wait()
  }

  private func snapshot() -> (title: String, streamName: String) {
    lock.lock()
    defer { lock.unlock() }
    return (title, streamName)
  }

  private func acceptLoop(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 { break }
      setCloexec(client)
      ignoreSigpipe(client)
      setTimeouts(client)
      Thread.detachNewThread { [self] in
        self.serve(client)
        close(client)
      }
    }
  }

  private func serve(_ client: Int32) {
    guard let request = readRequest(client) else { return }
    let current = snapshot()
    let action = ListenerPage.action(
      method: request.method, requestTarget: request.target, streamName: current.streamName)
    switch action {
    case .page:
      let body = Data(ListenerPage.html(title: current.title).utf8)
      writeResponse(
        client, status: 200, reason: "OK",
        headers: [
          ("Content-Type", "text/html; charset=utf-8"),
          ("Cache-Control", "no-cache"),
        ],
        body: request.method.uppercased() == "HEAD" ? Data() : body,
        contentLength: body.count
      )
    case .titleJSON:
      let body = Data(ListenerPage.json(title: current.title).utf8)
      writeResponse(
        client, status: 200, reason: "OK",
        headers: [
          ("Content-Type", "application/json; charset=utf-8"),
          ("Cache-Control", "no-cache"),
        ],
        body: request.method.uppercased() == "HEAD" ? Data() : body,
        contentLength: body.count
      )
    case .redirectRoot:
      writeResponse(
        client, status: 302, reason: "Found",
        headers: [("Location", "/"), ("Cache-Control", "no-cache")],
        body: Data(), contentLength: 0
      )
    case .proxy(let path):
      proxy(client, request: request, upstreamPath: path)
    case .notFound:
      let body = Data("Not found".utf8)
      writeResponse(
        client, status: 404, reason: "Not Found",
        headers: [("Content-Type", "text/plain; charset=utf-8")],
        body: body, contentLength: body.count
      )
    }
  }

  private func proxy(_ client: Int32, request: Incoming, upstreamPath: String) {
    let upstream = openStreamSocket()
    if upstream < 0 {
      writeUnavailable(client)
      return
    }
    defer { close(upstream) }
    setCloexec(upstream)
    ignoreSigpipe(upstream)
    setTimeouts(upstream)
    var address = sockaddr_in()
    #if os(macOS)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(upstreamPort).bigEndian)
    if inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) != 1 {
      writeUnavailable(client)
      return
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected != 0 {
      writeUnavailable(client)
      return
    }
    var header = "\(request.method) \(upstreamPath) HTTP/1.0\r\n"
    header += "Host: 127.0.0.1:\(upstreamPort)\r\n"
    header += "Connection: close\r\n"
    for (name, value) in request.headers where shouldForwardRequest(name) {
      header += "\(name): \(value)\r\n"
    }
    header += "Content-Length: \(request.body.count)\r\n\r\n"
    var outbound = Data(header.utf8)
    outbound.append(request.body)
    guard writeAll(upstream, outbound) else {
      writeUnavailable(client)
      return
    }
    guard let response = readResponse(upstream) else {
      writeUnavailable(client)
      return
    }
    var headers: [(String, String)] = []
    for (name, value) in response.headers where shouldForwardResponse(name) {
      headers.append((name, value))
    }
    writeResponse(
      client, status: response.status, reason: response.reason,
      headers: headers, body: response.body, contentLength: response.body.count
    )
  }

  private func writeUnavailable(_ client: Int32) {
    let body = Data("The broadcast is not ready.".utf8)
    writeResponse(
      client, status: 502, reason: "Bad Gateway",
      headers: [("Content-Type", "text/plain; charset=utf-8")],
      body: body, contentLength: body.count
    )
  }

  private func shouldForwardRequest(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower == "content-type" || lower == "if-match" || lower == "authorization"
  }

  private func shouldForwardResponse(_ name: String) -> Bool {
    let lower = name.lowercased()
    switch lower {
    case "connection", "keep-alive", "transfer-encoding", "proxy-connection", "upgrade",
      "content-length":
      return false
    default:
      return true
    }
  }
}

private struct Incoming {
  var method: String
  var target: String
  var headers: [(String, String)]
  var body: Data
}

private struct UpstreamResponse {
  var status: Int
  var reason: String
  var headers: [(String, String)]
  var body: Data
}

private let maxHeaderBytes = 64 * 1024
private let maxBodyBytes = 1_048_576

private func readRequest(_ fd: Int32) -> Incoming? {
  let stream = SocketBytes(fd)
  guard let head = stream.header(), let parsed = parseHead(head) else { return nil }
  let length = contentLength(parsed.headers)
  if length < 0 {
    return Incoming(
      method: parsed.method, target: parsed.target, headers: parsed.headers, body: Data())
  }
  if length > maxBodyBytes { return nil }
  let body = length > 0 ? stream.exact(length) : Data()
  guard body.count == length else { return nil }
  return Incoming(method: parsed.method, target: parsed.target, headers: parsed.headers, body: body)
}

private func readResponse(_ fd: Int32) -> UpstreamResponse? {
  let stream = SocketBytes(fd)
  guard let head = stream.header(), let parsed = parseHead(head) else { return nil }
  let length = contentLength(parsed.headers)
  let body: Data
  if length > 0 {
    if length > maxBodyBytes { return nil }
    body = stream.exact(length)
    if body.count != length { return nil }
  } else if length == 0 {
    body = Data()
  } else {
    body = stream.rest(limit: maxBodyBytes)
  }
  let status = Int(parsed.method) ?? 502
  return UpstreamResponse(
    status: status, reason: parsed.target, headers: parsed.headers, body: body)
}

/// Bytes already pulled from the socket stay here, so a header and its body
/// can arrive in one read.
private final class SocketBytes {
  private let fd: Int32
  private var extra = Data()

  init(_ fd: Int32) {
    self.fd = fd
  }

  func header() -> Data? {
    while extra.count < maxHeaderBytes {
      if let range = extra.range(of: Data("\r\n\r\n".utf8)) {
        let head = extra.subdata(in: 0..<range.lowerBound)
        extra.removeSubrange(0..<range.upperBound)
        return head
      }
      if !pull() { return nil }
    }
    return nil
  }

  func exact(_ length: Int) -> Data {
    while extra.count < length {
      if !pull() { break }
    }
    let count = min(length, extra.count)
    let body = extra.prefix(count)
    extra.removeFirst(count)
    return Data(body)
  }

  func rest(limit: Int) -> Data {
    while extra.count < limit {
      if !pull() { break }
    }
    let body = Data(extra.prefix(limit))
    extra.removeAll()
    return body
  }

  private func pull() -> Bool {
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = recv(fd, &buffer, buffer.count, 0)
      if count < 0 {
        if errno == EINTR { continue }
        return false
      }
      if count == 0 { return false }
      extra.append(buffer, count: count)
      return true
    }
  }
}

/// Request line is `METHOD target HTTP/x`. Status line is `HTTP/x status reason`.
/// `method` holds the status code string for a response, and `target` holds the reason.
private func parseHead(_ head: Data) -> (
  method: String, target: String, headers: [(String, String)]
)? {
  guard let text = String(data: head, encoding: .utf8) else { return nil }
  let lines = text.components(separatedBy: "\r\n")
  guard let first = lines.first else { return nil }
  let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
  guard parts.count >= 2 else { return nil }
  var headers: [(String, String)] = []
  for line in lines.dropFirst() where !line.isEmpty {
    guard let colon = line.firstIndex(of: ":") else { continue }
    let name = String(line[..<colon])
    var value = String(line[line.index(after: colon)...])
    if value.hasPrefix(" ") { value.removeFirst() }
    headers.append((name, value))
  }
  if first.hasPrefix("HTTP/") {
    let status = String(parts[1])
    let reason = parts.count > 2 ? String(parts[2]) : ""
    return (status, reason, headers)
  }
  return (String(parts[0]), String(parts[1]), headers)
}

private func contentLength(_ headers: [(String, String)]) -> Int {
  for (name, value) in headers where name.lowercased() == "content-length" {
    return Int(value) ?? -1
  }
  return -1
}

private func writeResponse(
  _ fd: Int32,
  status: Int,
  reason: String,
  headers: [(String, String)],
  body: Data,
  contentLength: Int
) {
  var text = "HTTP/1.1 \(status) \(reason)\r\n"
  for (name, value) in headers {
    text += "\(name): \(value)\r\n"
  }
  text += "Content-Length: \(contentLength)\r\n"
  text += "Connection: close\r\n\r\n"
  var data = Data(text.utf8)
  if !body.isEmpty { data.append(body) }
  _ = writeAll(fd, data)
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { raw in
    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
    var sent = 0
    while sent < raw.count {
      let count = send(fd, base.advanced(by: sent), raw.count - sent, sendFlags)
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

private var sendFlags: Int32 {
  #if os(Linux)
    return Int32(MSG_NOSIGNAL)
  #else
    return 0
  #endif
}

private func setCloexec(_ fd: Int32) {
  let flags = fcntl(fd, F_GETFD)
  if flags >= 0 {
    _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
  }
}

private func ignoreSigpipe(_ fd: Int32) {
  #if os(macOS)
    var on: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
  #else
    _ = fd
  #endif
}

private func setTimeouts(_ fd: Int32) {
  var timeout = timeval()
  timeout.tv_sec = 5
  timeout.tv_usec = 0
  _ = setsockopt(
    fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
  _ = setsockopt(
    fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
}

func openStreamSocket() -> Int32 {
  #if os(Linux)
    return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
  #else
    return socket(AF_INET, SOCK_STREAM, 0)
  #endif
}

private func posixMessage(_ what: String) -> String {
  "\(what): \(String(cString: strerror(errno)))"
}
