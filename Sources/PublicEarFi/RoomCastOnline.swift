import Foundation
import PublicEarFiCore

enum UpdateCheckPhase: Equatable {
  case idle
  case checking
  case upToDate(String)
  case available(version: String, notes: String, downloadURL: URL, osNote: String?)
  case failed(String)
}

/// Short-lived requests. Failures stay in the completion and never throw.
/// Cookies are off so a Set-Cookie on install cannot identify the update check.
enum RoomCastHTTP {
  static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 6
    config.timeoutIntervalForResource = 8
    config.waitsForConnectivity = false
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.httpCookieStorage = nil
    config.httpAdditionalHeaders = nil
    config.urlCache = nil
    return URLSession(configuration: config)
  }()

  static func post(_ body: Data, to url: URL, completion: @escaping (UsagePostOutcome) -> Void) {
    guard let request = RoomCastRequest.post(url: url, body: body) else {
      completion(.rejected)
      return
    }
    session.dataTask(with: request) { _, response, error in
      if error != nil {
        completion(.retryLater)
        return
      }
      let code = (response as? HTTPURLResponse)?.statusCode
      completion(UsagePostOutcome(statusCode: code))
    }.resume()
  }

  /// Public update feed. The request has no serial, no cookies, and no custom headers.
  static func getUpdateFeed(_ url: URL, completion: @escaping (Data?) -> Void) {
    let request = RoomCastRequest.updateCheck(url: url)
    session.dataTask(with: request) { data, response, error in
      if error != nil {
        completion(nil)
        return
      }
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(code), let data, !data.isEmpty else {
        completion(nil)
        return
      }
      completion(data)
    }.resume()
  }
}

/// Install until the server accepts it or rejects the payload, and one run
/// report per launch. Both posts are background URLSession tasks. Sharing
/// usage off skips both, including a pending install.
enum UsageReporter {
  static func sendLaunch(
    defaults: UserDefaults,
    shareUsage: Bool,
    appVersion: String,
    osVersion: String,
    now: Date = Date()
  ) {
    UsageDispatch.sendLaunch(
      shareUsage: shareUsage,
      defaults: defaults,
      appVersion: appVersion,
      osVersion: osVersion,
      now: now
    ) { url, body, completion in
      RoomCastHTTP.post(body, to: url, completion: completion)
    }
  }
}

enum UpdateChecker {
  static let offlineMessage =
    "Could not check for updates. Check your internet connection and try again."
  static let unreadableMessage = "Could not read the update information. Try again later."

  static func check(
    currentVersion: String, osVersion: String, completion: @escaping (UpdateCheckPhase) -> Void
  ) {
    RoomCastHTTP.getUpdateFeed(RoomCastAPI.latestMacURL) { data in
      guard let data else {
        completion(.failed(offlineMessage))
        return
      }
      switch UpdateVerdict.decide(current: currentVersion, osVersion: osVersion, payload: data) {
      case .upToDate(let version):
        completion(.upToDate(version))
      case .available(let version, let notes, let url, let minOS):
        guard let download = URL(string: url) else {
          completion(.failed(unreadableMessage))
          return
        }
        let osNote = minOS.map { "Requires macOS \($0) or later." }
        completion(
          .available(version: version, notes: notes, downloadURL: download, osNote: osNote))
      case .unreadable:
        completion(.failed(unreadableMessage))
      }
    }
  }
}
