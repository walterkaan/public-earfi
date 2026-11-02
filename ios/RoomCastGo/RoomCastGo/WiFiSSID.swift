import CoreLocation
import Foundation
import NetworkExtension
import UserNotifications

enum NetworkChoice: Equatable {
    case checking
    case wifi(ssid: String)
    case unnamedWiFi(locationDenied: Bool)
    case hotspot
    case offline
}

/// Reads the joined Wi-Fi name. iOS only returns it when the app has the
/// Access Wi-Fi Information entitlement and When-In-Use location permission
/// (precise, if the system has reduced accuracy). Personal Hotspot is not a
/// joined network, so this stays nil while the phone is the hotspot.
final class WiFiSSIDFetcher: NSObject, CLLocationManagerDelegate {
    struct Update {
        var ssid: String?
        var denied: Bool
    }

    var onUpdate: ((Update) -> Void)?

    private let location = CLLocationManager()
    private var asked = false

    func start() {
        if location.delegate == nil {
            location.delegate = self
        } else {
            resolve()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        resolve()
    }

    private func resolve() {
        switch location.authorizationStatus {
        case .notDetermined:
            guard !asked else { return }
            asked = true
            location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if location.accuracyAuthorization == .reducedAccuracy {
                location.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WifiSSID") { [weak self] _ in
                    self?.fetch()
                }
            } else {
                fetch()
            }
        case .denied, .restricted:
            deliver(ssid: nil, denied: true)
        @unknown default:
            deliver(ssid: nil, denied: true)
        }
    }

    private func fetch() {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let raw = network?.ssid.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.deliver(ssid: raw.isEmpty ? nil : raw, denied: false)
        }
    }

    private func deliver(ssid: String?, denied: Bool) {
        let update = Update(ssid: ssid, denied: denied)
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(update)
        }
    }
}

enum WiFiDropNotice {
    static let id = "wifi-dropped"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post() {
        let content = UNMutableNotificationContent()
        content.title = "Wi-Fi dropped"
        content.body = "RoomCast Go lost Wi-Fi. Listeners can’t hear you until this iPhone is back on Wi-Fi or Personal Hotspot."
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
