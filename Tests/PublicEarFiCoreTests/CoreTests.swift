import XCTest

@testable import PublicEarFiCore

final class SettingsTests: XCTestCase {
  func testDefaultsMatchTheSpecTable() {
    let settings = AppSettings.defaults
    XCTAssertNil(settings.inputDeviceUID)
    XCTAssertEqual(settings.channelMode, .mono)
    XCTAssertEqual(settings.inputChannel, 1)
    XCTAssertEqual(settings.inputGainDB, 0)
    XCTAssertEqual(FFmpegCommand.sampleRate, 48_000)
    XCTAssertEqual(settings.quality, .speech)
    XCTAssertEqual(settings.resolvedBitrateKbps, 32)
    XCTAssertEqual(settings.opusApplication, "voip")
    XCTAssertEqual(settings.streamName, "live")
    XCTAssertEqual(settings.listenerPort, 8889)
    XCTAssertEqual(settings.icePort, 8189)
    XCTAssertEqual(settings.networkMode, .auto)
    XCTAssertNil(settings.advertisedAddress)
    XCTAssertEqual(settings.urlStyle, .ip)
    XCTAssertEqual(settings.maxListeners, 0)
    XCTAssertTrue(settings.keepAwake)
    XCTAssertFalse(settings.launchAtLogin)
    XCTAssertFalse(settings.startWhenAppOpens)
    XCTAssertEqual(settings.logLevel, .info)
    XCTAssertEqual(settings.posterHeader, "Listen live on your phone")
    XCTAssertEqual(settings.posterDescription, "")
    XCTAssertTrue(settings.posterShowInstructions)
    XCTAssertTrue(settings.posterInstructions.contains("No sound? Tap the speaker/mute icon"))
    XCTAssertEqual(settings.posterNetworkName, "")
    XCTAssertEqual(settings.posterWiFiSecurity, .wpa)
    XCTAssertFalse(settings.posterWiFiHidden)
    XCTAssertNil(settings.posterPaperSize)
    XCTAssertTrue(settings.posterUseFooter)
    XCTAssertEqual(AppSettings.listenerTarget, 30)
    XCTAssertEqual(settings.bandwidthHint, "30 listeners ≈ 0.96 Mbps")
    XCTAssertTrue(validate(settings).isEmpty)
  }

  func testQualityBitrates() {
    var settings = AppSettings.defaults
    settings.applyPreset(.speech)
    XCTAssertEqual(settings.channelMode, .mono)
    XCTAssertEqual(settings.resolvedBitrateKbps, 32)
    XCTAssertEqual(settings.opusApplication, "voip")
    XCTAssertEqual(AppSettings.listenerTarget, 30)
    XCTAssertEqual(settings.bandwidthHint, "30 listeners ≈ 0.96 Mbps")
    XCTAssertTrue(validate(settings).isEmpty)

    settings.quality = .music
    settings.channelMode = .mono
    XCTAssertEqual(settings.resolvedBitrateKbps, 96)
    settings.channelMode = .stereo
    XCTAssertEqual(settings.resolvedBitrateKbps, 128)
    XCTAssertEqual(formatMbps(settings.estimatedMegabits(listeners: 10)), "1.28")

    settings.quality = .custom
    settings.customBitrateKbps = 16
    XCTAssertEqual(settings.resolvedBitrateKbps, 16)
    settings.customBitrateKbps = 8
    XCTAssertEqual(settings.resolvedBitrateKbps, 16)
    XCTAssertFalse(validate(settings).isEmpty)
  }

  func testStreamNameAndPorts() {
    XCTAssertTrue(isValidStreamName("live"))
    XCTAssertTrue(isValidStreamName("room-2"))
    XCTAssertFalse(isValidStreamName(""))
    XCTAssertFalse(isValidStreamName("Live"))
    XCTAssertFalse(isValidStreamName(String(repeating: "a", count: 33)))

    var settings = AppSettings.defaults
    settings.listenerPort = 80
    settings.streamName = "Live"
    let fields = Set(validate(settings).map(\.field))
    XCTAssertTrue(fields.contains("listenerPort"))
    XCTAssertTrue(fields.contains("streamName"))

    settings = .defaults
    settings.listenerPort = 8554
    XCTAssertTrue(validate(settings).contains { $0.field == "listenerPort" })
  }

  func testResetRestoresDefaultsWithoutTouchingLogs() {
    let suite = "public-earfi-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = SettingsStore(userDefaults: defaults)
    var settings = AppSettings.defaults
    settings.streamName = "hall"
    settings.posterHeader = "Custom"
    settings.posterDescription = "Talk"
    settings.keepAwake = false
    settings.quality = .speech
    store.save(settings)
    store.rememberPoster(url: "http://192.168.1.40:8889/live")
    defaults.set("log-line", forKey: "unrelated.log")

    let reset = store.reset()
    XCTAssertEqual(reset, .defaults)
    XCTAssertEqual(store.load(), .defaults)
    XCTAssertEqual(defaults.string(forKey: "unrelated.log"), "log-line")
    XCTAssertEqual(store.posterStamp()?.url, "http://192.168.1.40:8889/live")
  }

  func testRoundTripKeepsARememberedDevice() {
    let suite = "public-earfi-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = SettingsStore(userDefaults: defaults)
    var settings = AppSettings.defaults
    settings.inputDeviceUID = "AppleUSBAudioEngine:Focusrite:Scarlett"
    settings.posterPaperSize = .letter
    settings.urlStyle = .localHostname
    store.save(settings)
    XCTAssertEqual(store.load(), settings)
  }

  func testBroadcastSignatureIgnoresPosterText() {
    var settings = AppSettings.defaults
    let before = BroadcastSignature(settings)
    settings.posterHeader = "Welcome"
    settings.posterDescription = "Hall"
    settings.keepAwake = false
    settings.inputGainDB = 18
    settings.broadcastTitle = "Hall A"
    XCTAssertEqual(BroadcastSignature(settings), before)
    settings.listenerPort = 8890
    XCTAssertNotEqual(BroadcastSignature(settings), before)
  }

  func testDevicePreferencePicksExternalThenBuiltInThenRemembered() {
    let builtIn = DeviceCandidate(
      uid: "builtin", name: "MacBook Microphone", isBuiltIn: true, inputChannels: 1)
    let scarlett = DeviceCandidate(
      uid: "scarlett", name: "Scarlett 2i2", isBuiltIn: false, inputChannels: 2)
    let outputOnly = DeviceCandidate(uid: "out", name: "HDMI", isBuiltIn: false, inputChannels: 0)
    XCTAssertEqual(
      DeviceSelection.preferred(devices: [builtIn, outputOnly, scarlett], rememberedUID: nil)?.uid,
      "scarlett"
    )
    XCTAssertEqual(
      DeviceSelection.preferred(devices: [builtIn], rememberedUID: nil)?.uid,
      "builtin"
    )
    XCTAssertEqual(
      DeviceSelection.preferred(devices: [builtIn, scarlett], rememberedUID: "builtin")?.uid,
      "builtin"
    )
    XCTAssertNil(DeviceSelection.preferred(devices: [outputOnly], rememberedUID: "missing"))
    XCTAssertTrue(DeviceSelection.isMissing(rememberedUID: "BlackHole2ch_UID", devices: [builtIn]))
    XCTAssertFalse(DeviceSelection.isMissing(rememberedUID: "builtin", devices: [builtIn]))
    XCTAssertFalse(DeviceSelection.isMissing(rememberedUID: nil, devices: [builtIn]))
    XCTAssertFalse(DeviceSelection.isMissing(rememberedUID: "  ", devices: [builtIn]))
    let switching = DeviceCandidate(
      uid: "headset", name: "Headset", isBuiltIn: false, inputChannels: 0)
    XCTAssertFalse(
      DeviceSelection.isMissing(rememberedUID: "headset", devices: [builtIn, switching]))
    XCTAssertEqual(
      DeviceSelection.preferred(devices: [builtIn, switching], rememberedUID: nil)?.uid,
      "builtin"
    )
  }

