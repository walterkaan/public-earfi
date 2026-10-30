import AppKit
import PublicEarFiCore
import SwiftUI

@main
enum RoomCastMain {
  static func main() {
    if CommandLine.arguments.contains("--listener-page-self-test") {
      exit(ListenerPageSelfTest.run())
    }
    PublicEarFiApp.main()
  }
}

struct PublicEarFiApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("RoomCast 1.0 Beta Release", id: "main") {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 620, minHeight: 820)
        .preferredColorScheme(.dark)
        .background(MainWindowLifecycle(model: model, appDelegate: appDelegate))
    }
    .defaultSize(width: 680, height: 860)
    .commands {
      AppMenus(model: model)
    }

    Settings {
      SettingsTab()
        .environmentObject(model)
        .frame(width: 700, height: 600)
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

/// Hooks openWindow and AppKit lifecycle into the main WindowGroup.
private struct MainWindowLifecycle: View {
  @ObservedObject var model: AppModel
  var appDelegate: AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onAppear {
        AppDelegate.shared = appDelegate
        appDelegate.model = model
        appDelegate.openMainWindow = { openWindow(id: "main") }
        MiniPlayerController.shared.attach(model: model)
        BroadcastNotifier.requestPermission()
        model.refreshChrome()
      }
      .onReceive(NotificationCenter.default.publisher(for: .roomCastOpenMainWindow)) { _ in
        openWindow(id: "main")
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
        model.refreshChrome()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
        model.refreshChrome()
      }
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
      Button("Copy Diagnostics") {
        model.copyDiagnostics()
      }
    }
    CommandGroup(after: .toolbar) {
      Button("Show Log") {
        openWindow(id: "log")
      }
      .keyboardShortcut("l", modifiers: [.command])
    }
    CommandMenu("Broadcast") {
      Button(model.isBroadcasting ? "Stop Broadcasting" : "Start Broadcasting") {
        model.toggleBroadcast()
      }
      .keyboardShortcut("b", modifiers: [.command])
    }
    CommandGroup(replacing: .help) {
      Button("Getting Started") {
        model.reopenGettingStarted()
      }
      Button("Broadcast music from an app") {
        model.openMusicFAQ()
      }
      Button("RoomCast FAQ") {
        model.openFAQ()
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
  static weak var shared: AppDelegate?
  weak var model: AppModel?
  var openMainWindow: (() -> Void)?

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

  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    MainActor.assumeIsolated {
      Self.reopenMainWindow()
      model?.refreshChrome()
    }
    return true
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    MainActor.assumeIsolated {
      // Closed main window (not merely miniaturised): bring it back.
      let main = MiniPlayerController.mainWindow()
      if main == nil || !(main?.isVisible ?? false) {
        Self.reopenMainWindow()
      }
      model?.refreshChrome()
    }
  }

  func applicationDidResignActive(_ notification: Notification) {
    MainActor.assumeIsolated {
      model?.refreshChrome()
    }
  }

  /// Brings the main broadcast window back when it was closed or miniaturised.
  @MainActor
  static func reopenMainWindow() {
    if let window = MiniPlayerController.mainWindow() {
      if window.isMiniaturized {
        window.deminiaturize(nil)
      }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    // SwiftUI dropped the WindowGroup instance; open a fresh one.
    let conf = NSApplication.shared.windows
    for window in conf where window.title.hasPrefix("RoomCast") {
      window.makeKeyAndOrderFront(nil)
      return
    }
    shared?.openMainWindow?()
    NotificationCenter.default.post(name: .roomCastOpenMainWindow, object: nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

extension Notification.Name {
  static let roomCastOpenMainWindow = Notification.Name("roomCastOpenMainWindow")
}
