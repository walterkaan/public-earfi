import SwiftUI

struct BroadcastView: View {
    @ObservedObject var model: BroadcastModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var shareURL: String?

    var body: some View {
        ZStack {
            Color.roomNavy.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    header
                    startButton
                    muteButton
                    if model.muted {
                        Text("Muted. Listeners hear silence.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.roomPink)
                            .frame(maxWidth: .infinity)
                    }
                    gainRow
                    statusLine
                    qrCard
                    shareButton
                    listenerLine
                    meter
                    Text("Plug in for long events.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    if let reviewURL = AppStoreListing.writeReviewURL {
                        Link("Rate RoomCast", destination: reviewURL)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.roomTeal)
                    }
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
        .sheet(isPresented: sharePresented) {
            ShareSheet(items: [shareURL ?? ""])
        }
    }

    private var sharePresented: Binding<Bool> {
        Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )
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

    private var muteButton: some View {
        Button {
            model.setMuted(!model.muted)
        } label: {
            Text(model.muted ? "Unmute" : "Mute")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(model.muted ? Color.roomPink : Color.white.opacity(0.12))
                .foregroundStyle(model.muted ? Color.roomNavy : .white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var gainRow: some View {
        HStack(spacing: 16) {
            stepButton("−", enabled: model.gain > (BroadcastGain.steps.first ?? 0)) {
                model.adjustGain(up: false)
            }
            VStack(spacing: 2) {
                Text(BroadcastGain.label(model.gain))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("Mic gain")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .frame(minWidth: 72)
            stepButton("+", enabled: model.gain < (BroadcastGain.steps.last ?? 1)) {
                model.adjustGain(up: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title2.weight(.semibold))
                .frame(width: 52, height: 44)
                .background(Color.white.opacity(0.12))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
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

    private var shareButton: some View {
        Button {
            shareURL = model.url
        } label: {
            Text("Share")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.white.opacity(0.12))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.url.isEmpty)
        .opacity(model.url.isEmpty ? 0.4 : 1)
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
                Text(model.muted ? "Microphone · not sent" : "Microphone")
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
                        .fill(model.muted ? Color.roomPink : Color.roomTeal)
                        .frame(width: max(0, geo.size.width * CGFloat(model.level)))
                }
            }
            .frame(height: 18)
            .accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int(model.level * 100)) percent")
        }
    }

    private var hint: some View {
        Text("Listeners open the page in a browser and tap the speaker icon to unmute. Locking this iPhone keeps the broadcast going. If the network changes, this phone restarts and refreshes the code. A phone call pauses the mic, then it comes back.")
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.55))
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum AppStoreListing {
    /// Placeholder until RoomCast Go has an App Store id. Replace `APP_ID`
    /// with the numeric id from App Store Connect. The Rate link stays
    /// hidden while this is still the placeholder.
    static let appID = "APP_ID"

    static var writeReviewURL: URL? {
        guard appID != "APP_ID", !appID.isEmpty, appID.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")
    }
}

extension Color {
    static let roomNavy = Color(red: 22 / 255, green: 26 / 255, blue: 66 / 255)
    static let roomTeal = Color(red: 47 / 255, green: 208 / 255, blue: 189 / 255)
    static let roomPink = Color(red: 255 / 255, green: 93 / 255, blue: 143 / 255)
}
