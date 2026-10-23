import AppKit
import Darwin
import SwiftUI

/// Website hero, drawn dimmed behind the main-window cards on dark navy.
///
/// A violet monitor sits on the left, with pink rings expanding behind it.
/// Three teal arcs travel right and fade. Three pink phones on the right,
/// staggered vertically, each carry three teal bars. Buttons stay the brand
/// green; this scene does not. Stopped is dimmer than a live broadcast.
/// Reduce Motion holds one frame, and a hidden window pauses the timeline.
/// The scene is stretched across the window. The card stack is an opaque
/// plate, so the hero stays in the margin and under the title, including
/// when Reduce Transparency is on.
struct BroadcastBackdrop: View {
  var live: Bool
  var level: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pausedByOcclusion = false

  var body: some View {
    let paused = reduceMotion || pausedByOcclusion
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
      Canvas { context, size in
        guard size.width > 2, size.height > 2 else { return }
        let time =
          reduceMotion
          ? HeroMotion.stillTime
          : timeline.date.timeIntervalSinceReferenceDate
        HeroMotion.draw(
          in: &context,
          size: size,
          time: time,
          live: live,
          level: level
        )
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .background(WindowVisibility(isOccluded: $pausedByOcclusion))
  }
}

enum HeroPalette {
  static let backdropHex: UInt32 = 0x0B0A14
  static let violetHex: UInt32 = 0x6B6CF0
  static let pinkHex: UInt32 = 0xFF5FA2
  static let tealHex: UInt32 = 0x3FD9C6
  static let navyHex: UInt32 = 0x121022

  static var backdrop: Color { color(backdropHex) }
  static var violet: Color { color(violetHex) }
  static var pink: Color { color(pinkHex) }
  static var teal: Color { color(tealHex) }
  static var navy: Color { color(navyHex) }

  static func color(_ hex: UInt32) -> Color {
    let red = Double((hex >> 16) & 0xFF) / 255
    let green = Double((hex >> 8) & 0xFF) / 255
    let blue = Double(hex & 0xFF) / 255
    return Color(red: red, green: green, blue: blue)
  }
}

enum HeroMotion {
  static let waveDuration = 2.4
  static let waveStagger = 0.8
  static let waveScaleEnd = 2.2
  static let ringDuration = 3.0
  static let ringStagger = 1.0
  static let ringScaleStart = 0.5
  static let ringScaleEnd = 6.0
  static let ringOpacityStart = 0.7
  static let stillTime = 1.15
  static let arcCount = 3
  static let ringCount = 3
  static let phoneCount = 3
  static let barsPerPhone = 3
  static let sceneSize = CGSize(width: 980, height: 440)
  static let monitor = CGRect(x: 92, y: 96, width: 236, height: 156)
  static let phoneSize = CGSize(width: 86, height: 156)
  /// Left phone highest, middle lowest, right between them.
  static let phoneOrigins = [
    CGPoint(x: 628, y: 72),
    CGPoint(x: 708, y: 128),
    CGPoint(x: 788, y: 96),
  ]

  static func unit(time: Double, duration: Double, delay: Double) -> Double {
    let elapsed = time - delay
    let wrapped = elapsed.truncatingRemainder(dividingBy: duration)
    let positive = wrapped < 0 ? wrapped + duration : wrapped
    return positive / duration
  }

  static func easeOut(_ progress: Double) -> Double {
    let t = min(1, max(0, progress))
    let remaining = 1 - t
    return 1 - remaining * remaining * remaining
  }

  static func waveScale(progress: Double) -> Double {
    1 + (waveScaleEnd - 1) * easeOut(progress)
  }

  static func ringScale(progress: Double) -> Double {
    ringScaleStart + (ringScaleEnd - ringScaleStart) * easeOut(progress)
  }

  static func fade(progress: Double) -> Double {
    1 - easeOut(progress)
  }

