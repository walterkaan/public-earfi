import XCTest

@testable import PublicEarFiCore

final class RoomCastAPITests: XCTestCase {
  func testEndpointsUseTheSingleBase() {
    XCTAssertEqual(RoomCastAPI.base, "https://roomcast.channel")
    XCTAssertEqual(
      RoomCastAPI.installURL.absoluteString, "https://roomcast.channel/api/roomcast/install")
    XCTAssertEqual(
      RoomCastAPI.runURL.absoluteString, "https://roomcast.channel/api/roomcast/run")
    XCTAssertEqual(
      RoomCastAPI.latestMacURL.absoluteString,
      "https://roomcast.channel/roomcast/mac/latest.json")
  }

  func testInstallAndRunPayloadsMatchTheContract() throws {
    let serial = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    let longApp = String(repeating: "a", count: 40)
    let longOS = String(repeating: "o", count: 80)
    let install = try XCTUnwrap(
      UsagePayload.installJSON(
        serial: serial,
        installedAt: "2026-11-19T19:20:00Z",
        appVersion: longApp,
        osVersion: longOS
      ))
    XCTAssertLessThanOrEqual(install.count, UsagePayload.maxBodyBytes)
    XCTAssertEqual(
      try strings(install),
      [
        "app_version": String(repeating: "a", count: 32),
        "installed_at": "2026-11-19T19:20:00Z",
        "os_version": String(repeating: "o", count: 64),
        "serial": serial,
      ])
    XCTAssertEqual(Set(try strings(install).keys), ["serial", "installed_at", "app_version", "os_version"])

    let run = try XCTUnwrap(
      UsagePayload.runJSON(serial: serial, ranAt: "2026-11-19T20:00:00Z", appVersion: longApp)
    )
    XCTAssertLessThanOrEqual(run.count, UsagePayload.maxBodyBytes)
    XCTAssertEqual(
      try strings(run),
      [
        "app_version": String(repeating: "a", count: 32),
        "ran_at": "2026-11-19T20:00:00Z",
        "serial": serial,
      ])
    XCTAssertEqual(Set(try strings(run).keys), ["serial", "ran_at", "app_version"])
    XCTAssertNil(
      UsagePayload.installJSON(
        serial: "not-a-uuid",
        installedAt: "2026-11-19T19:20:00Z",
        appVersion: "1.0.2",
        osVersion: "15.1.0"))
    XCTAssertNil(
      UsagePayload.runJSON(
        serial: serial, ranAt: "2026-11-19T19:20:00+00:00", appVersion: "1.0.2"))
  }

