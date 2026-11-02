import ActivityKit
import AVFoundation
import Darwin
import Foundation
import MediaPlayer
import Network
import StoreKit
import UIKit

enum BroadcastPhase: Equatable {
    case idle
    case starting
    case live
    case stopping
    case reconnecting
}

@MainActor
final class BroadcastModel: ObservableObject {
    @Published var phase: BroadcastPhase = .idle
    @Published var failed = false
    @Published var status = "Ready"
    /// Wi-Fi or hotspot losses this broadcast, shown once it is live again.
    private var dropCount = 0
    private var liveStatus: String {
        if muted { return "Muted. Listeners hear silence." }
        if dropCount == 0 { return "Live" }
        return "Wi-Fi unreliable? Dropped \(dropCount) \(dropCount == 1 ? "time" : "times")."
    }
    @Published var url = ""
    @Published var networkNote = "Join a Wi-Fi network, or turn on Personal Hotspot."
    @Published var listeners = 0
    @Published var level: Float = 0
    @Published var clipping = false
    @Published var inputName = ""
    @Published var qrImage: UIImage?
    @Published var muted = false
    @Published var gain = 1.0
    /// Remembered across launches. Applied only while a USB input is connected.
    @Published var musicPreferred = true // USB always uses Music quality
    @Published var usbInput = false
    @Published var profileText = ""
    @Published var cpuPercent = 0.0
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var batteryLevel: Float = -1
    @Published var sessionName = SessionName.stored
    @Published var wifiPrompt: WifiPrompt = .checking
    @Published var wifiReady = false
    @Published var wifiDown = false
    /// Set when a free session is stopped at 40 minutes, so the paywall opens.
    @Published var freeLimitHit = false
    let store = ProStore()

    var isOnAir: Bool { phase == .live || phase == .reconnecting }
    var musicActive: Bool { musicPreferred && usbInput }

    var listenerLabel: String {
        switch listeners {
        case 0: return "0 listeners"
        case 1: return "1 listener"
        default: return "\(listeners) listeners"
        }
    }

    var statsText: String {
        let cpu = String(format: "CPU %.0f%%", cpuPercent)
        let battery: String
        if batteryLevel < 0 {
            battery = "battery —"
        } else {
            battery = "battery \(Int((batteryLevel * 100).rounded()))%"
        }
        return "\(listenerLabel) · \(cpu) · \(thermalLabel) · \(battery)"
    }

