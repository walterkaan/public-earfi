import SwiftUI
import UIKit

final class RoomCastAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BroadcastActivityController.endAllSynchronously()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        BroadcastActivityController.endAllSynchronously()
    }
}

@main
struct RoomCastGoApp: App {
    @UIApplicationDelegateAdaptor(RoomCastAppDelegate.self) private var appDelegate
    @StateObject private var model = BroadcastModel()

    var body: some Scene {
        WindowGroup {
            BroadcastView(model: model)
        }
    }
}
