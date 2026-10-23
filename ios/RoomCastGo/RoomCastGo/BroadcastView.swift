import SwiftUI

struct BroadcastView: View {
    @ObservedObject var model: BroadcastModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.roomNavy.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    header
                    startButton
                    statusLine
                    qrCard
                    listenerLine
                    meter
                    hint
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.appear() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneBecameActive()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("RoomCast Go")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
            Text("Voice only · Opus 32 kbps · mono")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    private var startButton: some View {
        Button(action: model.toggle) {
            Text(model.running ? "Stop" : "Start")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(model.running ? Color.roomPink : Color.roomTeal)
                .foregroundStyle(Color.roomNavy)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.busy || (!model.running && model.url.isEmpty))
        .opacity(model.busy ? 0.6 : 1)
    }

    private var statusLine: some View {
        Text(model.status)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(model.failed ? Color.roomPink : Color.white.opacity(0.78))
            .frame(maxWidth: .infinity)
    }

    private var qrCard: some View {
        VStack(spacing: 14) {
            if let image = model.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .padding(12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("QR code for the listener page")
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 220)
                    .overlay {
                        Text(model.networkNote)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(24)
                    }
            }
            Text(model.url.isEmpty ? "No listener address yet" : model.url)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Text(model.networkNote)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var listenerLine: some View {
        Text(model.running ? model.listenerLabel : "Not broadcasting")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Microphone")
                Spacer()
                Text(model.inputName.isEmpty ? " " : model.inputName)
                    .lineLimit(1)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.75))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Color.roomTeal)
                        .frame(width: max(0, geo.size.width * CGFloat(model.level)))
                }
            }
            .frame(height: 18)
            .accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int(model.level * 100)) percent")
        }
    }

    private var hint: some View {
        Text("Listeners open the page in a browser and tap the speaker icon to unmute. Locking this iPhone keeps the broadcast going. A phone call pauses it, then it comes back.")
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.55))
    }
}

extension Color {
    static let roomNavy = Color(red: 22 / 255, green: 26 / 255, blue: 66 / 255)
    static let roomTeal = Color(red: 47 / 255, green: 208 / 255, blue: 189 / 255)
    static let roomPink = Color(red: 255 / 255, green: 93 / 255, blue: 143 / 255)
}