    private var thermalLabel: String {
        switch thermal {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private let capture = AudioCapture()
    private let probe = LocalNetworkProbe()
    private let activity = BroadcastActivityController()
    private let gate = BroadcastServerGate()
    private var monitor: NWPathMonitor?
    private var poll: Timer?
    private var ip = ""
    private var iface = ""
    private var boundIP: String?
    private var boundIface: String?
    private var lastPathKey = ""
    private var sawPath = false
    private var rebindGeneration = 0
    private var rebindRunning = false
    private var rebindAgain = false
    private var remoteInstalled = false
    @Published var startedAt: Date?
    private var cpuSampler = AppCPUSampler()
    private var usbObserver: NSObjectProtocol?
    private var nowPlayingKey = ""
    private lazy var nowPlayingArtwork: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "Logo") else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()
    private let wifiNames = WifiNameSource()
    private var knownSSID: String?
    private var ssidFetched = false
    private var ssidTask: Task<Void, Never>?
    private var ssidTicketIP = ""
    private var acceptedWifi: WifiChoice?
    private var limitTask: Task<Void, Never>?
    private var stopNote: String?
    private var wifiAlertSent = false
    private var wifiDownTask: Task<Void, Never>?
    private var sawAddress = false

    private enum WifiChoice: Equatable {
        case ssid(String)
        case hotspot
        case unnamed
    }

    init() {
        BroadcastBus.start { [weak self] command in
            Task { @MainActor in
                self?.handle(command)
            }
        }
        wifiNames.onAuthorizationChange = { [weak self] in
            guard let self else { return }
            self.ssidFetched = false
            self.syncWifiPrompt()
        }
        activity.endOrphans()
    }

    func appear() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        Task { await self.prepareAddress() }
        if phase == .idle {
            activity.endOrphans()
            refreshUSB()
        }
        observeUSBWhileIdle()
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let key = Self.pathKey(path)
            Task { @MainActor in
                self?.handlePath(key)
            }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    func sceneBecameActive() {
        ssidFetched = false
        Task { await self.refreshAfterActive() }
    }

    func setSessionName(_ raw: String) {
        let name = SessionName.cleaned(raw)
        sessionName = name
        UserDefaults.standard.set(name, forKey: SessionName.key)
    }

    func confirmWifi() {
        switch wifiPrompt {
        case .ssid(let name):
            acceptedWifi = .ssid(name)
        case .hotspot:
            acceptedWifi = .hotspot
        case .unnamed:
            acceptedWifi = .unnamed
        case .checking, .noNetwork:
            return
        }
        wifiReady = true
    }

    func recheckWifi() {
        acceptedWifi = nil
        wifiReady = false
        ssidFetched = false
        knownSSID = nil
        ssidTicketIP = ""
        wifiPrompt = .checking
        Task { await self.updateAddress() }
    }

    func toggle() {
        switch phase {
        case .starting, .stopping:
            return
        case .live, .reconnecting:
            beginStop()
        case .idle:
            beginStart()
        }
    }

    func setMuted(_ value: Bool) {
        muted = value
        capture.setMix(gain: Float(gain), muted: muted)
        updateNowPlaying()
        guard isOnAir else { return }
        if status == "Live" || status == "Muted. Listeners hear silence." {
            status = liveStatus
        }
        pushActivity(force: true)
    }

    func setGain(_ value: Double) {
        let range = BroadcastGain.range(music: musicActive)
        applyGain(min(range.upperBound, max(range.lowerBound, value)))
    }

    func adjustGain(up: Bool) {
        applyGain(BroadcastGain.adjusted(gain, up: up, music: musicActive))
    }

    /// Music is USB-only. The choice is kept when the device is unplugged,
    /// and capture restarts without dropping the listener sessions.
    func setMusicPreferred(_ preferred: Bool) {
        guard musicPreferred != preferred else { return }
        musicPreferred = preferred
        UserDefaults.standard.set(preferred, forKey: "capture.music")
        let range = BroadcastGain.range(music: preferred && usbInput)
        gain = min(range.upperBound, max(range.lowerBound, gain))
        capture.setMusicPreferred(preferred)
        capture.setMix(gain: Float(gain), muted: muted)
    }

    private func applyGain(_ value: Double) {
        gain = value
        capture.setMix(gain: Float(gain), muted: muted)
        if isOnAir {
            pushActivity(force: false)
        }
    }

    private func handle(_ command: BroadcastCommand) {
        switch command {
        case .mute:
            setMuted(true)
        case .unmute:
            setMuted(false)
        case .gainUp:
            adjustGain(up: true)
        case .gainDown:
            adjustGain(up: false)
        }
    }

    private func beginStart() {
        guard phase == .idle else { return }
        phase = .starting
        failed = false
        freeLimitHit = false
        dropCount = 0
        status = "Starting…"
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            Task { await self.startGranted() }
        case .denied:
            failStart("Microphone access is off. Turn it on in Settings → Privacy & Security → Microphone.")
        case .undetermined:
            AVAudioApplication.requestRecordPermission {  [weak self] granted in
                Task { @MainActor in
                    guard let self, self.phase == .starting else { return }
                    if granted {
                        await self.startGranted()
                    } else {
                        self.failStart("Microphone access is off. The broadcast needs the microphone.")
                    }
                }
            }
        @unknown default:
            failStart("Microphone access is unavailable.")
        }
    }

    private func failStart(_ message: String) {
        phase = .idle
        failed = true
        status = message
    }