  func testInvalidSettingsAreRepairedAndPersisted() throws {
    let suite = "public-earfi-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = SettingsStore(userDefaults: defaults)
    var settings = AppSettings.defaults
    settings.listenerPort = 80
    settings.icePort = 8554
    settings.streamName = "Live"
    settings.inputChannel = 0
    settings.inputDeviceUID = "  "
    settings.maxListeners = 900
    settings.customBitrateKbps = 1
    settings.advertisedAddress = "bad host"
    store.save(settings)

    let resolved = store.loadResolved()
    XCTAssertEqual(resolved.settings.listenerPort, 8889)
    XCTAssertEqual(resolved.settings.icePort, 8189)
    XCTAssertEqual(resolved.settings.streamName, "live")
    XCTAssertEqual(resolved.settings.inputChannel, 1)
    XCTAssertNil(resolved.settings.inputDeviceUID)
    XCTAssertEqual(resolved.settings.maxListeners, 0)
    XCTAssertEqual(resolved.settings.customBitrateKbps, 16)
    XCTAssertNil(resolved.settings.advertisedAddress)
    XCTAssertEqual(
      resolved.notice,
      "Saved settings were invalid (device, input channel, bitrate, stream name, listener port, ICE port, max listeners, address) and were reset. Check Settings, then press Start."
    )
    XCTAssertEqual(store.load().listenerPort, 8889)
    XCTAssertEqual(store.load().streamName, "live")
    XCTAssertFalse(SettingsRepair.channelFits(8, inputCount: 2))
    XCTAssertTrue(SettingsRepair.channelFits(2, inputCount: 2))

    defaults.set(Data("{}".utf8), forKey: SettingsStore.storageKey)
    let missingPosterFields = store.load()
    XCTAssertEqual(missingPosterFields.posterWiFiSecurity, .wpa)
    XCTAssertFalse(missingPosterFields.posterWiFiHidden)
    XCTAssertEqual(missingPosterFields.posterNetworkName, "")

    var poster = AppSettings.defaults
    poster.posterNetworkName = "Hall-Guest"
    poster.posterWiFiSecurity = .wep
    poster.posterWiFiHidden = true
    store.save(poster)
    XCTAssertEqual(store.load().posterNetworkName, "Hall-Guest")
    XCTAssertEqual(store.load().posterWiFiSecurity, .wep)
    XCTAssertTrue(store.load().posterWiFiHidden)
    let saved = try XCTUnwrap(JSONEncoder().encode(poster))
    let json = String(decoding: saved, as: UTF8.self)
    XCTAssertFalse(json.contains("password"))
    XCTAssertFalse(json.contains("venue-password"))

    defaults.set(Data([0x00, 0x01, 0xFF]), forKey: SettingsStore.storageKey)
    let unreadable = store.loadResolved()
    XCTAssertEqual(unreadable.settings, .defaults)
    XCTAssertEqual(unreadable.notice, SettingsRepair.unreadableNotice)
    XCTAssertEqual(store.reset(), .defaults)
    XCTAssertEqual(store.load(), .defaults)
  }
}

final class MediaMTXConfigTests: XCTestCase {
  func testAutoConfigMatchesPinnedKeys() throws {
    let yaml = MediaMTXConfigWriter.yaml(settings: .defaults, advertisedHost: "192.168.1.42")
    let allowed = try allowedKeys()
    let used = MediaMTXConfigWriter.topLevelKeys(in: yaml).subtracting([
      AppSettings.defaults.streamName
    ])
    XCTAssertTrue(used.isSubset(of: allowed), "Unknown keys: \(used.subtracting(allowed))")
    XCTAssertTrue(yaml.contains("paths:\n  live:\n    source: publisher\n    maxReaders: 0\n"))
    XCTAssertTrue(yaml.contains("apiAddress: 127.0.0.1:9997"))
    XCTAssertTrue(yaml.contains("rtspAddress: 127.0.0.1:8554"))
    XCTAssertTrue(yaml.contains("rtspTransports: [tcp]"))
    XCTAssertTrue(yaml.contains("moq: no"))
    XCTAssertTrue(yaml.contains("webrtcAddress: 127.0.0.1:18889"))
    XCTAssertFalse(yaml.contains("webrtcAddress: :8889"))
    XCTAssertEqual(
      MediaMTXConfigWriter.webrtcHTTPPort(listenerPort: 8889, icePort: 8189), 18889)
    XCTAssertEqual(
      MediaMTXConfigWriter.webrtcHTTPPort(listenerPort: 8889, icePort: 18889), 18890)
    XCTAssertTrue(yaml.contains("webrtcLocalUDPAddress: :8189"))
    XCTAssertTrue(yaml.contains("webrtcLocalTCPAddress: :8189"))
    XCTAssertTrue(yaml.contains("webrtcAdditionalHosts: ['192.168.1.42']"))
    XCTAssertTrue(yaml.contains("logLevel: info"))
  }

  func testNetworkModes() {
    var settings = AppSettings.defaults
    settings.networkMode = .tcpOnly
    let tcp = MediaMTXConfigWriter.yaml(settings: settings)
    XCTAssertTrue(tcp.contains("webrtcLocalUDPAddress: ''"))
    XCTAssertTrue(tcp.contains("webrtcLocalTCPAddress: :8189"))

    settings.networkMode = .udpOnly
    settings.maxListeners = 50
    settings.streamName = "hall"
    settings.logLevel = .debug
    let udp = MediaMTXConfigWriter.yaml(
      settings: settings, options: MediaMTXConfigOptions(includeMoqKey: false))
    XCTAssertTrue(udp.contains("webrtcLocalUDPAddress: :8189"))
    XCTAssertTrue(udp.contains("webrtcLocalTCPAddress: ''"))
    XCTAssertTrue(udp.contains("  hall:\n    source: publisher\n    maxReaders: 50"))
    XCTAssertFalse(udp.contains("\nmoq:"))
    XCTAssertTrue(udp.contains("logLevel: debug"))
  }

  func testRealMediaMTXAcceptsGeneratedConfig() throws {
    let binary = ProcessInfo.processInfo.environment["MEDIAMTX_BIN"] ?? ""
    try XCTSkipIf(binary.isEmpty, "MEDIAMTX_BIN is not set")
    for mode in [NetworkMode.auto, .udpOnly, .tcpOnly] {
      var settings = AppSettings.defaults
      settings.networkMode = mode
      let yaml = MediaMTXConfigWriter.yaml(settings: settings, advertisedHost: "10.0.0.8")
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "earfi-\(mode.rawValue).yml")
      try yaml.write(to: url, atomically: true, encoding: .utf8)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: binary)
      process.arguments = ["--validate-conf", url.path]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      process.waitUntilExit()
      let output =
        String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let status = ProcessExit.statusIfExited(
        isRunning: process.isRunning, wasLaunched: true
      ) {
        process.terminationStatus
      }
      XCTAssertEqual(status, 0, output)
    }
  }

  private func allowedKeys() throws -> Set<String> {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("mediamtx-keys.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    return Set(text.split(separator: "\n").map(String.init))
  }
}

final class FFmpegCommandTests: XCTestCase {
  func testDefaultCommandReadsRawPCMFromStdin() {
    let arguments = FFmpegCommand.arguments(settings: .defaults)
    XCTAssertEqual(
      arguments,
      [
        "-hide_banner", "-nostdin", "-loglevel", "warning",
        "-thread_queue_size", "1024",
        "-f", "f32le", "-ar", "48000", "-ac", "1", "-i", "pipe:0",
        "-c:a", "libopus", "-b:a", "32k", "-application", "voip", "-frame_duration", "20",
        "-muxdelay", "0", "-muxpreload", "0",
        "-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://127.0.0.1:8554/live",
      ]
    )
    XCTAssertFalse(arguments.contains("avfoundation"))
  }