  static func ringOpacity(progress: Double) -> Double {
    ringOpacityStart * fade(progress: progress)
  }

  /// How strongly the teal arcs are drawn. Live is brighter than stopped.
  static func presence(live: Bool) -> Double {
    live ? 1 : 0.82
  }

  static func ringStrength(live: Bool) -> Double {
    live ? 0.85 : 0.62
  }

  static func deviceOpacity(live: Bool) -> Double {
    live ? 1 : 0.9
  }

  /// Bar height as a fraction of its maximum. Live follows the input level.
  static func barScale(time: Double, index: Int, live: Bool, level: Double) -> Double {
    let period = 0.85 + Double(index) * 0.11
    let phase = time / period + Double(index) * 0.37
    let wave = 0.5 - 0.5 * cos(phase * 2 * .pi)
    let pulse = 0.30 + 0.70 * wave
    let clamped = min(1, max(0, level))
    let energy = live ? (0.42 + 0.58 * clamped) : 0.34
    return pulse * energy
  }

  static func draw(
    in context: inout GraphicsContext,
    size: CGSize,
    time: Double,
    live: Bool,
    level: Double
  ) {
    context.fill(
      Path(CGRect(origin: .zero, size: size)),
      with: .color(AppChrome.window)
    )
    // Stretch to the window. A fitted scene sat in a short band and the gaps
    // around the cards stayed empty. Dim the illustration on the navy field.
    var scene = context
    scene.scaleBy(x: size.width / sceneSize.width, y: size.height / sceneSize.height)
    var rings = scene
    rings.opacity = AppChrome.heroOpacity
    drawRings(in: &rings, time: time, live: live)
    var arcs = scene
    arcs.opacity = AppChrome.heroOpacity
    drawArcs(in: &arcs, time: time, live: live)
    var devices = scene
    devices.opacity = deviceOpacity(live: live) * AppChrome.heroOpacity
    drawMonitor(in: &devices)
    drawPhones(in: &devices, time: time, live: live, level: level)
  }

  private static func drawRings(in context: inout GraphicsContext, time: Double, live: Bool) {
    let center = CGPoint(x: monitor.midX, y: monitor.midY)
    let strength = ringStrength(live: live)
    for index in 0..<ringCount {
      let progress = unit(
        time: time, duration: ringDuration, delay: Double(index) * ringStagger)
      let alpha = ringOpacity(progress: progress) * strength
      guard alpha > 0.02 else { continue }
      let radius = CGFloat(46 * ringScale(progress: progress))
      let rect = CGRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
      // A soft disc plus a thick stroke, so a 12 pt gap still catches the ring.
      context.fill(
        Path(ellipseIn: rect),
        with: .color(HeroPalette.pink.opacity(alpha * 0.35))
      )
      context.stroke(
        Path(ellipseIn: rect),
        with: .color(HeroPalette.pink.opacity(alpha)),
        lineWidth: 7
      )
    }
  }

  private static func drawArcs(in context: inout GraphicsContext, time: Double, live: Bool) {
    let anchor = CGPoint(x: monitor.maxX + 78, y: monitor.midY)
    let strength = presence(live: live)
    for index in 0..<arcCount {
      let progress = unit(
        time: time, duration: waveDuration, delay: Double(index) * waveStagger)
      let alpha = fade(progress: progress) * strength
      guard alpha > 0.02 else { continue }
      let eased = easeOut(progress)
      let radius = CGFloat(34 * waveScale(progress: progress))
      let center = CGPoint(x: anchor.x + CGFloat(120 * eased), y: anchor.y)
      var path = Path()
      path.addArc(
        center: center,
        radius: radius,
        startAngle: .degrees(-64),
        endAngle: .degrees(64),
        clockwise: true
      )
      context.stroke(
        path,
        with: .color(HeroPalette.teal.opacity(alpha)),
        style: StrokeStyle(lineWidth: 7, lineCap: .round)
      )
    }
  }

