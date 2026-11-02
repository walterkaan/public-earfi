import CoreLocation
import Foundation
import NetworkExtension
import UIKit
import UserNotifications

/// What the launch screen asks the host to confirm before Start appears.
enum WifiPrompt: Equatable {
    case checking
    case ssid(String)
    case hotspot
    case unnamed(locationDenied: Bool)
    case noNetwork
}

/// Name shown as "from …" on the listener page. iOS 16 and later returns a
/// generic "iPhone" from `UIDevice.name` unless Apple has granted the
/// user-assigned device name entitlement, so a real hostname is preferred
/// when the device name is generic.
enum ListenerHostName {
    static var current: String {
        let device = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["iPhone", "iPad", "iPod touch", "iPod"]
        if !device.isEmpty, !generic.contains(device) {
            return device
        }
        var host = ProcessInfo.processInfo.hostName
        if host.lowercased().hasSuffix(".local") {
            host = String(host.dropLast(".local".count))
        }
        host = host.replacingOccurrences(of: "-", with: " ")
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty { return host }
        if !device.isEmpty { return device }
        return "this iPhone"
    }
}

enum WifiDropNotifier {
    static let id = "channel.roomcast.go.wifi-dropped"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post() {
        let content = UNMutableNotificationContent()
        content.title = "Wi-Fi dropped"
        content.body = "RoomCast Go lost the network. Listeners can’t hear you until Wi-Fi or Personal Hotspot is back."
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}

/// Reads the joined Wi-Fi name. iOS only returns it after Location is
/// allowed and the Access Wi-Fi Information entitlement is on the App ID.
@MainActor
final class WifiNameSource: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var fixContinuation: CheckedContinuation<Void, Never>?
    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorization: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func currentSSID() async -> String? {
        let status = await ensureAuthorization()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        await ensurePrecise()
        await waitForFix()
        return await fetchSSID()
    }

    private func ensureAuthorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            self.authContinuation = continuation
            self.manager.requestWhenInUseAuthorization()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                self.resumeAuth(self.manager.authorizationStatus)
            }
        }
    }

    private func ensurePrecise() async {
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WifiSSID") { _ in
                continuation.resume()
            }
        }
    }

    private func waitForFix() async {
        await withCheckedContinuation { continuation in
            self.fixContinuation = continuation
            self.manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.resumeFix()
            }
        }
    }

    private func fetchSSID() async -> String? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce<String?> { continuation.resume(returning: $0) }
            NEHotspotNetwork.fetchCurrent { network in
                once.call(network?.ssid)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                once.call(nil)
            }
        }
    }

    private func resumeAuth(_ status: CLAuthorizationStatus) {
        guard status != .notDetermined else { return }
        let continuation = authContinuation
        authContinuation = nil
        continuation?.resume(returning: status)
    }

    private func resumeFix() {
        let continuation = fixContinuation
        fixContinuation = nil
        continuation?.resume()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.resumeAuth(status)
            if status != .notDetermined {
                self.onAuthorizationChange?()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.resumeFix() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resumeFix() }
    }
}

/// Resumes a continuation once, from whichever callback wins.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let resume: (T) -> Void

    init(_ resume: @escaping (T) -> Void) {
        self.resume = resume
    }

    func call(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        resume(value)
    }
}