  func testChannelMapAndSpeechPreset() {
    var settings = AppSettings.defaults
    settings.channelMode = .mono
    settings.inputChannel = 2
    settings.applyPreset(.speech)
    settings.inputChannel = 2
    settings.streamName = "talk"
    let arguments = FFmpegCommand.arguments(settings: settings)
    XCTAssertTrue(arguments.contains("pipe:0"))
    XCTAssertTrue(arguments.contains("32k"))
    XCTAssertTrue(arguments.contains("voip"))
    XCTAssertTrue(arguments.contains("48000"))
    XCTAssertTrue(arguments.contains("rtsp://127.0.0.1:8554/talk"))
    XCTAssertEqual(
      CaptureChannelMap.indices(mode: .mono, inputChannel: 2, inputCount: 4), [0, 1, 2, 3])
    XCTAssertEqual(CaptureChannelMap.indices(mode: .mono, inputChannel: 1, inputCount: 1), [0])

    settings.channelMode = .stereo
    settings.inputChannel = 3
    settings.quality = .music
    let stereo = FFmpegCommand.arguments(settings: settings)
    XCTAssertEqual(stereo[stereo.firstIndex(of: "-ac")! + 1], "2")
    XCTAssertTrue(stereo.contains("128k"))
    XCTAssertEqual(
      CaptureChannelMap.indices(mode: .stereo, inputChannel: 3, inputCount: 8), [2, 3])
    XCTAssertEqual(
      CaptureChannelMap.indices(mode: .stereo, inputChannel: 3, inputCount: 1), [0, 0])
  }
}

final class NetworkAndURLTests: XCTestCase {
  func testPrefersEthernetOverWiFiAndSkipsVirtualAddresses() {
    let candidates = [
      NetworkCandidate(name: "lo0", address: "127.0.0.1", kind: .other, isUp: true),
      NetworkCandidate(name: "utun0", address: "10.8.0.2", kind: .other, isUp: true),
      NetworkCandidate(name: "bridge0", address: "192.168.64.1", kind: .other, isUp: true),
      NetworkCandidate(name: "en0", address: "169.254.1.2", kind: .wifi, isUp: true),
      NetworkCandidate(name: "en0", address: "192.168.1.20", kind: .wifi, isUp: true),
      NetworkCandidate(name: "en0", address: "192.168.1.20", kind: .wifi, isUp: false),
      NetworkCandidate(name: "en5", address: "10.0.0.4", kind: .ethernet, isUp: true),
      NetworkCandidate(name: "awdl0", address: "192.168.1.9", kind: .other, isUp: true),
    ]
    XCTAssertEqual(NetworkSelection.best(candidates)?.address, "10.0.0.4")
    XCTAssertEqual(
      NetworkSelection.ranked(candidates).map(\.address), ["10.0.0.4", "192.168.1.20"])
  }

  func testURLsAndStalePoster() {
    let ip = ListenerLink.make(
      style: .ip,
      ipAddress: "192.168.1.42",
      localHostname: "Hall-Mac.local",
      port: 8889
    )
    XCTAssertEqual(ip, "http://192.168.1.42:8889/")
    XCTAssertNil(URLComponents(string: ip ?? "")?.queryItems)
    XCTAssertNil(
      ListenerLink.make(
        style: .ip, ipAddress: nil, localHostname: "Hall-Mac", port: 8889)
    )
    XCTAssertEqual(
      ListenerLink.make(
        style: .localHostname,
        ipAddress: nil,
        localHostname: "Hall-Mac.local",
        port: 8889
      ),
      "http://Hall-Mac.local:8889/"
    )
    XCTAssertEqual(ListenerLink.normalizeLocalHostname("Hall-Mac.localdomain."), "Hall-Mac.local")
    XCTAssertEqual(ListenerLink.normalizeLocalHostname(""), "mac.local")

    let warning = ListenerLink.staleWarning(
      previousURL: "http://192.168.1.40:8889/live",
      currentURL: "http://192.168.1.57:8889/live"
    )
    XCTAssertEqual(warning?.previous, "192.168.1.40")
    XCTAssertEqual(warning?.current, "192.168.1.57")
    XCTAssertTrue(warning?.message.contains("Reprint the poster") == true)
    XCTAssertNil(
      ListenerLink.staleWarning(
        previousURL: "http://192.168.1.40:8889/live",
        currentURL: "http://192.168.1.40:8889/live"
      )
    )
    XCTAssertNil(
      ListenerLink.staleWarning(
        previousURL: "http://192.168.1.40:8889/live?title=Old",
        currentURL: "http://192.168.1.40:8889/"
      )
    )
    XCTAssertNil(
      ListenerLink.staleWarning(
        previousURL: "http://192.168.1.40:8889/live?title=Old",
        currentURL: "http://192.168.1.40:8889/live?title=New"
      )
    )
    let portChange = ListenerLink.staleWarning(
      previousURL: "http://192.168.1.40:8889/",
      currentURL: "http://192.168.1.40:8890/"
    )
    XCTAssertEqual(portChange?.previous, "192.168.1.40")
    XCTAssertEqual(portChange?.current, "192.168.1.40")
  }

  func testBroadcastTitleFollowsTheAppName() {
    XCTAssertEqual(
      BroadcastTitle.resolved(stored: "", appName: "Public EarFi"),
      "Public EarFi Broadcast"
    )
    XCTAssertEqual(
      BroadcastTitle.resolved(stored: "   ", appName: "Public EarFi"),
      "Public EarFi Broadcast"
    )
    XCTAssertEqual(BroadcastTitle.resolved(stored: "", appName: "Hall Ear"), "Hall Ear Broadcast")
    XCTAssertEqual(
      BroadcastTitle.resolved(stored: "", appName: ""),
      "Public EarFi Broadcast"
    )
    XCTAssertEqual(
      BroadcastTitle.resolved(stored: "Morning session", appName: "Public EarFi"),
      "Morning session"
    )
    let long = String(repeating: "a", count: 90)
    XCTAssertEqual(BroadcastTitle.sanitize(long).count, BroadcastTitle.maximumLength)
    XCTAssertEqual(BroadcastTitle.limited("Hello\nthere").contains("\n"), false)
    XCTAssertEqual(BroadcastTitle.sanitize("  Hello   there \n"), "Hello there")
  }

  func testPaperSizeFollowsRegion() {
    XCTAssertEqual(PaperSize.preferred(regionCode: "AU"), .a4)
    XCTAssertEqual(PaperSize.preferred(regionCode: "us"), .letter)
    XCTAssertEqual(PaperSize.preferred(regionCode: "CA"), .letter)
    XCTAssertEqual(PaperSize.preferred(regionCode: nil, measurementSystemIsUS: true), .letter)
    XCTAssertEqual(PaperSize.preferred(regionCode: nil, measurementSystemIsUS: false), .a4)
    XCTAssertEqual(PaperSize.a4.widthPoints, 595)
    XCTAssertEqual(PaperSize.a4.heightPoints, 842)
    XCTAssertEqual(PaperSize.letter.widthPoints, 612)
    XCTAssertEqual(PaperSize.letter.heightPoints, 792)
  }
}

final class PosterAndSupervisorTests: XCTestCase {
  func testInstructionsHideTheNetworkStepAndNumberLater() {
    let withNetwork = PosterBuilder.steps(
      instructions: PosterBuilder.defaultInstructions,
      show: true,
      networkName: "Hall-Guest"
    )
    XCTAssertEqual(withNetwork.first, "Join the Wi-Fi network Hall-Guest")
    XCTAssertEqual(withNetwork.count, 4)
    XCTAssertTrue(withNetwork.last?.contains("No sound? Tap the speaker/mute icon") == true)

    let hidden = PosterBuilder.steps(
      instructions: PosterBuilder.defaultInstructions,
      show: true,
      networkName: "  "
    )
    XCTAssertEqual(hidden.count, 3)
    XCTAssertFalse(hidden.joined(separator: "\n").contains("{network}"))
    XCTAssertTrue(
      PosterBuilder.steps(
        instructions: PosterBuilder.defaultInstructions, show: false, networkName: "Hall"
      ).isEmpty
    )
  }

