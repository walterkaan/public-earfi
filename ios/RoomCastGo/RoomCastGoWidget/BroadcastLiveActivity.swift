import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RoomCastWidgetBundle: WidgetBundle {
    var body: some Widget {
        BroadcastLiveActivity()
    }
}

struct BroadcastLiveActivity: Widget {
    private let navy = Color(red: 22 / 255, green: 26 / 255, blue: 66 / 255)
    private let teal = Color(red: 47 / 255, green: 208 / 255, blue: 189 / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BroadcastAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(navy)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RoomCast")
                            .font(.headline)
                        Text(context.state.muted ? "Muted" : "Live")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(context.state.muted ? Color.pink : teal)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(listenerText(context.state.listeners))
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    controls(context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(context.state.muted ? Color.pink : teal)
            } compactTrailing: {
                Text("\(context.state.listeners)")
                    .font(.caption.weight(.bold))
            } minimal: {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<BroadcastAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RoomCast Go")
                    .font(.headline)
                Spacer()
                Text(context.state.muted ? "Muted" : "Live")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(context.state.muted ? Color.pink : teal)
            }
            HStack {
                Text(listenerText(context.state.listeners))
                    .font(.subheadline)
                Spacer()
                LevelMarks(level: context.state.level, tint: context.state.muted ? Color.pink : teal)
                Text(BroadcastGain.label(context.state.gain))
                    .font(.caption.monospacedDigit())
            }
            controls(context.state)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 4)
    }

    private func controls(_ state: BroadcastAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            Button(intent: SetMutedIntent(muted: !state.muted)) {
                Text(state.muted ? "Unmute" : "Mute")
            }
            Button(intent: AdjustGainIntent(up: false)) {
                Text("Gain −")
            }
            Button(intent: AdjustGainIntent(up: true)) {
                Text("Gain +")
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
    }

    private func listenerText(_ count: Int) -> String {
        switch count {
        case 0: return "0 listeners"
        case 1: return "1 listener"
        default: return "\(count) listeners"
        }
    }
}

private struct LevelMarks: View {
    var level: Double
    var tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(level > Double(index) / 5 ? tint : Color.white.opacity(0.25))
                    .frame(width: 7, height: 14)
            }
        }
        .accessibilityLabel("Microphone level")
    }
}
