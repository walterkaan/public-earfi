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
                            high: moving ? sample.high : 0,
                            kick: moving ? sample.kick : 0
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
            return 1.0 / 25.0
        case .rich:
            return 1.0 / 45.0
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
            return 1.63
        case .rich:
            return 2.28
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
        var kick: Float
    }

    private var phase: Double = 0
    private var low: Float = 0
    private var mid: Float = 0
    private var high: Float = 0
    private var kick: Float = 0
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
            let dt = Float(min(elapsed, 1.0 / 24.0))
            let aim = min(1, max(0, target))
            let previous = mid
            // Halfway between the older symmetric follow and the snappier envelope.
            low = follow(low, toward: aim, dt: dt, attack: 0.55, release: 1.20)
            mid = follow(mid, toward: aim, dt: dt, attack: 0.20, release: 0.63)
            let onset = max(0, aim - previous)
            if onset > 0.02 {
                high = min(1, max(high, onset * 2))
                kick = min(1, max(kick, onset * 3))
            }
            high = follow(high, toward: 0, dt: dt, attack: 0.04, release: 0.33)
            kick = follow(kick, toward: 0, dt: dt, attack: 0.02, release: 0.16)
        } else if !running {
            low = 0
            mid = 0
            high = 0
            kick = 0
        }
        let sample = Sample(phase: phase, low: low, mid: mid, high: high, kick: kick)
        cached = sample
        return sample
    }

    /// Rises on `attack` seconds and falls on `release` seconds.
    private func follow(_ value: Float, toward aim: Float, dt: Float, attack: Float, release: Float) -> Float {
        let seconds = aim >= value ? attack : release
        return value + (aim - value) * response(dt, seconds: max(seconds, 0.02))
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
        Blob(color: .roomTeal, speed: 0.40, phase: 0.3, ax: 0.27, ay: 0.29, ox: 0.21, oy: 0.16, radius: 0.52, band: 0, alpha: 0.30),
        Blob(color: purple, speed: 0.30, phase: 2.4, ax: 0.66, ay: 0.73, ox: 0.18, oy: 0.15, radius: 0.48, band: 0, alpha: 0.20),
        Blob(color: cyan, speed: 0.53, phase: 1.5, ax: 0.76, ay: 0.32, ox: 0.17, oy: 0.20, radius: 0.40, band: 1, alpha: 0.26),
        Blob(color: .roomTeal, speed: 0.46, phase: 5.0, ax: 0.44, ay: 0.55, ox: 0.18, oy: 0.17, radius: 0.36, band: 1, alpha: 0.18),
        Blob(color: cyan, speed: 0.71, phase: 3.7, ax: 0.36, ay: 0.41, ox: 0.16, oy: 0.19, radius: 0.26, band: 2, alpha: 0.22),
    ]

    static func paint(
        _ context: inout GraphicsContext,
        size: CGSize,
        look: Look,
        phase: Double,
        low: Float,
        mid: Float,
        high: Float,
        kick: Float
    ) {
        let rect = CGRect(origin: .zero, size: size)
        let rich = look == .rich
        let idle = look != .gentle && look != .rich
        let energy = CGFloat(min(1, max(0, mid)))
        let hit = CGFloat(min(1, max(0, kick)))

        context.fill(Path(rect), with: .color(.roomNavy))

        context.drawLayer { (layer: inout GraphicsContext) in
            // Sustained scale stays small. The peak is a short jolt, not a brighter hold.
            let pulse: CGFloat = idle ? 1 : (1 + energy * (rich ? 0.105 : 0.078) + hit * (rich ? 0.11 : 0.07))
            let nudge = idle ? 0 : hit * (rich ? 9 : 5)
            let cx = size.width / 2
            let cy = size.height / 2
            layer.translateBy(x: cx + nudge * CGFloat(sin(phase * 11)), y: cy + nudge * CGFloat(cos(phase * 8)))
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
                    kick: hit,
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
            veil = max(0.06, 0.25 - Double(energy) * 0.19)
        } else {
            veil = max(0.12, 0.37 - Double(energy) * 0.25)
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
        let turn = phase * (rich ? 0.60 : idle ? 0.08 : 0.39) * (idle ? 1 : (0.78 + Double(energy) * 0.8))
        let reach = min(size.width, size.height) * 0.65
        let cx = size.width / 2
        let cy = size.height / 2
        let dx = CGFloat(cos(turn)) * reach
        let dy = CGFloat(sin(turn)) * reach
        // Quiet starts darker. Loud reaches the same peak opacity as before, not past it.
        let lift = idle ? 0 : Double(energy) * (rich ? 0.42 : 0.36)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [
                    Color.roomTeal.opacity((idle ? 0.09 : 0.20) + lift),
                    Color.roomNavy.opacity(0.02),
                    purple.opacity((idle ? 0.07 : 0.15) + lift * 0.725),
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
        kick: CGFloat,
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
        let drive = idle ? 0 : (0.2 + amount * 0.8)
        let travel = idle ? 0.7 : (0.61 + drive * (rich ? 1.08 : 0.73))
        let tempo = idle ? 0.72 : (rich ? (0.73 + Double(drive) * 1.21) : (0.66 + Double(drive) * 0.84))
        let angle = phase * blob.speed * tempo + blob.phase
        let jolt = idle ? 0 : kick * (rich ? 0.10 : 0.065)
        var nx = blob.ax + blob.ox * travel * CGFloat(sin(angle)) + jolt * CGFloat(cos(angle * 2.4))
        var ny = blob.ay + blob.oy * travel * CGFloat(cos(angle * 0.81)) + jolt * CGFloat(sin(angle * 1.7))
        nx = min(0.94, max(0.06, nx))
        ny = min(0.94, max(0.06, ny))
        let swell = idle ? 1 : (1 + amount * (blob.band == 2 ? (rich ? 0.74 : 0.68) : (rich ? 0.59 : 0.45)) + kick * (blob.band == 2 ? (rich ? 0.53 : 0.36) : (rich ? 0.39 : 0.25)))
        // Loud opacity stays at the previous peak. The quiet floor is halfway back up.
        let alpha = idle ? blob.alpha * 0.55 : blob.alpha * (rich ? (0.60 + amount * 1.15) : (0.625 + amount * 0.975))
        let swung = shifted(blob.color, phase: phase, energy: drive, rich: rich)
        let center = CGPoint(x: nx * size.width, y: ny * size.height)
        let radius = blob.radius * max(size.width, size.height) * swell
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: swung.opacity(Double(alpha)), location: 0),
                    .init(color: swung.opacity(Double(alpha) * 0.32), location: 0.45),
                    .init(color: swung.opacity(0), location: 1),
                ]),
                center: center,
                startRadius: 0,
                endRadius: max(radius, 1)
            )
        )
    }

    /// Oscillates toward purple or navy. The unshifted color is the brightest this blob gets.
    private static func shifted(_ color: Color, phase: Double, energy: CGFloat, rich: Bool) -> Color {
        let swing = CGFloat(sin(phase * (rich ? 1.15 : 0.7)))
        let towardPurple = max(0, swing) * (rich ? 0.31 : 0.21) * (0.3 + energy * 0.7)
        let towardNavy = max(0, -swing) * (rich ? 0.14 : 0.09) * energy
        var mixed = color
        if towardPurple > 0 { mixed = mix(mixed, purple, t: towardPurple) }
        if towardNavy > 0 { mixed = mix(mixed, .roomNavy, t: towardNavy) }
        return mixed
    }

    private static func mix(_ a: Color, _ b: Color, t: CGFloat) -> Color {
        let amount = min(1, max(0, t))
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        _ = (aa, ba)
        return Color(
            red: ar + (br - ar) * amount,
            green: ag + (bg - ag) * amount,
            blue: ab + (bb - ab) * amount
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
