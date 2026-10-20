import XCTest

@testable import PublicEarFiCore

final class SettingsTests: XCTestCase {
  func testDefaultsMatchTheSpecTable() {
    let settings = AppSettings.defaults
    XCTAssertNil(settings.inputDeviceUID)
    XCTAssertEqual(settings.channelMode, .mono)
    XCTAssertEqual(settings.inputChannel, 1)
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
  }

  func testInvalidSettingsAreRepairedAndPersisted() {
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
      XCTAssertEqual(process.terminationStatus, 0, output)
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
    XCTAssertEqual(CaptureChannelMap.indices(mode: .mono, inputChannel: 2, inputCount: 4), [1])

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
      port: 8889,
      streamName: "live"
    )
    XCTAssertEqual(ip, "http://192.168.1.42:8889/live")
    XCTAssertNil(
      ListenerLink.make(
        style: .ip, ipAddress: nil, localHostname: "Hall-Mac", port: 8889, streamName: "live")
    )
    XCTAssertEqual(
      ListenerLink.make(
        style: .localHostname,
        ipAddress: nil,
        localHostname: "Hall-Mac.local",
        port: 8889,
        streamName: "live"
      ),
      "http://Hall-Mac.local:8889/live"
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
    XCTAssertEqual(ports.map(\.port), [8889, 8189, 8554, 9997])
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
    XCTAssertTrue(report.contains("Recent log (200 lines)"))
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
  }
}
