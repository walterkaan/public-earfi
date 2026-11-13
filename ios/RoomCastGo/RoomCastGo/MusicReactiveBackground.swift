import Combine
import SwiftUI
import UIKit

/// Soft backdrop for the main RoomCast Go screen.
///
/// Driven by the level the capture path already publishes. Nothing here
/// touches the encoder. On battery the field is a slow gradient. While the
/// phone is charging or full it adds a few drifting color blobs. Stopped,
/// Reduce Motion, and a backgrounded app all fall back to a calm picture.
///
/// Override with UserDefaults key `visualizer.mode`:
/// `auto` (default), `off`, `gentle`, or `rich`.
struct MusicReactiveBackground: View {
    var level: Float
    var live: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var preference = MusicBackdropPreference.stored
    @State private var pluggedIn = false
    @StateObject private var motion = BackdropMotion()

    var body: some View {
        let look = resolvedLook
        let moving = scenePhase == .active && !reduceMotion && look != .off
        ZStack {
            Color.roomNavy
            if look != .off {
                TimelineView(.animation(minimumInterval: interval(for: look), paused: !moving)) { timeline in
                    let shown = reduceMotion ? Look.idle : look
                    let sample = motion.step(
                        to: timeline.date,
                        running: moving,
                        target: moving && live ? drivenLevel : 0,
                        pace: pace(for: look)
                    )
                    Canvas { context, size in
                        BackdropField.paint(
                            &context,
                            size: size,
                            look: shown,
                            phase: sample.phase,
                            low: moving ? sample.low : 0,
                            mid: moving ? sample.mid : 0,
                            high: moving ? sample.high : 0
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            refreshPower()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshPreference()
        }
    }

    /// The meter is already 0 at about −50 dB and 1 at 0 dB. A curve lifts
    /// ordinary speech, which often sits around 0.3–0.6, so the field moves
    /// with the sound instead of staying near the navy floor.
    private var drivenLevel: Float {
        let clamped = min(1, max(0, level))
        return pow(clamped, 0.55)
    }

    /// Auto follows the charger. A stopped broadcast stays on the idle
    /// gradient even if the override asks for gentle or rich. Battery uses
    /// gentle, which is still meant to be obvious while sound is coming in.
    private var resolvedLook: Look {
        switch preference {
        case .off:
            return .off
        case .gentle:
            return live ? .gentle : .idle
        case .rich:
            return live ? .rich : .idle
        case .auto:
            guard live else { return .idle }
            return pluggedIn ? .rich : .gentle
        }
    }

    private func interval(for look: Look) -> Double {
        switch look {
        case .off, .idle:
            return 0.5
        case .gentle:
            return 1.0 / 20.0
        case .rich:
            return 1.0 / 30.0
        }
    }

    /// Seconds of motion added per real second. Idle barely drifts.
    private func pace(for look: Look) -> Double {
        switch look {
        case .off:
            return 0
        case .idle:
            return 0.16
        case .gentle:
            return 1.15
        case .rich:
            return 1.35
        }
    }

    private func refresh() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshPower()
        refreshPreference()
    }

    private func refreshPower() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let state = device.batteryState
        let next = state == .charging || state == .full
        if next != pluggedIn { pluggedIn = next }
    }

    private func refreshPreference() {
        let next = MusicBackdropPreference.stored
        if next != preference { preference = next }
    }
}

private enum Look {
    case off
    case idle
    case gentle
    case rich
}

enum MusicBackdropPreference: String, CaseIterable, Identifiable {
    case auto
    case gentle
    case rich
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .gentle: return "Gentle"
        case .rich: return "Rich"
        case .off: return "Off"
        }
    }

    static let defaultsKey = "visualizer.mode"

    static var stored: MusicBackdropPreference {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return .auto }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MusicBackdropPreference(rawValue: cleaned) ?? .auto
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Keeps the phase and a smoothed level across frames. The meter already
/// arrives smoothed; this only stops the picture from stepping.
///
/// Low / mid / high are three speeds of that one level (slow body, the
/// level itself, and sudden rises). The capture callback is left alone,
/// so there is no FFT and no extra tap.
private final class BackdropMotion: ObservableObject {
    struct Sample {
        var phase: Double
        var low: Float
        var mid: Float
        var high: Float
    }

