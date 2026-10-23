import ActivityKit
import AppIntents
import Foundation

struct BroadcastAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var listeners: Int
        var level: Double
        var muted: Bool
        var gain: Double
    }

    var name: String
}

enum BroadcastGain {
    static let minimum = 0.5
    static let maximum = 3.0
    static let musicMinimum = 0.0
    static let musicMaximum = 2.0
    static let steps: [Double] = [0.5, 0.75, 1, 1.5, 2, 3]
    static let musicSteps: [Double] = [0, 0.5, 1, 1.5, 2]

    static func range(music: Bool) -> ClosedRange<Double> {
        music ? musicMinimum...musicMaximum : minimum...maximum
    }

    static func adjusted(_ gain: Double, up: Bool, music: Bool) -> Double {
        let steps = music ? musicSteps : self.steps
        let index = steps.enumerated().min { abs($0.element - gain) < abs($1.element - gain) }?.offset ?? 0
        let next = index + (up ? 1 : -1)
        if next < 0 || next >= steps.count { return steps[index] }
        return steps[next]
    }

    static func label(_ gain: Double) -> String {
        if gain == floor(gain) { return "\(Int(gain))×" }
        return String(format: "%g×", gain)
    }
}

enum BroadcastCommand: String {
    case mute
    case unmute
    case gainUp
    case gainDown
}

/// Lock-screen buttons run either in the app or in the widget extension.
/// The app registers a handler. The extension only posts a Darwin note.
enum BroadcastBus {
    static let suite = "group.channel.roomcast.go"
    private static let note = CFNotificationName("channel.roomcast.go.command" as CFString)
    private static var handler: ((BroadcastCommand) -> Void)?
    private static var listening = false
    private static var lastSeq = 0

    static func start(_ handler: @escaping (BroadcastCommand) -> Void) {
        self.handler = handler
        guard !listening else { return }
        listening = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            broadcastDarwinCallback,
            note.rawValue,
            nil,
            .deliverImmediately
        )
    }

    static func post(_ command: BroadcastCommand) {
        let defaults = UserDefaults(suiteName: suite)
        let seq = (defaults?.integer(forKey: "seq") ?? 0) + 1
        defaults?.set(command.rawValue, forKey: "cmd")
        defaults?.set(seq, forKey: "seq")
        defaults?.synchronize()
        if handler != nil {
            DispatchQueue.main.async { handler?(command) }
            return
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            note,
            nil,
            nil,
            true
        )
    }

    fileprivate static func deliver() {
        let defaults = UserDefaults(suiteName: suite)
        let seq = defaults?.integer(forKey: "seq") ?? 0
        guard seq > lastSeq else { return }
        lastSeq = seq
        guard let raw = defaults?.string(forKey: "cmd"),
              let command = BroadcastCommand(rawValue: raw) else { return }
        DispatchQueue.main.async { handler?(command) }
    }
}

private let broadcastDarwinCallback: CFNotificationCallback = { _, _, _, _, _ in
    BroadcastBus.deliver()
}

struct SetMutedIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mute"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Muted")
    var muted: Bool

    init() {
        muted = true
    }

    init(muted: Bool) {
        self.muted = muted
    }

    func perform() async throws -> some IntentResult {
        BroadcastBus.post(muted ? .mute : .unmute)
        return .result()
    }
}

struct AdjustGainIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mic gain"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Up")
    var up: Bool

    init() {
        up = true
    }

    init(up: Bool) {
        self.up = up
    }

    func perform() async throws -> some IntentResult {
        BroadcastBus.post(up ? .gainUp : .gainDown)
        return .result()
    }
}
