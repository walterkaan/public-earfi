import ActivityKit
import AVFoundation
import Foundation
import MediaPlayer
import Network
import StoreKit
import UIKit

@MainActor
final class BroadcastModel: ObservableObject {
    @Published var running = false
    @Published var busy = false
    @Published var failed = false
    @Published var status = "Ready"
    @Published var url = ""
    @Published var networkNote = "Join a Wi-Fi network, or turn on Personal Hotspot."
    @Published var listeners = 0
    @Published var level: Float = 0
    @Published var inputName = ""
    @Published var qrImage: UIImage?
    @Published var muted = false
    @Published var gain = 1.0

    var listenerLabel: String {
        switch listeners {
        case 0: return "0 listeners"
        case 1: return "1 listener"
        default: return "\(listeners) listeners"
        }
    }

    private let capture = AudioCapture()
    private let probe = LocalNetworkProbe()
    private let activity = BroadcastActivityController()
    private var monitor: NWPathMonitor?
    private var poll: Timer?
    private var ip = ""
    private var iface = ""
    private var boundIP: String?
    private var lastPathKey = ""
    private var sawPath = false
    private var rebindGeneration = 0
    private var rebindRunning = false
    private var rebindAgain = false
    private var remoteInstalled = false
    private var startedAt: Date?

    init() {
        BroadcastBus.start { [weak self] command in
            Task { @MainActor in
                self?.handle(command)
            }
        }
    }

    func appear() {
        updateAddress()
        if !ip.isEmpty {
            probe.poke(ip: ip)
        }
        if !running {
            activity.endOrphans()
        }
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
        updateAddress()
        guard running else { return }
        listeners = BroadcastServer.listenerCount()
        if !ip.isEmpty, ip != boundIP {
            scheduleRebind()
        }
        pushActivity(force: true)
    }

    func toggle() {
        if running {
            let duration = startedAt.map { Date().timeIntervalSince($0) }
            stopBroadcast(nextStatus: "Ready")
            if let duration {
                requestReviewIfEarned(duration: duration)
            }
        } else {
            beginStart(note: nil)
        }
    }

    func setMuted(_ value: Bool) {
        muted = value
        capture.setMix(gain: Float(gain), muted: muted)
        updateNowPlaying()
        if running {
            if status == "Live" || status == "Muted. Listeners hear silence." {
                status = muted ? "Muted. Listeners hear silence." : "Live"
            }
            pushActivity(force: true)
        }
    }

