import AppKit
import SwiftUI

@main
struct PublicEarFiApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 780, minHeight: 640)
    }
    .defaultSize(width: 880, height: 720)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Public EarFi") {
          model.showAboutPanel()
        }
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      AppModel.shared?.shutdown()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