    private func startGranted() async {
        await Task.yield()
        guard phase == .starting else { return }
        await updateAddress()
        guard phase == .starting else { return }
        guard !ip.isEmpty else {
            failed = true
            phase = .idle
            status = networkNote
            return
        }
        probe.poke(ip: ip)
        wireCapture()
        refreshUSB()
        capture.setMusicPreferred(musicPreferred)
        let range = BroadcastGain.range(music: musicActive)
        gain = min(range.upperBound, max(range.lowerBound, gain))
        capture.setMix(gain: Float(gain), muted: muted)
        let address = ip
        let interfaceName = iface
        let started = Date()
        if let failure = await gate.start(
            ip: address,
            iface: interfaceName,
            title: sessionName,
            host: ListenerHostName.current,
            started: started
        ) {
            capture.stop()
            await gate.stop()
            guard phase == .starting else { return }
            failed = true
            phase = .idle
            status = failure
            return
        }
        guard phase == .starting else {
            await gate.stop()
            return
        }
        do {
            // AVAudioSession.setActive and engine start can take seconds;
            // keep them off the main thread so "Starting…" stays responsive.
            let cap = capture
            try await Task.detached(priority: .userInitiated) { try cap.start() }.value
        } catch {
            capture.stop()
            await gate.stop()
            guard phase == .starting else { return }
            failed = true
            phase = .idle
            status = error.localizedDescription
            return
        }
        guard phase == .starting else {
            capture.stop()
            await gate.stop()
            return
        }
        boundIP = address
        boundIface = interfaceName
        startedAt = started
        phase = .live
        failed = false
        level = 0
        listeners = 0
        cpuSampler.reset()
        sampleStats()
        status = liveStatus
        // Now Playing card dropped: the Live Activity has mute, gain and the meter.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        activity.start(activityState())
        WifiDropNotifier.requestPermission()
        armFreeLimit()
        startPolling()
    }