  func testSameRateStereoKeepsTheEngineFormat() {
    XCTAssertEqual(
      CaptureFormatPlan.clientFormatChoice(engineChannels: 2, deviceChannels: 2), .keep)
    XCTAssertEqual(
      CaptureFormatPlan.clientFormatChoice(engineChannels: 1, deviceChannels: 1), .keep)
    XCTAssertEqual(
      CaptureFormatPlan.clientFormatChoice(engineChannels: 2, deviceChannels: 1), .keep)
    XCTAssertEqual(
      CaptureFormatPlan.clientFormatChoice(engineChannels: 0, deviceChannels: 2), .keep)
    XCTAssertEqual(
      CaptureFormatPlan.clientFormatChoice(engineChannels: 1, deviceChannels: 2), .widen)
    let delivery = CaptureDelivery(
      callbacks: 4, framesIn: 3840, framesOut: 1920, dropped: 1, bytesWritten: 7680,
      rateNote: "rate conversion skipped at 48000 Hz"
    )
    XCTAssertTrue(delivery.line.contains("callbacks 4"))
    XCTAssertTrue(delivery.line.contains("frames in 3840"))
    XCTAssertTrue(delivery.line.contains("frames out 1920"))
    XCTAssertTrue(delivery.line.contains("stdin bytes 7680"))
    XCTAssertTrue(delivery.line.contains("rate conversion skipped at 48000 Hz"))
  }

  func testQuickPosterStepsLeaveALineWhenTheNetworkIsUnknown() {
    XCTAssertEqual(
      PosterBuilder.quickSteps(networkName: "Hall-Guest"),
      [
        "Join Wi-Fi Hall-Guest",
        "Scan the QR code with your phone camera",
        "Tap play; use your own earphones",
      ]
    )
    let blank = PosterBuilder.quickSteps(networkName: "  ")
    XCTAssertEqual(blank.count, 3)
    XCTAssertTrue(blank[0].hasPrefix("Join Wi-Fi "))
    XCTAssertTrue(blank[0].contains("____"))
    XCTAssertFalse(blank[0].contains("Hall"))
    XCTAssertEqual(PosterBuilder.poweredBy, "Powered by Public EarFi")
  }

  func testQuickPosterAddsAWiFiCodeWhenTheNetworkIsSet() {
    let url = "http://192.168.1.20:8889/"
    let blank = PosterBuilder.quickPlan(
      networkName: "  ",
      password: "secret",
      security: .wpa,
      hidden: true,
      listenerURL: url
    )
    XCTAssertFalse(blank.includesWiFiCode)
    XCTAssertEqual(blank.codes.map(\.payload), [url])
    XCTAssertEqual(blank.closing, "")
    XCTAssertTrue(blank.steps[0].contains("____"))
    XCTAssertFalse(blank.steps.joined(separator: "\n").contains("secret"))

    let joined = PosterBuilder.quickPlan(
      networkName: "Hall-Guest",
      password: "p:q;r",
      security: .wpa,
      hidden: false,
      listenerURL: url
    )
    XCTAssertTrue(joined.includesWiFiCode)
    XCTAssertEqual(joined.codes[0].label, "1. Join the Wi-Fi")
    XCTAssertEqual(
      joined.codes[0].payload,
      "WIFI:T:WPA;S:Hall-Guest;P:p\\:q\\;r;H:false;;"
    )
    XCTAssertEqual(joined.codes[0].lines, ["Hall-Guest", "Password: p:q;r"])
    XCTAssertEqual(joined.codes[1].label, "2. Open the broadcast")
    XCTAssertEqual(joined.codes[1].payload, url)
    XCTAssertEqual(joined.codes[1].lines, [url])
    XCTAssertEqual(joined.closing, "3. Tap play; use your own earphones")
    XCTAssertFalse(joined.codes[1].payload.contains("WIFI:"))

    let hidden = PosterBuilder.quickPlan(
      networkName: "a\\b;c,d:e\"f",
      password: "secret",
      security: .wep,
      hidden: true,
      listenerURL: url
    )
    XCTAssertEqual(
      hidden.codes[0].payload,
      "WIFI:T:WEP;S:a\\\\b\\;c\\,d\\:e\\\"f;P:secret;H:true;;"
    )
    XCTAssertEqual(
      hidden.codes[0].lines,
      ["a\\b;c,d:e\"f", "Password: secret", "Hidden network"]
    )

    let open = PosterBuilder.quickPlan(
      networkName: "Hall",
      password: "secret",
      security: .none,
      hidden: false,
      listenerURL: url
    )
    XCTAssertEqual(open.codes[0].payload, "WIFI:T:nopass;S:Hall;P:;H:false;;")
    XCTAssertEqual(open.codes[0].lines, ["Hall", "No password"])
    XCTAssertFalse(open.codes[0].lines.joined(separator: "\n").contains("secret"))
  }

  func testWiFiQREscapesTheReservedCharacters() {
    XCTAssertEqual(WiFiQRCode.escape("\\ ;,:\"end"), #"\\ \;\,\:\"end"#)
    XCTAssertEqual(
      WiFiQRCode.payload(ssid: "Cafe", password: "ok", security: .wpa, hidden: true),
      "WIFI:T:WPA;S:Cafe;P:ok;H:true;;"
    )
    XCTAssertEqual(WiFiSecurity.wpa.menuLabel, "WPA/WPA2/WPA3")
    XCTAssertEqual(WiFiSecurity.none.qrType, "nopass")
  }

  func testStartFFmpegDoesNotReadStatusWhileFFmpegIsRunning() {
    var reads = 0
    let running = ProcessExit.statusIfExited(isRunning: true, wasLaunched: true) {
      reads += 1
      return 9
    }
    XCTAssertNil(running)
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(
      ProcessExit.ffmpegNotReadyDetail(isRunning: true, wasLaunched: true, status: nil),
      "the stream was not ready within 5 s"
    )

    var unlaunchedReads = 0
    let unlaunched = ProcessExit.statusIfExited(isRunning: false, wasLaunched: false) {
      unlaunchedReads += 1
      return 0
    }
    XCTAssertNil(unlaunched)
    XCTAssertEqual(unlaunchedReads, 0)
    XCTAssertEqual(
      ProcessExit.ffmpegNotReadyDetail(isRunning: false, wasLaunched: false, status: nil),
      "the stream was not ready within 5 s"
    )

    var exitedReads = 0
    let exited = ProcessExit.statusIfExited(isRunning: false, wasLaunched: true) {
      exitedReads += 1
      return 1
    }
    XCTAssertEqual(exited, 1)
    XCTAssertEqual(exitedReads, 1)
    XCTAssertEqual(
      ProcessExit.ffmpegNotReadyDetail(isRunning: false, wasLaunched: true, status: 1),
      "exited with status 1"
    )
  }

  func testBackoffStallAndHealth() {
    XCTAssertEqual(RestartBackoff.delay(forFailureCount: 1), 1)
    XCTAssertEqual(RestartBackoff.delay(forFailureCount: 2), 2)
    XCTAssertEqual(RestartBackoff.delay(forFailureCount: 3), 4)
    XCTAssertEqual(RestartBackoff.delay(forFailureCount: 6), 30)
    XCTAssertFalse(RestartBackoff.showsProblem(failureCount: 4))
    XCTAssertTrue(RestartBackoff.showsProblem(failureCount: 5))
    XCTAssertFalse(RestartBackoff.shouldResetCounter(stableFor: 59))
    XCTAssertTrue(RestartBackoff.shouldResetCounter(stableFor: 60))

    var stall = StallDetector()
    let start = Date(timeIntervalSince1970: 1_000)
    XCTAssertFalse(stall.observe(bytes: 10, now: start))
    XCTAssertFalse(stall.observe(bytes: 10, now: start.addingTimeInterval(5.9)))
    XCTAssertTrue(stall.observe(bytes: 10, now: start.addingTimeInterval(6)))
    XCTAssertFalse(stall.observe(bytes: 11, now: start.addingTimeInterval(7)))
    XCTAssertFalse(stall.observe(bytes: 11, now: start.addingTimeInterval(12.9)))
    XCTAssertTrue(stall.observe(bytes: 11, now: start.addingTimeInterval(13)))

    XCTAssertEqual(
      HealthText.restarted(component: "ffmpeg", count: 1, limit: 5, time: "11:47:20"),
      "11:47:20 ffmpeg restarted after exit (1/5) — OK"
    )
    XCTAssertEqual(
      HealthText.retrying(
        component: "ffmpeg",
        detail: "the stream was not ready within 5 s",
        count: 1,
        limit: 5,
        time: "11:47:20",
        extra: "Decoding requested, but no decoder found for: pcm_f32le"
      ),
      """
      11:47:20 ffmpeg: the stream was not ready within 5 s (1/5). Retrying.
      Decoding requested, but no decoder found for: pcm_f32le
      """
    )
    XCTAssertTrue(
      HealthText.retrying(
        component: "ffmpeg", detail: "exited with status 234", count: 5, limit: 5,
        time: "11:47:20", extra: nil
      ).contains("Still retrying every 30 s.")
    )
    XCTAssertTrue(StreamLog.isFailure("no decoder found for: pcm_f32le"))
    XCTAssertTrue(StreamLog.isFailure("Error opening output files: Invalid argument"))
    XCTAssertFalse(StreamLog.isFailure("configuration loaded"))
    XCTAssertTrue(StreamLog.isFrameDrop("Thread message queue blocking"))
    XCTAssertTrue(StreamLog.isFrameDrop("aresample drift detected"))
    XCTAssertFalse(StreamLog.isFrameDrop("configuration loaded"))
  }
}

final class PortConflictTests: XCTestCase {
  func testWatchedPortsCoverListenerIceRTSPAndAPI() {
    var settings = AppSettings.defaults
    settings.listenerPort = 8889
    settings.icePort = 8189
    let ports = WatchedPorts.all(settings: settings)
    XCTAssertEqual(ports.map(\.port), [8889, 8189, 8554, 9997, 18889])
    XCTAssertTrue(ports[4].localhostOnly)
    XCTAssertFalse(ports[4].changeable)
    XCTAssertTrue(ports[4].tcp)
    XCTAssertFalse(ports[4].udp)
    XCTAssertTrue(ports[0].tcp)
    XCTAssertFalse(ports[0].udp)
    XCTAssertTrue(ports[0].changeable)
    XCTAssertTrue(ports[1].tcp)
    XCTAssertTrue(ports[1].udp)
    XCTAssertFalse(ports[2].changeable)
    XCTAssertTrue(ports[2].localhostOnly)
    XCTAssertTrue(ports[3].localhostOnly)

    settings.networkMode = .tcpOnly
    let tcpOnly = WatchedPorts.all(settings: settings)
    XCTAssertTrue(tcpOnly[1].tcp)
    XCTAssertFalse(tcpOnly[1].udp)

    settings.networkMode = .udpOnly
    let udpOnly = WatchedPorts.all(settings: settings)
    XCTAssertFalse(udpOnly[1].tcp)
    XCTAssertTrue(udpOnly[1].udp)
  }

