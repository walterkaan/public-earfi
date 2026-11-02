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
    private let pink = Color(red: 255 / 255, green: 93 / 255, blue: 143 / 255)

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
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(listenerText(context.state.listeners))
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    livePill(context.state, stale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        LevelBar(
                            level: context.state.level,
                            tint: context.state.muted ? pink : teal
                        )
                        controls(context.state)
                    }
                }
            } compactLeading: {
                glyph(size: 30)
            } compactTrailing: {
                Text("\(context.state.listeners)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(context.state.muted ? pink : teal)
            } minimal: {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(context.state.muted ? pink : teal)
            }
            .keylineTint(teal)
        }
    }

    private func lockScreen(_ context: ActivityViewContext<BroadcastAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                glyph(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RoomCast Go")
                        .font(.headline)
                    Text(context.isStale ? "Ended" : listenerText(context.state.listeners))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                }
                Spacer(minLength: 8)
                livePill(context.state, stale: context.isStale)
            }
            LevelBar(
                level: context.state.level,
                tint: context.state.muted ? pink : teal
            )
            controls(context.state)
        }
        .foregroundStyle(.white)
        .opacity(context.isStale ? 0.72 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func glyph(size: CGFloat) -> some View {
        Image("Glyph")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func livePill(_ state: BroadcastAttributes.ContentState, stale: Bool) -> some View {
        Text(stale ? "Ended" : (state.muted ? "Muted" : "Live"))
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(stale ? Color.white.opacity(0.28) : (state.muted ? pink : teal), in: Capsule())
            .foregroundStyle(stale || state.muted ? Color.white : navy)
    }

    private func controls(_ state: BroadcastAttributes.ContentState) -> some View {
        HStack(spacing: 8) {
            symbolButton(
                systemName: state.muted ? "mic.slash.fill" : "mic.slash",
                prominent: state.muted,
                intent: SetMutedIntent(muted: !state.muted)
            )
            symbolButton(
                systemName: "minus",
                prominent: false,
                intent: AdjustGainIntent(up: false)
            )
            Text(BroadcastGain.label(state.gain))
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 40)
            symbolButton(
                systemName: "plus",
                prominent: false,
                intent: AdjustGainIntent(up: true)
            )
        }
    }

    private func symbolButton(systemName: String, prominent: Bool, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    prominent ? Color.white.opacity(0.28) : Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
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

private struct LevelBar: View {
    var level: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * CGFloat(min(1, max(0, level)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: width)
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