    private func wireCapture() {
        capture.onPacket = { packet in
            BroadcastServer.publish(packet)
        }
        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.level = level
            }
        }
        capture.onClip = { [weak self] on in
            Task { @MainActor in self?.clipping = on }
        }
        capture.onProfile = { [weak self] text in
            Task { @MainActor in self?.profileText = text }
        }
        capture.onInput = { [weak self] name in
            Task { @MainActor in
                self?.inputName = name
            }
        }
        capture.onInterrupted = { [weak self] interrupted in
            Task { @MainActor in
                guard let self, self.isOnAir else { return }
                if interrupted {
                    self.level = 0
                    self.failed = false
                    self.status = "Interrupted. It resumes when the call ends."
                } else {
                    self.status = self.liveStatus
                }
            }
        }
        capture.onUSB = { [weak self] usb in
            Task { @MainActor in
                self?.noteUSB(usb)
            }
        }
        capture.onCaptureFailure = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isOnAir else { return }
                self.failed = true
                self.status = message
            }
        }
    }

    private func observeUSBWhileIdle() {
        guard usbObserver == nil else { return }
        usbObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .idle else { return }
                self.refreshUSB()
            }
        }
    }

    private func refreshUSB() {
        let usb = AudioCapture.routeIsUSB
        if usbInput != usb {
            usbInput = usb
        }
        clampGainToMode()
    }

    /// Capture already restarted when this arrives during a broadcast.
    /// Do not call `setMusicPreferred` again.
    private func noteUSB(_ usb: Bool) {
        if usbInput != usb {
            usbInput = usb
        }
        clampGainToMode()
        capture.setMix(gain: Float(gain), muted: muted)
    }

    private func clampGainToMode() {
        let range = BroadcastGain.range(music: musicActive)
        let clamped = min(range.upperBound, max(range.lowerBound, gain))
        if clamped != gain {
            gain = clamped
        }
    }

    private func beginStop() {
        guard phase == .live || phase == .reconnecting else { return }
        limitTask?.cancel()
        limitTask = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) }
        phase = .stopping
        status = "Stopping…"
        rebindGeneration += 1
        rebindAgain = false
        rebindRunning = false
        Task { await self.finishStop(duration: duration) }
    }

    private func finishStop(duration: TimeInterval?) async {
        startedAt = nil
        poll?.invalidate()
        poll = nil
        capture.stop()
        await gate.stop()
        guard phase == .stopping else { return }
        phase = .idle
        level = 0
        listeners = 0
        cpuPercent = 0
        inputName = ""
        boundIP = nil
        boundIface = nil
        failed = false
        muted = false
        cpuSampler.reset()
        let note = stopNote
        stopNote = nil
        status = note ?? "Ready"
        wifiDownTask?.cancel()
        wifiDownTask = nil
        wifiDown = false
        wifiAlertSent = false
        WifiDropNotifier.clear()
        activity.end()
        clearRemote()
        syncWifiPrompt()
        if let duration, note == nil {
            requestReviewIfEarned(duration: duration)
        }
    }

    /// Only the Stop button reaches this, and only after the broadcast is down.
    /// A network rebind does not.
    private func requestReviewIfEarned(duration: TimeInterval) {
        guard phase == .idle, ReviewPrompt.noteFinished(duration: duration) else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        ReviewPrompt.markAsked()
        AppStore.requestReview(in: scene)
    }

    private func startPolling() {
        poll?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func pollTick() async {
        guard isOnAir else { return }
        listeners = await gate.listenerCount()
        guard isOnAir else { return }
        sampleStats()
        await updateAddress()
        guard isOnAir else { return }
        if !ip.isEmpty, ip != boundIP {
            scheduleRebind()
        }
        updateNowPlaying()
        pushActivity(force: false)
        enforceFreeLimit()
    }

    private func prepareAddress() async {
        await updateAddress()
        if !ip.isEmpty {
            probe.poke(ip: ip)
        }
    }

    private func refreshAfterActive() async {
        if phase == .idle {
            refreshUSB()
        }
        await updateAddress()
        guard isOnAir else { return }
        listeners = await gate.listenerCount()
        sampleStats()
        if !ip.isEmpty, ip != boundIP {
            scheduleRebind()
        }
        updateNowPlaying()
        pushActivity(force: true)
    }

    private func handlePath(_ key: String) {
        let changed = sawPath && key != lastPathKey
        sawPath = true
        lastPathKey = key
        if changed, isOnAir {
            scheduleRebind()
        }
        Task { await self.updateAddress() }
    }

    private func scheduleRebind() {
        guard isOnAir else { return }
        if rebindRunning {
            rebindAgain = true
            return
        }
        rebindRunning = true
        rebindGeneration += 1
        let generation = rebindGeneration
        Task { @MainActor in
            defer {
                if generation == self.rebindGeneration {
                    self.rebindRunning = false
                    let followUp = self.rebindAgain && self.isOnAir
                    self.rebindAgain = false
                    if followUp {
                        self.scheduleRebind()
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, generation == self.rebindGeneration, self.isOnAir else { return }
            if await self.hostUnchanged() {
                // Back on the same address after a drop: the server never
                // stopped, so just show Live again.
                if self.phase == .reconnecting {
                    self.failed = false
                    self.phase = .live
                    self.status = self.liveStatus
                    self.pushActivity(force: true)
                }
                return
            }
            self.phase = .reconnecting
            self.dropCount += 1
            self.failed = false
            self.status = "Reconnecting…"
            await self.rebind(generation: generation)
        }
    }

    /// Cellular flaps and other path updates must not restart the server.
    /// Stay live when the bound Wi-Fi or hotspot address is still up and is
    /// still the address `selectHost` would pick.
    private func hostUnchanged() async -> Bool {
        guard let boundIP, let boundIface, !boundIP.isEmpty, !boundIface.isEmpty else { return false }
        let present = HostAddress.interfaces().contains { $0.name == boundIface && $0.address == boundIP }
        guard present else { return false }
        let chosen = await gate.selectHost(HostAddress.table())
        let parts = chosen.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 && parts[0] == boundIface && parts[1] == boundIP
    }

    private func rebind(generation: Int) async {
        if await hostUnchanged() {
            guard generation == rebindGeneration, isOnAir else { return }
            if phase == .reconnecting {
                failed = false
                phase = .live
                status = liveStatus
            }
            return
        }
        let previous = boundIP
        for _ in 0..<20 {
            guard generation == rebindGeneration, phase == .reconnecting else { return }
            await updateAddress()
            guard generation == rebindGeneration, phase == .reconnecting else { return }
            if ip.isEmpty {
                failed = false
                status = "Waiting for Wi-Fi or Personal Hotspot…"
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let target = ip
            let interfaceName = iface
            failed = false
            status = "Reconnecting…"
            await gate.stop()
            guard generation == rebindGeneration, phase == .reconnecting else { return }
            if let failure = await gate.start(
                ip: target,
                iface: interfaceName,
                title: sessionName,
                host: ListenerHostName.current,
                started: startedAt ?? Date()
            ) {
                await gate.stop()
                guard generation == rebindGeneration, phase == .reconnecting else { return }
                failed = true
                status = failure
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            guard generation == rebindGeneration, phase == .reconnecting else {
                await gate.stop()
                return
            }
            boundIP = target
            boundIface = interfaceName
            probe.poke(ip: target)
            failed = false
            phase = .live
            if let previous, previous != target {
                status = "Live on a new address. Listeners need the new code."
            } else if muted {
                status = "Muted. Listeners hear silence."
            } else {
                status = liveStatus
            }
            pushActivity(force: true)
            if rebindAgain {
                rebindAgain = false
                phase = .reconnecting
                status = "Reconnecting…"
                try? await Task.sleep(nanoseconds: 400_000_000)
                continue
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard generation == rebindGeneration, isOnAir else { return }
            await updateAddress()
            guard generation == rebindGeneration, isOnAir else { return }
            if ip == target { return }
            phase = .reconnecting
            status = "Reconnecting…"
        }
        guard generation == rebindGeneration, isOnAir else { return }
        if ip.isEmpty {
            failed = true
            status = "Wi-Fi or Personal Hotspot dropped."
        }
    }

    private func updateAddress() async {
        let table = HostAddress.table()
        let chosen = await gate.selectHost(table)
        let parts = chosen.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            iface = parts[0]
            ip = parts[1]
            let nextURL = "http://\(ip):\(BroadcastPorts.http)/"
            if nextURL != url {
                url = nextURL
                qrImage = QRCodeImage.make(nextURL)
            }
            if Self.isPersonalHotspot(ip: ip, iface: iface) {
                networkNote = "Client phones must join this iPhone’s Personal Hotspot. When you start the stream, the join QR code will appear."
            } else {
                networkNote = "Client phones must use same wifi. When you start the stream, the join QR code will appear."
            }
        } else {
            iface = ""
            ip = ""
            if !isOnAir {
                if !url.isEmpty {
                    url = ""
                    qrImage = nil
                }
                networkNote = "Join a Wi-Fi network, or turn on Personal Hotspot."
            }
        }
        sawAddress = true
        syncWifiPrompt()
    }

    private static func isPersonalHotspot(ip: String, iface: String) -> Bool {
        ip == "172.20.10.1" || iface.hasPrefix("bridge")
    }

    private func syncWifiPrompt() {
        noteNetworkPresence()
        if isOnAir { return }
        guard sawAddress else {
            wifiPrompt = .checking
            return
        }
        if ip != ssidTicketIP {
            ssidTicketIP = ip
            ssidFetched = false
            knownSSID = nil
            wifiReady = false
            acceptedWifi = nil
        }
        if ip.isEmpty {
            applyPrompt(.noNetwork)
            return
        }
        if Self.isPersonalHotspot(ip: ip, iface: iface) {
            applyPrompt(.hotspot)
            return
        }
        let status = wifiNames.authorization
        if status == .denied || status == .restricted {
            ssidFetched = true
            applyPrompt(.unnamed(locationDenied: true))
            return
        }
        if !ssidFetched {
            if !wifiReady { applyPrompt(.checking) }
            fetchSSIDIfNeeded()
            return
        }
        if let knownSSID, !knownSSID.isEmpty {
            applyPrompt(.ssid(knownSSID))
        } else {
            applyPrompt(.unnamed(locationDenied: false))
        }
    }

    private func applyPrompt(_ prompt: WifiPrompt) {
        wifiPrompt = prompt
        if isOnAir { return }
        switch prompt {
        case .ssid(let name):
            wifiReady = acceptedWifi == .ssid(name)
        case .hotspot:
            wifiReady = acceptedWifi == .hotspot
        case .unnamed:
            wifiReady = acceptedWifi == .unnamed
        case .checking:
            break
        case .noNetwork:
            wifiReady = false
        }
    }

    private func fetchSSIDIfNeeded() {
        guard ssidTask == nil else { return }
        let ticketIP = ip
        ssidTask = Task { [weak self] in
            guard let self else { return }
            let name = await self.wifiNames.currentSSID()
            self.ssidTask = nil
            guard ticketIP == self.ip else {
                self.ssidFetched = false
                self.syncWifiPrompt()
                return
            }
            self.ssidFetched = true
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.knownSSID = (trimmed?.isEmpty == false) ? trimmed : nil
            self.syncWifiPrompt()
        }
    }

    /// Waits a moment so a one-packet path flap does not cover the screen
    /// or buzz the lock screen. A real drop still shows within about a second.
    private func noteNetworkPresence() {
        let down = isOnAir && ip.isEmpty
        if down {
            guard wifiDownTask == nil, !wifiDown else { return }
            wifiDownTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.wifiDownTask = nil
                guard self.isOnAir, self.ip.isEmpty else { return }
                self.wifiDown = true
                if !self.wifiAlertSent {
                    self.wifiAlertSent = true
                    WifiDropNotifier.post()
                }
            }
        } else {
            wifiDownTask?.cancel()
            wifiDownTask = nil
            if wifiDown {
                wifiDown = false
                wifiAlertSent = false
                WifiDropNotifier.clear()
            }
        }
    }

    private func armFreeLimit() {
        limitTask?.cancel()
        guard !store.isPro, let startedAt else { return }
        let remaining = BroadcastLimits.freeSeconds - Date().timeIntervalSince(startedAt)
        limitTask = Task { [weak self] in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.enforceFreeLimit()
        }
    }

    private func enforceFreeLimit() {
        guard isOnAir, !store.isPro, let startedAt else { return }
        guard Date().timeIntervalSince(startedAt) >= BroadcastLimits.freeSeconds - 0.5 else { return }
        guard !freeLimitHit else { return }
        freeLimitHit = true
        stopNote = "The free 40 minutes are up. Upgrade to Pro for unlimited time."
        beginStop()
    }

    private func sampleStats() {
        cpuPercent = cpuSampler.percent()
        thermal = ProcessInfo.processInfo.thermalState
        batteryLevel = UIDevice.current.batteryLevel
    }

    private func activityState() -> BroadcastAttributes.ContentState {
        let coarse = (Double(level) * 10).rounded() / 10
        return BroadcastAttributes.ContentState(
            listeners: listeners,
            level: min(1, max(0, coarse)),
            muted: muted,
            gain: (gain * 20).rounded() / 20
        )
    }

    private func pushActivity(force: Bool) {
        activity.update(activityState(), force: force)
    }

    private func installRemote() {
        let center = MPRemoteCommandCenter.shared()
        if !remoteInstalled {
            center.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.setMuted(true) }
                return .success
            }
            center.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.setMuted(false) }
                return .success
            }
            remoteInstalled = true
        }
        center.pauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard remoteInstalled else { return }
        let artist = (muted ? "Muted" : "Live") + " · " + listenerLabel
        guard artist != nowPlayingKey else { return }
        nowPlayingKey = artist
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "RoomCast Go",
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: muted ? 0 : 1,
        ]
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearRemote() {
        guard remoteInstalled else { return }
        nowPlayingKey = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.pauseCommand.isEnabled = false
        center.playCommand.isEnabled = false
    }

    /// Wi-Fi, wired Ethernet, and a Personal Hotspot bridge. Cellular is left
    /// out so a cell radio flapping does not look like a new network.
    nonisolated private static func pathKey(_ path: NWPath) -> String {
        let names = path.availableInterfaces.filter { interface in
            switch interface.type {
            case .wifi, .wiredEthernet:
                return true
            case .other:
                return interface.name.hasPrefix("bridge")
            default:
                return false
            }
        }.map { "\($0.type):\($0.name)" }.sorted()
        return "\(path.status)|\(names.joined(separator: ","))"
    }
}