  func testPortMessageNamesTheProcessAndDoesNotRetryABindError() {
    XCTAssertEqual(
      PortConflictText.message(
        port: 8889, processName: "mediamtx", pid: 4321, changeable: true, ours: false),
      "port 8889 is in use by mediamtx (pid 4321). Quit that app, or change the port in Settings."
    )
    XCTAssertEqual(
      PortConflictText.message(
        port: 8554, processName: "mediamtx", pid: 4321, changeable: false, ours: false),
      "port 8554 is in use by mediamtx (pid 4321). Quit that app."
    )
    XCTAssertEqual(
      PortConflictText.message(
        port: 8889, processName: "mediamtx", pid: 4321, changeable: true, ours: true),
      "port 8889 is in use by a leftover mediamtx (pid 4321). Stop it, then press Start again."
    )
    XCTAssertEqual(
      PortConflictText.message(
        port: 8189, processName: nil, pid: nil, changeable: true, ours: false),
      "port 8189 is in use. Quit the other app, or change the port in Settings."
    )

    let log = "ERR [WebRTC] listen tcp :8889: bind: address already in use"
    XCTAssertTrue(BindFailure.isAddressInUse(log))
    XCTAssertEqual(BindFailure.mentionedPort(log), 8889)
    XCTAssertEqual(
      BindFailure.mentionedPort("listen tcp 127.0.0.1:8554: bind: address already in use"),
      8554
    )
    XCTAssertFalse(RestartPolicy.retries(detail: "mediamtx exited with status 1", logExcerpt: log))
    XCTAssertTrue(
      RestartPolicy.retries(
        detail: "mediamtx exited with status 1", logExcerpt: "configuration loaded")
    )
    let fromLog = PortConflictText.fromLog(log, listenerPort: 8889, icePort: 8189)
    XCTAssertEqual(fromLog.port, 8889)
    XCTAssertNil(fromLog.stray)
    XCTAssertTrue(fromLog.message.contains("change the port in Settings"))
  }

  func testLsofParseAndBundledHelperPaths() {
    let text = """
      p4321
      cmediamtx
      n*:8889
      p77
      cGoogle
      n192.168.1.5:50000->192.168.1.9:8889
      p88
      cpython
      n127.0.0.1:9997
      """
    let records = LsofText.records(from: text)
    XCTAssertEqual(records.count, 3)
    XCTAssertEqual(records[0].pid, 4321)
    XCTAssertEqual(records[0].command, "mediamtx")
    XCTAssertTrue(LsofText.matches(name: records[0].names[0], port: 8889))
    XCTAssertFalse(LsofText.matches(name: records[0].names[0], port: 88890))
    XCTAssertFalse(LsofText.matches(name: "192.168.1.5:50000->192.168.1.9:8889", port: 8889))
    XCTAssertTrue(LsofText.matches(name: "[::1]:8189", port: 8189))

    let bundled = "/Applications/Public EarFi.app/Contents/Helpers/mediamtx"
    XCTAssertTrue(HelperIdentity.isBundledHelper(executablePath: bundled))
    XCTAssertTrue(
      HelperIdentity.isBundledHelper(
        executablePath: "/tmp/elsewhere/mediamtx",
        knownHelperPaths: ["/tmp/elsewhere/mediamtx"]
      )
    )
    XCTAssertFalse(
      HelperIdentity.isBundledHelper(executablePath: "/opt/homebrew/bin/mediamtx")
    )
    XCTAssertFalse(HelperIdentity.isBundledHelper(executablePath: nil))
  }
}

final class APIAndCreditsTests: XCTestCase {
  func testPathParserCountsOnlyWebRTCReadersAndPrefersNewByteCounters() throws {
    let json = """
      {
        "ready": false,
        "online": true,
        "bytesReceived": 5,
        "inboundBytes": 20,
        "bytesSent": 1,
        "outboundBytes": 9,
        "readers": [
          {"type": "webRTCSession", "id": "a"},
          {"type": "rtspSession", "id": "b"},
          {"type": "webRTCSession", "id": "c"}
        ]
      }
      """.data(using: .utf8)!
    let snapshot = try MediaMTXAPI.parsePath(json)
    XCTAssertTrue(snapshot.ready)
    XCTAssertEqual(snapshot.bytesReceived, 20)
    XCTAssertEqual(snapshot.bytesSent, 9)
    XCTAssertEqual(snapshot.webrtcListeners, 2)

    let legacy = """
      {"ready": true, "bytesReceived": 4, "bytesSent": 8, "readers": []}
      """.data(using: .utf8)!
    let old = try MediaMTXAPI.parsePath(legacy)
    XCTAssertTrue(old.ready)
    XCTAssertEqual(old.bytesReceived, 4)
    XCTAssertEqual(old.bytesSent, 8)

    let sessions = """
      {"itemCount": 2, "items": [{}, {}]}
      """.data(using: .utf8)!
    XCTAssertEqual(MediaMTXAPI.parseWebRTCSessionCount(sessions), 2)
  }

  func testCreditsCoverBundledComponentsAndFFmpegNotice() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let licenses = root.appendingPathComponent("Sources/PublicEarFi/Resources/Licenses")
    let document = try CreditsDocument.load(from: licenses.appendingPathComponent("credits.json"))
    XCTAssertEqual(CreditsRules.missingIDs(document), [])

    let mediamtx = try XCTUnwrap(document.component("mediamtx"))
    let mediamtxLicense = try String(
      contentsOf: licenses.appendingPathComponent(mediamtx.licenseFile), encoding: .utf8)
    XCTAssertTrue(mediamtxLicense.contains(mediamtx.copyright))
    XCTAssertEqual(mediamtx.copyright, "Copyright (c) 2019 aler9")
    XCTAssertEqual(mediamtx.version, "1.21.2")

