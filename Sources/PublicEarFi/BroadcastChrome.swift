import AppKit
import SwiftUI
import UserNotifications

/// Loads the packaged RoomCast icon, falling back to the application icon image.
enum RoomCastIcon {
  static var image: NSImage {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    {
      return image
    }
    if let named = NSImage(named: "AppIcon") {
      return named
    }
    return NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 128, height: 128))
  }
}

/// Local alerts when Wi-Fi drops or returns while broadcasting.
enum BroadcastNotifier {
  private static let category = "roomcast.network"

  static func requestPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  static func wifiLost() {
    post(id: "wifi-lost", title: "RoomCast", body: "Wi-Fi was lost while broadcasting.")
  }

  static func wifiRestored() {
    post(
      id: "wifi-restored", title: "RoomCast",
      body: "Wi-Fi is back. Share the listener link again if the address changed.")
  }

  private static func post(id: String, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "\(category).\(id).\(UUID().uuidString)",
      content: content,
      trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }
}

/// Floating translucent mini-player while broadcasting with the main window
/// miniaturised or the app in the background.
@MainActor
final class MiniPlayerController {
  static let shared = MiniPlayerController()

  private var panel: NSPanel?
  private var hosting: NSHostingView<MiniPlayerView>?
  private var model: AppModel?
  private let positionKey = "roomcast.miniPlayer.origin"

  func attach(model: AppModel) {
    self.model = model
  }

  func sync() {
    guard let model else { return }
    let want = shouldShow(for: model)
    if want {
      show(model: model)
      hosting?.rootView = MiniPlayerView(
        model: model,
        onStop: { [weak model] in
          model?.toggleBroadcast()
        },
        onReveal: { [weak self] in
          self?.revealMainWindow()
        })
    } else {
      hide()
    }
  }

  private func shouldShow(for model: AppModel) -> Bool {
    guard model.isBroadcasting else { return false }
    if NSApp.isActive, let main = Self.mainWindow(), main.isVisible, !main.isMiniaturized {
      return false
    }
    return true
  }

  private func show(model: AppModel) {
    if panel == nil {
      let view = MiniPlayerView(
        model: model,
        onStop: { [weak model] in
          model?.toggleBroadcast()
        },
        onReveal: { [weak self] in
          self?.revealMainWindow()
        })
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(x: 0, y: 0, width: 220, height: 78)
      let panel = NSPanel(
        contentRect: host.frame,
        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
        backing: .buffered,
        defer: false)
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.ignoresMouseEvents = false
      panel.hidesOnDeactivate = false
      panel.isMovableByWindowBackground = true
      panel.contentView = host
      panel.setFrameOrigin(initialOrigin(size: host.frame.size))
      NotificationCenter.default.addObserver(
        forName: NSWindow.didMoveNotification, object: panel, queue: .main
      ) { [weak self] note in
        guard let self, let window = note.object as? NSWindow else { return }
        UserDefaults.standard.set(
          NSStringFromPoint(window.frame.origin), forKey: self.positionKey)
      }
      self.panel = panel
      self.hosting = host
    }
    panel?.orderFrontRegardless()
  }

  private func initialOrigin(size: NSSize) -> NSPoint {
    if let saved = UserDefaults.standard.string(forKey: positionKey) {
      let origin = NSPointFromString(saved)
      // Zero origin usually means a failed parse; fall through to default.
      if origin != .zero {
        return clampedOrigin(origin, size: size)
      }
    }
    guard let screen = NSScreen.main else { return .zero }
    let visible = screen.visibleFrame
    // Default: top-right of the visible screen.
    return NSPoint(
      x: visible.maxX - size.width - 24,
      y: visible.maxY - size.height - 24)
  }

  private func hide() {
    panel?.orderOut(nil)
  }

  private func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
    guard
      let screen = NSScreen.screens.first(where: {
        $0.frame.contains(origin)
      }) ?? NSScreen.main
    else { return origin }
    let visible = screen.visibleFrame
    return NSPoint(
      x: min(max(origin.x, visible.minX), visible.maxX - size.width),
      y: min(max(origin.y, visible.minY), visible.maxY - size.height))
  }

  private func revealMainWindow() {
    AppDelegate.reopenMainWindow()
  }

  /// Prefer the visible main window; otherwise any RoomCast document window
  /// that is not the floating mini-player (including closed/hidden ones).
  static func mainWindow() -> NSWindow? {
    let candidates = NSApp.windows.filter { window in
      if window is NSPanel { return false }
      if window == MiniPlayerController.shared.panel { return false }
      let title = window.title
      return title.hasPrefix("RoomCast")
    }
    if let visible = candidates.first(where: { $0.isVisible && !$0.isMiniaturized }) {
      return visible
    }
    if let mini = candidates.first(where: \.isMiniaturized) {
      return mini
    }
    return candidates.first
  }
}

private struct MiniPlayerView: View {
  @ObservedObject var model: AppModel
  var onStop: () -> Void
  var onReveal: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: RoomCastIcon.image)
        .resizable()
        .interpolation(.high)
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(model.isBroadcasting ? "Live" : "Idle")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(AppChrome.heading)
        Text("\(model.listeners) listening")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.9))
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.15))
            Capsule()
              .fill(AppChrome.heading)
              .frame(width: max(2, geo.size.width * model.levelFraction))
          }
        }
        .frame(height: 6)
      }
      Button(action: onStop) {
        Image(systemName: "stop.fill")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 28, height: 28)
          .background(Circle().fill(Color.red.opacity(0.85)))
      }
      .buttonStyle(.plain)
      .help("Stop broadcasting")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: 220, height: 78)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.ultraThinMaterial)
        .opacity(0.92)
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
    }
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .onTapGesture(count: 2, perform: onReveal)
  }
}

/// Dock badge (listener count) and a light VU bar drawn into the dock tile.
@MainActor
final class DockFeedback {
  static let shared = DockFeedback()

  private var meterView: DockMeterView?
  private var active = false

  func sync(listeners: Int, level: Double, broadcasting: Bool) {
    let tile = NSApp.dockTile
    if broadcasting {
      tile.badgeLabel = listeners > 0 ? "\(listeners)" : " "
      if meterView == nil {
        let view = DockMeterView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        meterView = view
        tile.contentView = view
      }
      meterView?.level = level
      meterView?.needsDisplay = true
      tile.display()
      active = true
    } else if active {
      tile.badgeLabel = nil
      tile.contentView = nil
      meterView = nil
      tile.display()
      active = false
    }
  }
}

private final class DockMeterView: NSView {
  var level: Double = 0

  override func draw(_ dirtyRect: NSRect) {
    let icon = RoomCastIcon.image
    let bounds = self.bounds
    icon.draw(
      in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: nil)
    let barHeight = max(2, bounds.height * 0.12)
    let inset = bounds.width * 0.18
    let barWidth = bounds.width - inset * 2
    let y = bounds.height * 0.12
    let track = NSRect(x: inset, y: y, width: barWidth, height: barHeight)
    NSColor.black.withAlphaComponent(0.45).setFill()
    NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    let fill = NSRect(
      x: inset, y: y, width: max(2, barWidth * max(0, min(1, level))), height: barHeight)
    NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 0.95).setFill()
    NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
  }
}