  private static func drawMonitor(in context: inout GraphicsContext) {
    let screen = Path(roundedRect: monitor, cornerRadius: 18)
    context.fill(screen, with: .color(HeroPalette.navy))
    context.stroke(screen, with: .color(HeroPalette.violet), lineWidth: 3)
    let dot = CGRect(x: monitor.midX - 8, y: monitor.midY - 8, width: 16, height: 16)
    context.fill(Path(ellipseIn: dot), with: .color(HeroPalette.pink))
    let neck = CGRect(x: monitor.midX - 16, y: monitor.maxY - 2, width: 32, height: 24)
    context.fill(Path(neck), with: .color(HeroPalette.navy))
    context.stroke(Path(neck), with: .color(HeroPalette.violet), lineWidth: 3)
    let base = CGRect(x: monitor.midX - 62, y: neck.maxY - 3, width: 124, height: 12)
    let foot = Path(roundedRect: base, cornerRadius: 4)
    context.fill(foot, with: .color(HeroPalette.navy))
    context.stroke(foot, with: .color(HeroPalette.violet), lineWidth: 3)
  }

  private static func drawPhones(
    in context: inout GraphicsContext,
    time: Double,
    live: Bool,
    level: Double
  ) {
    for (phoneIndex, origin) in phoneOrigins.enumerated() {
      let body = CGRect(origin: origin, size: phoneSize)
      let shape = Path(roundedRect: body, cornerRadius: 18)
      context.fill(shape, with: .color(HeroPalette.navy))
      context.stroke(shape, with: .color(HeroPalette.pink), lineWidth: 2.5)
      let inset = body.insetBy(dx: 16, dy: 18)
      let barWidth: CGFloat = 8
      let gap: CGFloat = 6
      let total = CGFloat(barsPerPhone) * barWidth + CGFloat(barsPerPhone - 1) * gap
      var x = inset.midX - total / 2
      let baseline = inset.maxY
      let maxHeight: CGFloat = live ? 52 : 30
      for bar in 0..<barsPerPhone {
        let scale = barScale(
          time: time, index: phoneIndex * barsPerPhone + bar, live: live, level: level)
        let height = max(3, maxHeight * CGFloat(scale))
        let rect = CGRect(x: x, y: baseline - height, width: barWidth, height: height)
        context.fill(
          Path(roundedRect: rect, cornerRadius: 2),
          with: .color(HeroPalette.teal)
        )
        x += barWidth + gap
      }
    }
  }
}

/// Pauses the hero when this window is hidden, miniaturized, or fully covered.
/// A view that is not in a window yet is not treated as hidden, or the first
/// frames never draw.
private struct WindowVisibility: NSViewRepresentable {
  @Binding var isOccluded: Bool

  func makeNSView(context: Context) -> VisibilityProbe {
    let view = VisibilityProbe()
    view.onChange = { occluded in
      if isOccluded != occluded {
        isOccluded = occluded
      }
    }
    return view
  }

  func updateNSView(_ view: VisibilityProbe, context: Context) {
    view.onChange = { occluded in
      if isOccluded != occluded {
        isOccluded = occluded
      }
    }
  }
}

private final class VisibilityProbe: NSView {
  var onChange: ((Bool) -> Void)?
  private var observers: [NSObjectProtocol] = []
  private var last: Bool?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    guard let window else { return }
    let names = [
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
    ]
    for name in names {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self] _ in
          self?.refresh()
        }
      )
    }
    for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          self?.refresh()
        }
      )
    }
    refresh()
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func refresh() {
    let shown =
      window?.isVisible == true
      && window?.isMiniaturized != true
      && NSApp.isHidden == false
      && window?.occlusionState.contains(.visible) == true
    publish(!shown)
  }

  private func publish(_ shown: Bool) {
    guard last != shown else { return }
    last = shown
    let callback = onChange
    DispatchQueue.main.async {
      callback?(shown)
    }
  }
}