/// Process CPU across every thread, as a percent of one core. It can pass
/// 100 when more than one core is busy. Sampled from the one-second poll.
private struct AppCPUSampler {
    private var lastCPU = 0.0
    private var lastWall = 0.0
    private var primed = false

    mutating func reset() {
        primed = false
    }

    mutating func percent() -> Double {
        let cpu = Self.taskCPUSeconds()
        let wall = ProcessInfo.processInfo.systemUptime
        let result: Double
        if primed, wall > lastWall {
            result = max(0, (cpu - lastCPU) / (wall - lastWall) * 100)
        } else {
            result = 0
        }
        lastCPU = cpu
        lastWall = wall
        primed = true
        return result
    }

    private static func taskCPUSeconds() -> Double {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    private static func seconds(_ time: time_value_t) -> Double {
        Double(time.seconds) + Double(time.microseconds) / 1_000_000
    }
}

/// Local Live Activity. If the phone has Live Activities turned off, start
/// fails quietly and the broadcast still runs.
///
/// `staleDate` is 30 seconds ahead and refreshed while the broadcast is up.
/// If the process is killed without `applicationWillTerminate` (a SIGKILL),
/// the system marks the activity stale instead of leaving a live card up
/// indefinitely. The next launch ends anything still on screen.
final class BroadcastActivityController {
    private static let staleAfter: TimeInterval = 30
    private static let refreshAfter: TimeInterval = 15