    private var phase: Double = 0
    private var low: Float = 0
    private var mid: Float = 0
    private var high: Float = 0
    private var lastDate: Date?
    private var lastRunning = false
    private var cached: Sample?

    func step(to date: Date, running: Bool, target: Float, pace: Double) -> Sample {
        if lastDate == date, lastRunning == running, let cached {
            return cached
        }
        if let lastDate, date < lastDate, let cached {
            return cached
        }
        let elapsed: Double
        if let lastDate {
            elapsed = min(0.5, max(0, date.timeIntervalSince(lastDate)))
        } else {
            elapsed = 0
        }
        lastDate = date
        lastRunning = running
        if running, elapsed > 0 {
            phase += elapsed * pace
            // One frame of smoothing even if the clock jumped while paused,
            // so coming back on air does not flash to full brightness.
            let dt = Float(min(elapsed, 1.0 / 20.0))
            let aim = min(1, max(0, target))
            let previous = mid
            low += (aim - low) * response(dt, seconds: 0.90)
            mid += (aim - mid) * response(dt, seconds: 0.36)
            let attack = max(0, aim - previous)
            high += (attack - high) * response(dt, seconds: 0.18)
        } else if !running {
            low = 0
            mid = 0
            high = 0
        }
        let sample = Sample(phase: phase, low: low, mid: mid, high: high)
        cached = sample
        return sample
    }

    private func response(_ dt: Float, seconds: Float) -> Float {
        1 - Float(exp(Double(-dt / seconds)))
    }
}

/// Navy field, a slow teal-to-purple wash, and soft radial blobs.
/// Edges fade out in the gradient, so there is no blur filter to pay for.
private enum BackdropField {
    private static let purple = Color(red: 0.46, green: 0.32, blue: 0.76)
    private static let cyan = Color(red: 0.35, green: 0.78, blue: 0.94)

    private struct Blob {
        var color: Color
        var speed: Double
        var phase: Double
        var ax: CGFloat
        var ay: CGFloat
        var ox: CGFloat
        var oy: CGFloat
        var radius: CGFloat
        var band: Int
        var alpha: CGFloat
    }

    /// Large, slow orbs. They read as one shifting gradient.
    private static let gentleBlobs: [Blob] = [
        Blob(color: .roomTeal, speed: 0.42, phase: 0.4, ax: 0.30, ay: 0.28, ox: 0.22, oy: 0.16, radius: 0.78, band: 1, alpha: 0.62),
        Blob(color: cyan, speed: 0.33, phase: 2.1, ax: 0.72, ay: 0.55, ox: 0.18, oy: 0.20, radius: 0.70, band: 0, alpha: 0.48),
        Blob(color: purple, speed: 0.28, phase: 4.2, ax: 0.48, ay: 0.78, ox: 0.20, oy: 0.14, radius: 0.62, band: 2, alpha: 0.42),
    ]

    private static let richBlobs: [Blob] = [
        Blob(color: .roomTeal, speed: 0.24, phase: 0.3, ax: 0.28, ay: 0.30, ox: 0.14, oy: 0.10, radius: 0.52, band: 0, alpha: 0.30),
        Blob(color: purple, speed: 0.17, phase: 2.4, ax: 0.62, ay: 0.72, ox: 0.12, oy: 0.10, radius: 0.48, band: 0, alpha: 0.20),
        Blob(color: cyan, speed: 0.33, phase: 1.5, ax: 0.74, ay: 0.34, ox: 0.12, oy: 0.14, radius: 0.40, band: 1, alpha: 0.26),
        Blob(color: .roomTeal, speed: 0.28, phase: 5.0, ax: 0.46, ay: 0.52, ox: 0.10, oy: 0.12, radius: 0.36, band: 1, alpha: 0.18),
        Blob(color: cyan, speed: 0.46, phase: 3.7, ax: 0.38, ay: 0.42, ox: 0.11, oy: 0.13, radius: 0.26, band: 2, alpha: 0.22),
    ]