    func adjustGain(up: Bool) {
        gain = BroadcastGain.adjusted(gain, up: up)
        capture.setMix(gain: Float(gain), muted: muted)
        if running {
            pushActivity(force: true)
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

    private func beginStart(note: String?) {
        guard !busy else { return }
        busy = true
        failed = false
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            startGranted(note: note)
        case .denied:
            busy = false
            failed = true
            status = "Microphone access is off. Turn it on in Settings → Privacy & Security → Microphone."
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.startGranted(note: note)
                    } else {
                        self.busy = false
                        self.failed = true
                        self.status = "Microphone access is off. The broadcast needs the microphone."
                    }
                }
            }
        @unknown default:
            busy = false
            failed = true
            status = "Microphone access is unavailable."
        }
    }

    private func startGranted(note: String?) {
        updateAddress()
        guard !ip.isEmpty else {
            busy = false
            failed = true
            status = networkNote
            return
        }
        probe.poke(ip: ip)
        wireCapture()
        capture.setMix(gain: Float(gain), muted: muted)
        do {
            try BroadcastServer.start(ip: ip, iface: iface)
            try capture.start()
        } catch {
            capture.stop()
            BroadcastServer.stop()
            busy = false
            failed = true
            status = error.localizedDescription
            return
        }
        boundIP = ip
        startedAt = Date()
        running = true
        busy = false
        failed = false
        level = 0
        listeners = 0
        status = note ?? (muted ? "Muted. Listeners hear silence." : "Live")
        installRemote()
        activity.start(activityState())
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
        capture.onInput = { [weak self] name in
            Task { @MainActor in
                self?.inputName = name
            }
        }
        capture.onInterrupted = { [weak self] interrupted in
            Task { @MainActor in
                guard let self, self.running else { return }
                if interrupted {
                    self.level = 0
                    self.failed = false
                    self.status = "Interrupted. It resumes when the call ends."
                } else {
                    self.status = self.muted ? "Muted. Listeners hear silence." : "Live"
                }
            }
        }
    }

    private func stopBroadcast(nextStatus: String) {
        rebindGeneration += 1
        rebindAgain = false
        rebindRunning = false
        startedAt = nil
        poll?.invalidate()
        poll = nil
        capture.stop()
        BroadcastServer.stop()
        running = false
        busy = false
        level = 0
        listeners = 0
        inputName = ""
        boundIP = nil
        failed = false
        muted = false
        status = nextStatus
        activity.end()
        clearRemote()
    }

    /// Only the Stop button reaches this, and only after `running` is false.
    /// A network rebind does not.
    private func requestReviewIfEarned(duration: TimeInterval) {
        guard !running, ReviewPrompt.noteFinished(duration: duration) else { return }
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
                guard let self, self.running else { return }
                self.listeners = BroadcastServer.listenerCount()
                self.updateAddress()
                if !self.ip.isEmpty, self.ip != self.boundIP {
                    self.scheduleRebind()
                }
                self.pushActivity(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func handlePath(_ key: String) {
        let changed = sawPath && key != lastPathKey
        sawPath = true
        lastPathKey = key
        updateAddress()
        guard running, changed else { return }
        scheduleRebind()
    }

    private func scheduleRebind() {
        guard running else { return }
        if rebindRunning {
            rebindAgain = true
            return
        }
        rebindRunning = true
        rebindGeneration += 1
        let generation = rebindGeneration
        Task { @MainActor in
            defer {
                guard generation == self.rebindGeneration else { return }
                self.rebindRunning = false
                let followUp = self.rebindAgain && self.running
                self.rebindAgain = false
                if followUp {
                    self.scheduleRebind()
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, generation == self.rebindGeneration, self.running else { return }
            await self.rebind(generation: generation)
        }
    }

    private func rebind(generation: Int) async {
        let previous = boundIP
        for _ in 0..<20 {
            guard generation == rebindGeneration, running else { return }
            updateAddress()
            if ip.isEmpty {
                failed = false
                status = "Waiting for Wi-Fi or Personal Hotspot…"
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let target = ip
            failed = false
            status = "Reconnecting…"
            BroadcastServer.stop()
            guard generation == rebindGeneration, running else { return }
            do {
                try BroadcastServer.start(ip: ip, iface: iface)
                guard generation == rebindGeneration, running else {
                    BroadcastServer.stop()
                    return
                }
                boundIP = ip
                probe.poke(ip: ip)
                failed = false
                if let previous, previous != ip {
                    status = "Live on a new address. Listeners need the new code."
                } else if muted {
                    status = "Muted. Listeners hear silence."
                } else {
                    status = "Live"
                }
                pushActivity(force: true)
                if rebindAgain {
                    rebindAgain = false
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                updateAddress()
                if ip == target { return }
            } catch {
                failed = true
                status = error.localizedDescription
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard generation == rebindGeneration, running else { return }
        if ip.isEmpty {
            failed = true
            status = "Wi-Fi or Personal Hotspot dropped."
        }
    }

    private func updateAddress() {
        let chosen = BroadcastServer.selectHost(HostAddress.table())
        let parts = chosen.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            iface = parts[0]
            ip = parts[1]
            let nextURL = "http://\(ip):\(BroadcastPorts.http)/"
            if nextURL != url {
                url = nextURL
                qrImage = QRCodeImage.make(nextURL)
            }
            if ip == "172.20.10.1" || iface.hasPrefix("bridge") {
                networkNote = "Personal Hotspot. Listeners join this iPhone’s hotspot, then scan."
            } else {
                networkNote = "Listeners join the same Wi-Fi, then scan."
            }
        } else {
            iface = ""
            ip = ""
            if !running {
                if !url.isEmpty {
                    url = ""
                    qrImage = nil
                }
                networkNote = "Join a Wi-Fi network, or turn on Personal Hotspot."
            }
        }
    }

    private func activityState() -> BroadcastAttributes.ContentState {
        let coarse = (Double(level) * 5).rounded() / 5
        return BroadcastAttributes.ContentState(
            listeners: listeners,
            level: min(1, max(0, coarse)),
            muted: muted,
            gain: gain
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "RoomCast Go",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: muted ? 0 : 1,
        ]
    }

    private func clearRemote() {
        guard remoteInstalled else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.pauseCommand.isEnabled = false
        center.playCommand.isEnabled = false
    }

    private static func pathKey(_ path: NWPath) -> String {
        let names = path.availableInterfaces.map { "\($0.type.rawValue):\($0.name)" }.sorted()
        return "\(path.status)|\(names.joined(separator: ","))"
    }
}

/// Local Live Activity. If the phone has Live Activities turned off, start
/// fails quietly and the broadcast still runs.
final class BroadcastActivityController {
    private var current: Activity<BroadcastAttributes>?
    private var last: BroadcastAttributes.ContentState?

    func start(_ state: BroadcastAttributes.ContentState) {
        last = state
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            current = nil
            return
        }
        do {
            current = try Activity.request(
                attributes: BroadcastAttributes(name: "RoomCast Go"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            current = nil
        }
    }

    func update(_ state: BroadcastAttributes.ContentState, force: Bool) {
        guard let current else { return }
        if !force, state == last { return }
        last = state
        Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        let ending = current
        current = nil
        last = nil
        guard let ending else { return }
        Task { await ending.end(nil, dismissalPolicy: .immediate) }
    }

    func endOrphans() {
        guard current == nil else { return }
        Task {
            for activity in Activity<BroadcastAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
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