    private var current: Activity<BroadcastAttributes>?
    private var last: BroadcastAttributes.ContentState?
    private var lastPush = Date.distantPast

    func start(_ state: BroadcastAttributes.ContentState) {
        last = state
        lastPush = Date()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            current = nil
            return
        }
        do {
            current = try Activity.request(
                attributes: BroadcastAttributes(name: "RoomCast Go"),
                content: content(state),
                pushType: nil
            )
        } catch {
            current = nil
        }
    }

    func update(_ state: BroadcastAttributes.ContentState, force: Bool) {
        guard let current else { return }
        let due = Date().timeIntervalSince(lastPush) >= Self.refreshAfter
        if !force, state == last, !due { return }
        last = state
        lastPush = Date()
        let next = content(state)
        Task { await current.update(next) }
    }

    func end() {
        let ending = current
        current = nil
        last = nil
        guard let ending else { return }
        Task { await ending.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ends activities left by a previous process. The list is captured now
    /// so a broadcast started a moment later is not included.
    func endOrphans() {
        let keep = current?.id
        let existing = Activity<BroadcastAttributes>.activities.filter { $0.id != keep }
        guard !existing.isEmpty else { return }
        Task {
            for activity in existing {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Called from `applicationWillTerminate`. `Activity.end` is async and
    /// does not need the main actor. The wait gives ActivityKit time to
    /// record the immediate dismissal before the process exits.
    static func endAllOnTerminate() {
        let existing = Activity<BroadcastAttributes>.activities
        guard !existing.isEmpty else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in existing {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    private func content(_ state: BroadcastAttributes.ContentState) -> ActivityContent<BroadcastAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }
}

/// Counts Stop presses after a broadcast of at least two minutes, and allows
/// one review request per marketing version.
private enum ReviewPrompt {
    private static let countKey = "review.longBroadcasts"
    private static let askedKey = "review.askedVersion"
    private static let minimum: TimeInterval = 120

    static func noteFinished(duration: TimeInterval) -> Bool {
        guard duration >= minimum else { return false }
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: countKey) + 1
        defaults.set(count, forKey: countKey)
        guard count >= 2 else { return false }
        let version = currentVersion
        return !version.isEmpty && defaults.string(forKey: askedKey) != version
    }

    static func markAsked() {
        let version = currentVersion
        guard !version.isEmpty else { return }
        UserDefaults.standard.set(version, forKey: askedKey)
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