    static func paint(
        _ context: inout GraphicsContext,
        size: CGSize,
        look: Look,
        phase: Double,
        low: Float,
        mid: Float,
        high: Float
    ) {
        let rect = CGRect(origin: .zero, size: size)
        let rich = look == .rich
        let idle = look != .gentle && look != .rich
        let energy = CGFloat(min(1, max(0, mid)))

        context.fill(Path(rect), with: .color(.roomNavy))

        context.drawLayer { (layer: inout GraphicsContext) in
            let pulse: CGFloat = idle ? 1 : (1 + energy * (rich ? 0.16 : 0.12))
            let cx = size.width / 2
            let cy = size.height / 2
            layer.translateBy(x: cx, y: cy)
            layer.scaleBy(x: pulse, y: pulse)
            layer.translateBy(x: -cx, y: -cy)
            paintWash(&layer, size: size, phase: phase, energy: energy, rich: rich, idle: idle)
            let blobs = rich ? richBlobs : gentleBlobs
            for blob in blobs {
                paintBlob(
                    &layer,
                    size: size,
                    phase: phase,
                    blob: blob,
                    low: low,
                    mid: mid,
                    high: high,
                    rich: rich,
                    idle: idle
                )
            }
        }

        if !idle {
            let breath = 0.06 + Double(energy) * (rich ? 0.28 : 0.22)
            context.fill(Path(rect), with: .color(Color.roomTeal.opacity(breath)))
        }

        // A heavy navy sheet used to hide the blobs, so a live broadcast on
        // battery looked like the old flat background. Gentle stays see-through
        // and opens further when the meter rises.
        let veil: Double
        if idle {
            veil = 0.62
        } else if rich {
            veil = max(0.04, 0.16 - Double(energy) * 0.10)
        } else {
            veil = max(0.08, 0.28 - Double(energy) * 0.16)
        }
        context.fill(Path(rect), with: .color(Color.roomNavy.opacity(veil)))
        paintVignette(&context, size: size)
    }

    private static func paintWash(
        _ context: inout GraphicsContext,
        size: CGSize,
        phase: Double,
        energy: CGFloat,
        rich: Bool,
        idle: Bool
    ) {
        let turn = phase * (rich ? 0.34 : idle ? 0.08 : 0.22)
        let reach = min(size.width, size.height) * 0.65
        let cx = size.width / 2
        let cy = size.height / 2
        let dx = CGFloat(cos(turn)) * reach
        let dy = CGFloat(sin(turn)) * reach
        let lift = idle ? 0 : Double(energy) * (rich ? 0.34 : 0.28)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [
                    Color.roomTeal.opacity((idle ? 0.10 : 0.28) + lift),
                    Color.roomNavy.opacity(0.02),
                    purple.opacity((idle ? 0.08 : 0.22) + lift * 0.7),
                ]),
                startPoint: CGPoint(x: cx + dx, y: cy + dy),
                endPoint: CGPoint(x: cx - dx, y: cy - dy)
            )
        )
    }

    private static func paintBlob(
        _ context: inout GraphicsContext,
        size: CGSize,
        phase: Double,
        blob: Blob,
        low: Float,
        mid: Float,
        high: Float,
        rich: Bool,
        idle: Bool
    ) {
        let band: Float
        switch blob.band {
        case 0: band = low
        case 2: band = high
        default: band = mid
        }
        let amount = CGFloat(min(1, max(0, band)))
        let swell = idle ? 1 : (1 + amount * (blob.band == 2 ? 1.15 : (rich ? 0.85 : 0.70)))
        let alpha = idle ? blob.alpha * 0.55 : blob.alpha * (0.85 + amount * (rich ? 0.9 : 0.75))
        let center = CGPoint(
            x: (blob.ax + blob.ox * CGFloat(sin(phase * blob.speed + blob.phase))) * size.width,
            y: (blob.ay + blob.oy * CGFloat(cos(phase * blob.speed * 0.81 + blob.phase))) * size.height
        )
        let radius = blob.radius * max(size.width, size.height) * swell
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: blob.color.opacity(Double(alpha)), location: 0),
                    .init(color: blob.color.opacity(Double(alpha) * 0.32), location: 0.45),
                    .init(color: blob.color.opacity(0), location: 1),
                ]),
                center: center,
                startRadius: 0,
                endRadius: max(radius, 1)
            )
        )
    }

    private static func paintVignette(_ context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.48)
        let radius = max(size.width, size.height) * 0.78
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color.roomNavy.opacity(0), location: 0.42),
                    .init(color: Color.roomNavy.opacity(0.28), location: 0.78),
                    .init(color: Color.roomNavy.opacity(0.55), location: 1),
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }
}

#Preview {
    MusicReactiveBackground(level: 0.4, live: true)
}
