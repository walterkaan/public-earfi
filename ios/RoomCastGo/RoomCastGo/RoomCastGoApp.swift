import SwiftUI
import UIKit
import UserNotifications

final class RoomCastAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Swiping the app away while audio is running usually delivers this.
    /// A SIGKILL does not. The Live Activity's stale date covers that case,
    /// and the next launch ends anything still on screen.
    func applicationWillTerminate(_ application: UIApplication) {
        BroadcastActivityController.endAllOnTerminate()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The in-app alert is the foreground banner. Still file the
        // notification and play the sound.
        [.list, .sound]
    }
}

@main
struct RoomCastGoApp: App {
    @UIApplicationDelegateAdaptor(RoomCastAppDelegate.self) private var appDelegate
    @StateObject private var model = BroadcastModel()

    var body: some Scene {
        WindowGroup {
            BroadcastView(model: model, store: model.store)
        }
    }
}