    let ffmpeg = try XCTUnwrap(document.component("ffmpeg"))
    XCTAssertEqual(ffmpeg.version, "9.0.2")
    XCTAssertTrue(ffmpeg.notes.contains(CreditsRules.ffmpegStatement))
    XCTAssertTrue(ffmpeg.notes.contains("ffmpeg-9.0.2-source.tar.xz"))
    let flags = try XCTUnwrap(ffmpeg.configureFlags)
    let flagFile = root.appendingPathComponent("scripts/ffmpeg-configure-flags.txt")
    let expectedFlags = try String(contentsOf: flagFile, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .joined(separator: " ")
    XCTAssertEqual(flags, expectedFlags)
    XCTAssertTrue(flags.contains("--disable-gpl"))
    XCTAssertTrue(flags.contains("--disable-nonfree"))
    XCTAssertTrue(flags.contains("--enable-libopus"))
    XCTAssertTrue(flags.contains("--enable-avfoundation"))
    XCTAssertTrue(flags.contains("pcm_f32le"))
    XCTAssertTrue(flags.contains("pcm_s16le"))
    XCTAssertTrue(flags.contains("pcm_s24le"))
    XCTAssertTrue(flags.contains("pcm_s32le"))
    XCTAssertTrue(flags.contains("pcm_f64le"))
    XCTAssertTrue(flags.contains("--enable-filter=aresample,pan,astats,aformat"))
    XCTAssertTrue(flags.contains("--enable-protocol=file,pipe,tcp,udp,rtp,http"))
    XCTAssertFalse(flags.contains(" --enable-gpl"))
    XCTAssertFalse(flags.contains("--enable-nonfree"))
    let lgpl = try String(
      contentsOf: licenses.appendingPathComponent(ffmpeg.licenseFile), encoding: .utf8)
    XCTAssertTrue(lgpl.hasPrefix("                  GNU LESSER GENERAL PUBLIC LICENSE"))

    let opus = try XCTUnwrap(document.component("libopus"))
    XCTAssertEqual(opus.version, "1.6.1")
    let opusLicense = try String(
      contentsOf: licenses.appendingPathComponent(opus.licenseFile), encoding: .utf8)
    XCTAssertTrue(opusLicense.hasPrefix(opus.copyright))
    XCTAssertTrue(opusLicense.contains("Redistribution and use in source and binary forms"))

    let app = try XCTUnwrap(document.component("public-earfi"))
    XCTAssertEqual(app.copyright, "Copyright (c) 2026 Walter Kaan")
    XCTAssertEqual(document.component("qr")?.notes.contains("CIQRCodeGenerator"), true)

    let text = document.plainText()
    XCTAssertTrue(text.contains("MediaMTX 1.21.2"))
    XCTAssertTrue(text.contains("FFmpeg 9.0.2"))
  }

  func testDiagnosticsIncludesTheTailOfTheLog() {
    let lines = (1...250).map { "line \($0)" }
    let report = DiagnosticsReport.make(
      appVersion: "1.0.0 (7, abc)",
      systemDescription: "macOS 15",
      settings: .defaults,
      listenerURL: "http://192.168.1.42:8889/live",
      helperSummary: "MediaMTX 1.21.2",
      logLines: lines
    )
    XCTAssertTrue(report.contains("line 250"))
    XCTAssertFalse(report.contains("line 1\n"))
    XCTAssertTrue(report.contains("stream: live"))
    XCTAssertTrue(report.contains("broadcast title: Public EarFi Broadcast"))
    XCTAssertTrue(report.contains("poster Wi-Fi password: not included"))
    XCTAssertTrue(report.contains("Recent log (200 lines)"))
  }

  func testDiagnosticsOmitsThePosterPassword() throws {
    var settings = AppSettings.defaults
    settings.posterNetworkName = "Hall-Guest"
    settings.posterWiFiSecurity = .wpa
    settings.posterWiFiHidden = true
    let secret = "venue-password-9f3a"
    let report = DiagnosticsReport.make(
      appVersion: "1.0.0",
      systemDescription: "macOS",
      settings: settings,
      listenerURL: "http://10.0.0.2:8889/",
      helperSummary: "helpers",
      logLines: ["started"]
    )
    XCTAssertFalse(report.contains(secret))
    XCTAssertTrue(report.contains("poster Wi-Fi: Hall-Guest"))
    XCTAssertTrue(report.contains("poster Wi-Fi security: wpa"))
    XCTAssertTrue(report.contains("poster Wi-Fi hidden: true"))
    XCTAssertTrue(report.contains("poster Wi-Fi password: not included"))
    let data = try XCTUnwrap(JSONEncoder().encode(settings))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
  }

  func testMonoDownmixGainAndSoftLimit() {
    XCTAssertEqual(MonoDownmix.sum(interleaved: [1, 3, 5, 7], channelCount: 2), [4, 12])
    XCTAssertEqual(MonoDownmix.average(interleaved: [1, 3, 5, 7], channelCount: 2), [2, 6])
    XCTAssertEqual(MonoDownmix.average(interleaved: [1, 2, 3], channelCount: 3), [2])
    XCTAssertEqual(MonoDownmix.average(interleaved: [0.5], channelCount: 1), [0.5])
    XCTAssertEqual(MonoDownmix.average(interleaved: [], channelCount: 2), [])
    XCTAssertEqual(MonoDownmix.average(interleaved: [1, 2], channelCount: 0), [])

    XCTAssertEqual(InputGain.clamped(80), 24)
    XCTAssertEqual(InputGain.clamped(-40), -12)
    XCTAssertEqual(InputGain.clamped(.nan), 0)
    XCTAssertEqual(InputGain.label(6), "+6 dB")
    XCTAssertEqual(InputGain.label(-12), "-12 dB")

    let quiet = InputGain.apply([0.25, -0.25], gainDB: 0)
    XCTAssertEqual(quiet[0], 0.25, accuracy: 0.0001)
    XCTAssertEqual(quiet[1], -0.25, accuracy: 0.0001)

    let mild = InputGain.softLimit(1.05)
    let hotter = InputGain.softLimit(1.5)
    XCTAssertGreaterThan(mild, 0.9)
    XCTAssertLessThan(mild, hotter)
    XCTAssertLessThan(hotter, 1)
    XCTAssertLessThanOrEqual(InputGain.softLimit(100), 1)

    let boosted = InputGain.render(
      interleaved: [0.2, 0.4],
      channelCount: 2,
      downmixToMono: true,
      gainDB: 12
    )
    XCTAssertEqual(boosted.count, 1)
    XCTAssertGreaterThan(boosted[0], 0.9)
    XCTAssertLessThan(boosted[0], 1)

    let negative = InputGain.softLimit(-1.5)
    XCTAssertGreaterThan(negative, -1)
    XCTAssertLessThan(negative, -0.9)

    let level = SignalLevel.decibels([1, -1, 1, -1])
    XCTAssertEqual(level, 0, accuracy: 0.01)

    let oneSide = InputGain.render(
      interleaved: [0.5, 0],
      channelCount: 2,
      downmixToMono: true,
      gainDB: 0
    )
    XCTAssertEqual(oneSide, [0.5])
    let bothSides = InputGain.render(
      interleaved: [0.8, 0.8],
      channelCount: 2,
      downmixToMono: true,
      gainDB: 0
    )
    XCTAssertEqual(bothSides.count, 1)
    XCTAssertGreaterThan(bothSides[0], 0.9)
    XCTAssertLessThanOrEqual(bothSides[0], 1)
  }

