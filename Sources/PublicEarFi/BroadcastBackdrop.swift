import AppKit
import Darwin
import SwiftUI

/// Website hero, drawn behind the main-window cards.
///
/// Three arcs move right and scale to 2.2× over 2.4 s, staggered by 0.8 s.
/// Three rings scale from 0.5× to 6× and fade from 0.7 opacity over 3 s,
/// staggered by 1 s. Equaliser bars pulse on scaleY. Stopped stays fainter
/// than a live broadcast. Reduce Motion holds one frame, and a hidden or
/// fully occluded window pauses the timeline.
struct BroadcastBackdrop: View {
  var live: Bool
  var level: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var windowVisible = true

  var body: some View {
    let paused = reduceMotion || !windowVisible
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
      Canvas { context, size in
        guard windowVisible, size.width > 2, size.height > 2 else { return }
        let time =
          reduceMotion
          ? HeroMotion.stillTime
          : timeline.date.timeIntervalSinceReferenceDate
        HeroMotion.draw(
          in: context,
          size: size,
          time: time,
          live: live,
          level: level
        )
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .background(WindowVisibility(isVisible: $windowVisible))
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
  static let barCount = 7

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
    ringOpacityStart * fade(progress)
  }

  /// How strongly the hero is drawn. Live is brighter; stopped stays calm.
  static func presence(live: Bool) -> Double {
    live ? 0.48 : 0.26
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
    let anchor = CGPoint(x: size.width * 0.50, y: size.height * 0.40)
    let gain = presence(live: live)
    let green = AppChrome.startButton
    for index in 0..<ringCount {
      let progress = unit(time: time, duration: ringDuration, delay: Double(index) * ringStagger)
      let alpha = ringOpacity(progress: progress) * gain
      guard alpha > 0.015 else { continue }
      let radius = CGFloat(40 * ringScale(progress: progress))
      let rect = CGRect(
        x: anchor.x - radius,
        y: anchor.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      context.stroke(
        Path(ellipseIn: rect),
        with: .color(green.opacity(alpha)),
        lineWidth: 1.25
      )
    }
    for index in 0..<arcCount {
      let progress = unit(time: time, duration: waveDuration, delay: Double(index) * waveStagger)
      let alpha = fade(progress: progress) * gain
      guard alpha > 0.015 else { continue }
      let eased = easeOut(progress)
      let radius = CGFloat(36 * waveScale(progress: progress))
      let center = CGPoint(x: anchor.x - 28 + CGFloat(78 * eased), y: anchor.y)
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
        with: .color(green.opacity(alpha)),
        style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
      )
    }
    drawBars(
      in: &context,
      size: size,
      time: time,
      live: live,
      level: level,
      green: green,
      gain: gain
    )
  }

  private static func drawBars(
    in context: inout GraphicsContext,
    size: CGSize,
    time: Double,
    live: Bool,
    level: Double,
    green: Color,
    gain: Double
  ) {
    let barWidth: CGFloat = 6
    let gap: CGFloat = 8
    let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
    var x = (size.width - total) / 2
    let baseline = size.height * 0.64
    let maxHeight: CGFloat = live ? 92 : 52
    let alpha = gain * 0.9
    for index in 0..<barCount {
      let scale = barScale(time: time, index: index, live: live, level: level)
      let height = max(2, maxHeight * CGFloat(scale))
      let rect = CGRect(x: x, y: baseline - height, width: barWidth, height: height)
      context.fill(
        Path(roundedRect: rect, cornerRadius: 2),
        with: .color(green.opacity(alpha))
      )
      x += barWidth + gap
    }
  }
}

/// Pauses the hero when this window is hidden, miniaturized, or fully covered.
private struct WindowVisibility: NSViewRepresentable {
  @Binding var isVisible: Bool

  func makeNSView(context: Context) -> VisibilityProbe {
    let view = VisibilityProbe()
    view.onChange = { visible in
      if isVisible != visible {
        isVisible = visible
      }
    }
    return view
  }

  func updateNSView(_ view: VisibilityProbe, context: Context) {
    view.onChange = { visible in
      if isVisible != visible {
        isVisible = visible
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
    guard let window else {
      publish(false)
      return
    }
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
    publish(shown)
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