  func testSerialIsCreatedOnceAndSurvivesASettingsReset() {
    let suite = "roomcast-telemetry-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = UsageIdentityStore(defaults: defaults)
    let now = Date(timeIntervalSince1970: 1_763_577_600)
    let serial = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    var issued = 0
    let first = store.loadOrCreate(now: now) {
      issued += 1
      return serial
    }
    let later = store.loadOrCreate(now: now.addingTimeInterval(3600)) {
      issued += 1
      return "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    }
    XCTAssertEqual(issued, 1)
    XCTAssertEqual(first.serial, serial)
    XCTAssertEqual(first.serial.count, 36)
    XCTAssertTrue(UsagePayload.isInstallationSerial(first.serial))
    XCTAssertEqual(later.serial, serial)
    XCTAssertEqual(first.installedAt, RoomCastTime.iso8601(now))
    XCTAssertTrue(first.installedAt.hasSuffix("Z"))
    XCTAssertTrue(RoomCastTime.isUTCTimestamp(first.installedAt))
    XCTAssertEqual(later.installedAt, first.installedAt)
    XCTAssertFalse(later.installAcknowledged)

    store.markInstallAcknowledged()
    XCTAssertTrue(store.loadOrCreate(now: now).installAcknowledged)

    defaults.removeObject(forKey: SettingsStore.storageKey)
    let kept = store.loadOrCreate(now: now) { "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC" }
    XCTAssertEqual(kept.serial, serial)
    XCTAssertTrue(kept.installAcknowledged)

    defaults.set("not-a-uuid", forKey: UsageIdentityStore.serialKey)
    defaults.set("2026-11-19T19:20:00+00:00", forKey: UsageIdentityStore.installedAtKey)
    let repaired = store.loadOrCreate(now: now) { "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD" }
    XCTAssertEqual(repaired.serial, "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    XCTAssertFalse(repaired.installAcknowledged)
    XCTAssertTrue(RoomCastTime.isUTCTimestamp(repaired.installedAt))
    XCTAssertEqual(repaired.installedAt, RoomCastTime.iso8601(now))
  }

  func testPostOutcomesAndAnonymousUpdateRequest() throws {
    XCTAssertEqual(UsagePostOutcome(statusCode: 200), .registered)
    XCTAssertEqual(UsagePostOutcome(statusCode: 204), .registered)
    XCTAssertEqual(UsagePostOutcome(statusCode: 400), .rejected)
    XCTAssertEqual(UsagePostOutcome(statusCode: 413), .rejected)
    XCTAssertEqual(UsagePostOutcome(statusCode: 415), .rejected)
    XCTAssertEqual(UsagePostOutcome(statusCode: 429), .throttled)
    XCTAssertEqual(UsagePostOutcome(statusCode: 503), .retryLater)
    XCTAssertEqual(UsagePostOutcome(statusCode: nil), .retryLater)
    XCTAssertEqual(UsagePostOutcome(statusCode: 500), .retryLater)

    let serial = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    let body = try XCTUnwrap(
      UsagePayload.runJSON(serial: serial, ranAt: "2026-11-19T19:20:00Z", appVersion: "1.0.2"))
    let post = try XCTUnwrap(RoomCastRequest.post(url: RoomCastAPI.runURL, body: body))
    XCTAssertEqual(post.httpMethod, "POST")
    XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(
      Set(post.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []), ["content-type"])
    XCTAssertNil(post.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(post.value(forHTTPHeaderField: "User-Agent"))
    XCTAssertFalse(post.httpShouldHandleCookies)
    XCTAssertNil(RoomCastRequest.post(url: RoomCastAPI.runURL, body: Data(count: 2049)))

    let update = RoomCastRequest.updateCheck(url: RoomCastAPI.latestMacURL)
    XCTAssertEqual(update.httpMethod, "GET")
    XCTAssertEqual(update.url, RoomCastAPI.latestMacURL)
    XCTAssertNil(update.url?.query)
    XCTAssertFalse(update.url?.absoluteString.contains(serial) ?? true)
    XCTAssertNil(update.httpBody)
    XCTAssertFalse(update.httpShouldHandleCookies)
    XCTAssertTrue(update.allHTTPHeaderFields?.isEmpty ?? true)
    XCTAssertNil(update.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(update.value(forHTTPHeaderField: "Content-Type"))
  }

  func testVersionsCompareNumerically() {
    XCTAssertEqual(SemanticVersion.compare("1.0.2", "1.0.3"), .orderedAscending)
    XCTAssertEqual(SemanticVersion.compare("1.0.10", "1.0.9"), .orderedDescending)
    XCTAssertEqual(SemanticVersion.compare("1.2.0", "1.1.9"), .orderedDescending)
    XCTAssertEqual(SemanticVersion.compare("1.0", "1.0.0"), .orderedSame)
    XCTAssertEqual(SemanticVersion.compare("v1.4.0", "1.4"), .orderedSame)
    XCTAssertNil(SemanticVersion.compare("1.0.beta", "1.0.1"))
  }

  func testLatestJSONDecidesUpToDateOrAvailable() throws {
    let payload = Data(
      """
      {"version":"1.0.3","build":"42","url":"https://roomcast.channel/roomcast.dmg","notes":"Fixes pause.","min_os":"14.0"}
      """.utf8)
    XCTAssertEqual(
      UpdateVerdict.decide(current: "1.0.3", osVersion: "15.1.0", payload: payload),
      .upToDate(version: "1.0.3"))
    XCTAssertEqual(
      UpdateVerdict.decide(current: "1.0.10", osVersion: "15.0.0", payload: payload),
      .upToDate(version: "1.0.10"))
    XCTAssertEqual(
      UpdateVerdict.decide(current: "1.0.2", osVersion: "14.0.0", payload: payload),
      .available(version: "1.0.3", notes: "Fixes pause.", url: "https://roomcast.channel/roomcast.dmg", minOS: nil)
    )
    XCTAssertEqual(
      UpdateVerdict.decide(current: "1.0.2", osVersion: "13.6.0", payload: payload),
      .available(
        version: "1.0.3",
        notes: "Fixes pause.",
        url: "https://roomcast.channel/roomcast.dmg",
        minOS: "14.0")
    )
    XCTAssertEqual(
      UpdateVerdict.decide(current: "1.0.2", osVersion: "13.6.0", payload: Data("[]".utf8)),
      .unreadable)
    XCTAssertEqual(
      UpdateVerdict.decide(
        current: "1.0.2",
        osVersion: "14.0.0",
        payload: Data(#"{"version":"1.0.3","url":"javascript:alert(1)"}"#.utf8)),
      .unreadable)
    let release = try XCTUnwrap(MacRelease.parse(payload))
    XCTAssertEqual(release.build, "42")
    XCTAssertEqual(release.minOS, "14.0")

    let live = Data(
      """
      {"version":"1.0.2","build":"2","url":"https://roomcast.channel/RoomCast.dmg","notes":"","min_os":"13.0"}
      """.utf8)
    XCTAssertEqual(
      UpdateVerdict.decide(current: "1.0.2", osVersion: "14.0.0", payload: live),
      .upToDate(version: "1.0.2"))
    XCTAssertEqual(
      UpdateVerdict.decide(current: "1.0.1", osVersion: "12.0.0", payload: live),
      .available(
        version: "1.0.2",
        notes: "",
        url: "https://roomcast.channel/RoomCast.dmg",
        minOS: "13.0")
    )
  }

  func testSharingUsageOffSendsNothingAndKeepsTheSerial() throws {
    let suite = "roomcast-opt-out-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let now = Date(timeIntervalSince1970: 1_763_577_600)
    var sent: [(url: String, body: Data)] = []
    func deliver(
      _ url: URL, _ body: Data, _ completion: @escaping (UsagePostOutcome) -> Void
    ) {
      sent.append((url.absoluteString, body))
      XCTAssertFalse(url.absoluteString.contains("latest.json"))
      completion(.registered)
    }

    UsageDispatch.sendLaunch(
      shareUsage: false, defaults: defaults, appVersion: "1.0.2", osVersion: "15.1.0", now: now,
      post: deliver)
    UsageDispatch.sendLaunch(
      shareUsage: false, defaults: defaults, appVersion: "1.0.2", osVersion: "15.1.0", now: now,
      post: deliver)
    XCTAssertTrue(sent.isEmpty)
    let serial = try XCTUnwrap(defaults.string(forKey: UsageIdentityStore.serialKey))
    XCTAssertTrue(UsagePayload.isInstallationSerial(serial))
    XCTAssertEqual(serial.count, 36)
    XCTAssertFalse(defaults.bool(forKey: UsageIdentityStore.installAcknowledgedKey))
    let installedAt = try XCTUnwrap(defaults.string(forKey: UsageIdentityStore.installedAtKey))
    XCTAssertTrue(RoomCastTime.isUTCTimestamp(installedAt))

    var settings = AppSettings.defaults
    settings.shareUsageStatistics = false
    let store = SettingsStore(userDefaults: defaults)
    store.save(settings)
    XCTAssertFalse(store.load().shareUsageStatistics)
    UsageDispatch.sendLaunch(
      shareUsage: store.load().shareUsageStatistics,
      defaults: defaults,
      appVersion: "1.0.2",
      osVersion: "15.1.0",
      now: now,
      post: deliver)
    XCTAssertTrue(sent.isEmpty)

    settings.shareUsageStatistics = true
    store.save(settings)
    UsageDispatch.sendLaunch(
      shareUsage: store.load().shareUsageStatistics,
      defaults: defaults,
      appVersion: "1.0.2",
      osVersion: "15.1.0",
      now: now,
      post: deliver)
    XCTAssertEqual(
      sent.map(\.url),
      [RoomCastAPI.installURL.absoluteString, RoomCastAPI.runURL.absoluteString])
    let install = try strings(sent[0].body)
    let run = try strings(sent[1].body)
    XCTAssertEqual(install["serial"], serial)
    XCTAssertEqual(run["serial"], serial)
    XCTAssertEqual(install["installed_at"], installedAt)
    XCTAssertEqual(run["ran_at"], RoomCastTime.iso8601(now))
    XCTAssertTrue(defaults.bool(forKey: UsageIdentityStore.installAcknowledgedKey))
    XCTAssertEqual(defaults.string(forKey: UsageIdentityStore.serialKey), serial)
  }

  private func strings(_ data: Data) throws -> [String: String] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
  }
}
