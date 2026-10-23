import Foundation

public struct PathSnapshot: Equatable {
  public var ready: Bool
  public var bytesReceived: UInt64
  public var bytesSent: UInt64
  public var webrtcListeners: Int

  public init(ready: Bool, bytesReceived: UInt64, bytesSent: UInt64, webrtcListeners: Int) {
    self.ready = ready
    self.bytesReceived = bytesReceived
    self.bytesSent = bytesSent
    self.webrtcListeners = webrtcListeners
  }
}

public enum MediaMTXParseError: Error, Equatable {
  case notAnObject
}

public enum MediaMTXAPI {
  public static let pathListPath = "/v3/paths/list"
  public static let webrtcSessionsPath = "/v3/webrtc/sessions/list"

  public static func pathGetPath(streamName: String) -> String {
    "/v3/paths/get/\(streamName)"
  }

  public static func parsePath(_ data: Data) throws -> PathSnapshot {
    let json = try JSONSerialization.jsonObject(with: data)
    guard let object = json as? [String: Any] else { throw MediaMTXParseError.notAnObject }
    return snapshot(from: object)
  }

  public static func parseWebRTCSessionCount(_ data: Data) -> Int? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if let items = object["items"] as? [Any] { return items.count }
    return nil
  }

  private static func snapshot(from object: [String: Any]) -> PathSnapshot {
    let ready = (object["ready"] as? Bool) == true || (object["online"] as? Bool) == true
    let readers = object["readers"] as? [[String: Any]] ?? []
    let listeners = readers.filter { ($0["type"] as? String) == "webRTCSession" }.count
    return PathSnapshot(
      ready: ready,
      bytesReceived: integer(object["inboundBytes"]) ?? integer(object["bytesReceived"]) ?? 0,
      bytesSent: integer(object["outboundBytes"]) ?? integer(object["bytesSent"]) ?? 0,
      webrtcListeners: listeners
    )
  }

  private static func integer(_ value: Any?) -> UInt64? {
    switch value {
    case let number as UInt64:
      return number
    case let number as Int:
      return number >= 0 ? UInt64(number) : nil
    case let number as NSNumber:
      return number.uint64Value
    default:
      return nil
    }
  }
}
