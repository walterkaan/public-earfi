import AVFoundation
import Foundation
import Network
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

    var listenerLabel: String {
        switch listeners {
        case 0: return "0 listeners"
        case 1: return "1 listener"
        default: return "\(listeners) listeners"
        }
    }

    private let capture = AudioCapture()
    private let probe = LocalNetworkProbe()
    private var monitor: NWPathMonitor?
    private var poll: Timer?
    private var ip = ""
    private var iface = ""
    private var boundIP: String?
    private var restarting = false

    func appear() {
        refreshAddress()
        if !ip.isEmpty {
            probe.poke(ip: ip)
        }
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.refreshAddress()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    func sceneBecameActive() {
        refreshAddress()
        if running {
            listeners = BroadcastServer.listenerCount()
        }
    }

    func toggle() {
        if running {
            stopBroadcast(nextStatus: "Ready")
        } else {
            beginStart(note: nil)
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
        refreshAddress()
        guard !ip.isEmpty else {
            busy = false
            failed = true
            status = networkNote
            return
        }
        probe.poke(ip: ip)
        wireCapture()
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
        running = true
        busy = false
        failed = false
        level = 0
        status = note ?? "Live"
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
                    self.status = "Live"
                }
            }
        }
    }

    private func stopBroadcast(nextStatus: String) {
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
        status = nextStatus
    }

    private func startPolling() {
        poll?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.listeners = BroadcastServer.listenerCount()
                self.refreshAddress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func refreshAddress() {
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
            if !url.isEmpty {
                url = ""
                qrImage = nil
            }
            networkNote = "Join a Wi-Fi network, or turn on Personal Hotspot."
        }

        guard running, !restarting else { return }
        if ip.isEmpty {
            failed = true
            status = "Wi-Fi or Personal Hotspot dropped. The broadcast may have stopped."
            return
        }
        guard let boundIP else { return }
        if ip == boundIP {
            if failed {
                failed = false
                status = "Live"
            }
            return
        }
        restarting = true
        stopBroadcast(nextStatus: "The network changed. Starting at the new address.")
        beginStart(note: "The network changed. Listeners need the new code.")
        restarting = false
    }
}
