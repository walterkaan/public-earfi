import AppKit
import PublicEarFiCore
import SwiftUI

@main
struct PublicEarFiApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("RoomCast 1.0 Beta Release") {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 780, minHeight: 748)
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 880, height: 780)
    .commands {
      AppMenus(model: model)
    }

    Settings {
      SettingsTab()
        .environmentObject(model)
        .preferredColorScheme(.dark)
    }

    Window("Poster", id: "poster") {
      PosterTab()
        .environmentObject(model)
        .frame(minWidth: 860, minHeight: 640)
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 980, height: 720)

    Window("Log", id: "log") {
      LogWindow()
        .environmentObject(model)
        .frame(minWidth: 520, minHeight: 320)
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 720, height: 480)
  }
}

struct AppMenus: Commands {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About RoomCast") {
        model.showAboutPanel()
      }
    }
    // Settings is the scene below the app name (Cmd-,). It is not in File.
    CommandGroup(replacing: .newItem) {}
    CommandGroup(replacing: .printItem) {
      Button("Poster…") {
        openWindow(id: "poster")
      }
      .keyboardShortcut("p", modifiers: [.command])
    }
    CommandGroup(replacing: .importExport) {
      Button("Export Poster PDF…") {
        model.exportPosterPDF()
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
    }
    CommandGroup(after: .pasteboard) {
      Button("Copy Listener Link") {
        model.copyLink()
      }
      .disabled(model.listenerURL == nil)
      Button("Copy QR Image") {
        model.copyQRImage()
      }
      .disabled(model.listenerURL == nil)
    }
    CommandGroup(after: .toolbar) {
      Button("Show Log") {
        openWindow(id: "log")
      }
      .keyboardShortcut("l", modifiers: [.command])
    }
    CommandGroup(replacing: .help) {
      Button("Getting Started") {
        model.reopenGettingStarted()
      }
      Button("Broadcast music from an app") {
        model.openMusicFAQ()
      }
    }
  }
}

enum AppIdentity {
  /// Display name from the bundle, so a rename of the app follows the
  /// default listener title without a stored string.
  static var name: String {
    let info = Bundle.main.infoDictionary
    if let display = info?["CFBundleDisplayName"] as? String,
      !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return display
    }
    if let bundle = info?["CFBundleName"] as? String,
      !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return bundle
    }
    return BroadcastTitle.fallbackAppName
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      AppModel.shared?.shutdown()
    }
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      AppModel.shared?.shutdown()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