  func testMonoSumKeepsEitherStereoSide() {
    let left: [Float] = [0.4, 0, 0.2, 0]
    let right: [Float] = [0, 0.4, 0, 0.2]
    let fromLeft = MonoDownmix.sum(interleaved: left, channelCount: 2)
    let fromRight = MonoDownmix.sum(interleaved: right, channelCount: 2)
    XCTAssertEqual(fromLeft, [0.4, 0.2])
    XCTAssertEqual(fromRight, [0.4, 0.2])
    let leftLevel = SignalLevel.decibels(fromLeft)
    let rightLevel = SignalLevel.decibels(fromRight)
    XCTAssertGreaterThan(leftLevel, -40)
    XCTAssertEqual(leftLevel, rightLevel, accuracy: 0.01)

    let gainedLeft = InputGain.render(
      interleaved: left, channelCount: 2, downmixToMono: true, gainDB: 0)
    let gainedRight = InputGain.render(
      interleaved: right, channelCount: 2, downmixToMono: true, gainDB: 0)
    XCTAssertEqual(gainedLeft, fromLeft)
    XCTAssertEqual(gainedRight, fromRight)

    let channel0 = stride(from: 0, to: right.count, by: 2).map { right[$0] }
    XCTAssertEqual(channel0, [0, 0])
    XCTAssertLessThan(SignalLevel.decibels(channel0), -40)

    let mixedLeft = CaptureMix.render(
      interleaved: left, channelCount: 2, mode: .mono, inputChannel: 1)
    let mixedRight = CaptureMix.render(
      interleaved: right, channelCount: 2, mode: .mono, inputChannel: 2)
    XCTAssertEqual(mixedLeft, fromLeft)
    XCTAssertEqual(mixedRight, fromRight)
    XCTAssertEqual(
      CaptureMix.render(
        interleaved: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
        channelCount: 3,
        mode: .stereo,
        inputChannel: 2
      ),
      [0.2, 0.3, 0.5, 0.6]
    )
  }

  func testInputGainIsPersistedAndOutOfRangeValuesReset() {
    let suite = "public-earfi-gain-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = SettingsStore(userDefaults: defaults)
    var settings = AppSettings.defaults
    settings.inputGainDB = 12
    store.save(settings)
    XCTAssertEqual(store.load().inputGainDB, 12)

    settings.inputGainDB = 48
    store.save(settings)
    let resolved = store.loadResolved()
    XCTAssertEqual(resolved.settings.inputGainDB, 0)
    XCTAssertEqual(
      resolved.notice,
      "Saved settings were invalid (volume) and were reset. Check Settings, then press Start."
    )
  }

  func testChildStopSignalsOnlyTheHelperGroup() {
    XCTAssertEqual(ChildStop.Target(pid: 400, group: 400).signalTarget, -400)
    XCTAssertEqual(ChildStop.Target(pid: 400, group: 20).signalTarget, 400)
    XCTAssertEqual(ChildStop.Target(pid: 400, group: 0).signalTarget, 400)
    XCTAssertEqual(ChildStop.termSignal, 15)
    XCTAssertEqual(ChildStop.killSignal, 9)
    XCTAssertFalse(ChildStop.shouldReap(pid: 1, actualPath: "/tmp/mediamtx", expectedPath: nil))
    XCTAssertFalse(ChildStop.shouldReap(pid: 40, actualPath: nil, expectedPath: "/bin/mediamtx"))
    XCTAssertFalse(
      ChildStop.shouldReap(
        pid: 40, actualPath: "/opt/homebrew/bin/mediamtx", expectedPath: "/app/mediamtx")
    )
    XCTAssertTrue(
      ChildStop.shouldReap(
        pid: 40, actualPath: "/app/mediamtx", expectedPath: "/app/mediamtx"))
    let recorded = SupervisedPIDs(
      mediamtx: 10,
      ffmpeg: 11,
      mediamtxGroup: 10,
      ffmpegGroup: nil,
      mediamtxExecutable: "/app/mediamtx",
      ffmpegExecutable: "/app/ffmpeg"
    )
    XCTAssertEqual(
      recorded.reapTargets,
      [
        .init(pid: 10, group: 10, executable: "/app/mediamtx"),
        .init(pid: 11, group: 0, executable: "/app/ffmpeg"),
      ]
    )
    XCTAssertTrue(BindCheck.reuseAddress(tcp: true))
    XCTAssertFalse(BindCheck.reuseAddress(tcp: false))
  }

  func testChunkedFFmpegStderrWithCarriageReturnsAndPartialUTF8() throws {
    var buffer = ProcessOutputBuffer(historyLimit: 64)
    XCTAssertEqual(buffer.append(Data()), [])

    var lines: [String] = []
    let hello = Data("hello\n".utf8)
    for byte in hello {
      lines.append(contentsOf: buffer.append(Data([byte])))
    }
    XCTAssertEqual(lines, ["hello"])
    XCTAssertEqual(buffer.remainder, "")

    XCTAssertEqual(
      buffer.append(Data("frame= 1 fps=0.0 size= 0kB speed=1.0x\r".utf8)),
      ["frame= 1 fps=0.0 size= 0kB speed=1.0x"]
    )
    XCTAssertEqual(
      buffer.append(Data("frame= 2 fps=0.0 size= 1kB speed=1.0x\r".utf8)),
      ["frame= 2 fps=0.0 size= 1kB speed=1.0x"]
    )
    XCTAssertEqual(buffer.append(Data("\n".utf8)), [])

    let cafe = [UInt8]("café failed\n".utf8)
    let split = try XCTUnwrap(cafe.firstIndex(of: 0xC3))
    XCTAssertEqual(buffer.append(Data(cafe[..<(split + 1)])), [])
    XCTAssertEqual(
      buffer.append(Data(cafe[(split + 1)...])),
      ["café failed"]
    )
    XCTAssertEqual(buffer.remainder, "")

    XCTAssertEqual(buffer.append(Data("Error opening ".utf8)), [])
    XCTAssertEqual(buffer.remainder, "Error opening ")
    XCTAssertEqual(
      buffer.append(Data("output files: Invalid argument\r\n".utf8)),
      ["Error opening output files: Invalid argument"]
    )

    XCTAssertEqual(
      buffer.append(Data([0x62, 0x61, 0x64, 0xFF, 0x0A])),
      ["bad\u{FFFD}"]
    )

    var capped = ProcessOutputBuffer(historyLimit: 32)
    _ = capped.append(Data(String(repeating: "a", count: 100).utf8) + Data([0x0A]))
    _ = capped.append(Data("listen tcp :8889: bind: address already in use\n".utf8))
    XCTAssertLessThanOrEqual(capped.excerpt.utf8.count, 32)
    XCTAssertTrue(capped.excerpt.hasSuffix("address already in use\n"))
    capped.reset()
    XCTAssertEqual(capped.remainder, "")
    XCTAssertEqual(capped.excerpt, "")
  }

  func testCaptureFormatKeepsTheDeviceRateAndDoesNotRetry() {
    let desk = CaptureStreamDescription(
      sampleRate: 44_100,
      channelCount: 8,
      bitsPerChannel: 24,
      isFloat: false,
      isInterleaved: true
    )
    XCTAssertTrue(desk.canOpen)
    XCTAssertEqual(
      desk.summary,
      "44100 Hz, 24-bit integer, 8 channels, interleaved"
    )
    XCTAssertEqual(CaptureFormatPlan.rateChannels(inputChannels: 8, mono: true), 1)
    XCTAssertEqual(CaptureFormatPlan.rateChannels(inputChannels: 8, mono: false), 2)
    XCTAssertEqual(CaptureFormatPlan.identityChannelMap(channelCount: 2), [0, 1])
    XCTAssertEqual(CaptureFormatPlan.identityChannelMap(channelCount: 8), Array(0..<8))
    XCTAssertEqual(CaptureFormatPlan.pipeChannels(mono: true), 1)
    XCTAssertEqual(CaptureFormatPlan.silenceClearDB, -40)
    XCTAssertEqual(CaptureFormatPlan.silenceClearSeconds, 2)
    XCTAssertEqual(CaptureFormatPlan.interleavedChoices(channelCount: 8), [false])
    XCTAssertEqual(CaptureFormatPlan.interleavedChoices(channelCount: 2), [true, false])
    XCTAssertEqual(CaptureFormatPlan.silenceWarningSeconds, 5)
    XCTAssertFalse(
      CaptureFormatPlan.shouldRetry(message: "Could not build the 48 kHz capture format."))
    let impossible = CaptureFormatPlan.impossibleMessage(deviceName: "USB Audio", stream: desk)
    XCTAssertTrue(impossible.contains("44100 Hz"))
    XCTAssertTrue(impossible.contains("does not change the device's sample rate"))
    XCTAssertFalse(CaptureFormatPlan.shouldRetry(message: impossible))
    let silent = CaptureStreamDescription(
      sampleRate: 0, channelCount: 0, bitsPerChannel: 0, isFloat: false, isInterleaved: true)
    XCTAssertFalse(silent.canOpen)
    XCTAssertTrue(
      CaptureFormatPlan.impossibleMessage(deviceName: "USB Audio", stream: silent).contains(
        "no input"))
    XCTAssertFalse(
      CaptureFormatPlan.shouldRetry(
        message: CaptureFormatPlan.conversionStoppedMessage(
          deviceName: "USB Audio", summary: desk.summary)
      ))
    for rate in [16_000.0, 24_000.0] {
      let handsFree = CaptureStreamDescription(
        sampleRate: rate,
        channelCount: 1,
        bitsPerChannel: 16,
        isFloat: false,
        isInterleaved: true
      )
      XCTAssertTrue(handsFree.canOpen)
      XCTAssertEqual(CaptureFormatPlan.rateChannels(inputChannels: 1, mono: true), 1)
      XCTAssertTrue(handsFree.summary.hasPrefix("\(Int(rate)) Hz"))
      XCTAssertTrue(handsFree.summary.contains("1 channel"))
    }
    let settling = CaptureFormatPlan.notReadyMessage(deviceName: "Headset")
    XCTAssertTrue(CaptureFormatPlan.isInputSettling(settling))
    XCTAssertTrue(CaptureFormatPlan.shouldRetry(message: settling))
    XCTAssertFalse(settling.lowercased().contains("no input"))
    XCTAssertFalse(settling.lowercased().contains("not connected"))
    XCTAssertFalse(settling.lowercased().contains("could not open"))
    XCTAssertEqual(
      CaptureFormatPlan.noAudioMessage(deviceName: "BlackHole 2ch"),
      "No audio from BlackHole 2ch."
    )
    XCTAssertFalse(
      CaptureFormatPlan.noAudioMessage(deviceName: "USB PnP Audio Device").contains(
        "still switching")
    )
    let gaveUp = CaptureFormatPlan.inputGaveUpMessage(deviceName: "Headset")
    XCTAssertFalse(CaptureFormatPlan.isInputSettling(gaveUp))
    XCTAssertEqual(CaptureFormatPlan.rebuildLimit(bluetooth: false), 3)
    XCTAssertEqual(CaptureFormatPlan.rebuildLimit(bluetooth: true), 6)
    XCTAssertGreaterThanOrEqual(CaptureFormatPlan.formatSettleSeconds, 0.75)
    XCTAssertLessThanOrEqual(CaptureFormatPlan.formatSettleSeconds, 1.5)
    XCTAssertEqual(AudioTransportLabel.bluetooth, 0x626C_7565)
    XCTAssertEqual(AudioTransportLabel.bluetoothLE, 0x626C_6561)
    XCTAssertTrue(AudioTransportLabel.isBluetooth(AudioTransportLabel.bluetooth))
    XCTAssertTrue(AudioTransportLabel.isBluetooth(AudioTransportLabel.bluetoothLE))
    XCTAssertFalse(AudioTransportLabel.isBluetooth(AudioTransportLabel.usb))
    XCTAssertFalse(AudioTransportLabel.isBluetooth(AudioTransportLabel.builtIn))
    XCTAssertEqual(AudioTransportLabel.describe(AudioTransportLabel.bluetooth), "Bluetooth (blue)")
    XCTAssertEqual(
      AudioTransportLabel.describe(AudioTransportLabel.bluetoothLE), "Bluetooth (blea)")
    XCTAssertEqual(AudioTransportLabel.describe(AudioTransportLabel.builtIn), "Built-in (bltn)")
    XCTAssertEqual(AudioTransportLabel.describe(AudioTransportLabel.usb), "USB (usb)")
    XCTAssertEqual(AudioTransportLabel.describe(0), "Unknown (0x00000000)")
    var headsetBudget = FormatRebuildBudget(
      limit: CaptureFormatPlan.rebuildLimit(bluetooth: true))
    let budgetStart = Date(timeIntervalSince1970: 1_800_000_000)
    for _ in 0..<6 {
      XCTAssertTrue(headsetBudget.allow(at: budgetStart))
    }
    XCTAssertFalse(headsetBudget.allow(at: budgetStart.addingTimeInterval(10)))
    XCTAssertTrue(headsetBudget.allow(at: budgetStart.addingTimeInterval(31)))
    var wiredBudget = FormatRebuildBudget(limit: CaptureFormatPlan.rebuildLimit(bluetooth: false))
    XCTAssertTrue(wiredBudget.allow(at: budgetStart))
    XCTAssertTrue(wiredBudget.allow(at: budgetStart))
    XCTAssertTrue(wiredBudget.allow(at: budgetStart))
    XCTAssertFalse(wiredBudget.allow(at: budgetStart))
  }

  func testSilenceWarningWaitsAndDoesNotFlicker() {
    var watch = SilenceWatch()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    watch.update(decibels: -80, now: start)
    XCTAssertFalse(watch.showing)
    watch.update(decibels: -80, now: start.addingTimeInterval(4.9))
    XCTAssertFalse(watch.showing)
    watch.update(decibels: -80, now: start.addingTimeInterval(5))
    XCTAssertTrue(watch.showing)
    watch.update(decibels: -45, now: start.addingTimeInterval(6))
    XCTAssertTrue(watch.showing)
    watch.update(decibels: -20, now: start.addingTimeInterval(6.2))
    XCTAssertTrue(watch.showing)
    watch.update(decibels: -20, now: start.addingTimeInterval(8.2))
    XCTAssertFalse(watch.showing)
    watch.update(decibels: -80, now: start.addingTimeInterval(8.3))
    XCTAssertFalse(watch.showing)
    watch.update(decibels: -80, now: start.addingTimeInterval(13.3))
    XCTAssertTrue(watch.showing)
    watch.reset()
    XCTAssertFalse(watch.showing)
  }

  func testPCMCopyStaysInsideTheBuffersItWasGiven() {
    XCTAssertEqual(
      PCMCopy.interleavedSampleCount(byteSize: 64, frameCount: 4, channelCount: 2), 8)
    XCTAssertEqual(
      PCMCopy.interleavedSampleCount(byteSize: 12, frameCount: 4, channelCount: 2), 3)
    XCTAssertEqual(PCMCopy.interleavedSampleCount(byteSize: 0, frameCount: 4, channelCount: 2), 0)
    XCTAssertEqual(PCMCopy.interleavedSampleCount(byteSize: 16, frameCount: 0, channelCount: 2), 0)
    XCTAssertEqual(PCMCopy.planarFrameCount(frameLength: 8, stride: 3), 3)
    XCTAssertEqual(PCMCopy.planarFrameCount(frameLength: 2, stride: 8), 2)
    XCTAssertEqual(PCMCopy.planarFrameCount(frameLength: 4, stride: 0), 0)

    let mixed = PCMCopy.interleave(
      channels: [
        [1, 2, 3, 4],
        [10, 20],
      ],
      frameCount: 4
    )
    XCTAssertEqual(mixed, [1, 10, 2, 20, 3, 0, 4, 0])
    XCTAssertEqual(
      MonoDownmix.average(interleaved: mixed, channelCount: 2),
      [5.5, 11, 1.5, 2]
    )
    XCTAssertEqual(PCMCopy.interleave(channels: [[0.5, 0.25]], frameCount: 2), [0.5, 0.25])
    XCTAssertEqual(PCMCopy.interleave(channels: [], frameCount: 4), [])
  }

  func testSupportPaths() {
    let home = URL(fileURLWithPath: "/Users/volunteer")
    XCTAssertEqual(
      AppPaths.configFile(home: home).path,
      "/Users/volunteer/Library/Application Support/Public EarFi/mediamtx.yml"
    )
    XCTAssertEqual(
      AppPaths.logDirectory(home: home).path,
      "/Users/volunteer/Library/Logs/Public EarFi"
    )
    XCTAssertEqual(
      AppPaths.posterFile(home: home).path,
      "/Users/volunteer/Library/Application Support/Public EarFi/Public EarFi poster.pdf"
    )
  }
}
