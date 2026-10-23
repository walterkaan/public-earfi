import SwiftUI

struct BroadcastView: View {
    @State private var confirmStop = false
    @ObservedObject var model: BroadcastModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var shareURL: String?
    @State private var showStats = false

    var body: some View {
        ZStack {
            Color.roomNavy.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("RoomCast Go")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                mixRow
                startButton
                if let detail = detailText {
                    Text(detail)
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(model.failed ? Color.roomPink : Color.white.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .lineLimit(4)
                }
                if model.isOnAir {
                    qrCard
                    Text(model.url)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    shareButton
                    listenerBlock
                    meter
                }
                Spacer(minLength: 8)
                Text("Plug in for long events.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if let reviewURL = AppStoreListing.writeReviewURL {
                    Link("Rate RoomCast", destination: reviewURL)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.roomTeal)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
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

    private var detailText: String? {
        switch model.phase {
        case .starting, .stopping:
            return nil
        case .reconnecting:
            return model.status
        case .live:
            return model.status == "Live" ? nil : model.status
        case .idle:
            return model.failed ? model.status : model.networkNote
        }
    }

    private var startButton: some View {
        Button {
            if model.phase == .live || model.phase == .reconnecting {
                confirmStop = true
            } else {
                model.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                if model.phase == .starting || model.phase == .stopping {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.roomNavy)
                        .controlSize(.regular)
                }
                Text(buttonTitle)
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(buttonColor)
            .foregroundStyle(buttonInk)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SteadyButtonStyle())
        .disabled(buttonLocked)
        .accessibilityLabel(buttonTitle)
        .confirmationDialog("Stop the broadcast?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop broadcast", role: .destructive) { model.toggle() }
            Button("Keep broadcasting", role: .cancel) {}
        } message: {
            Text("Listeners will lose the sound.")
        }
    }

    private var buttonTitle: String {
        switch model.phase {
        case .idle: return "Start"
        case .starting: return "Starting…"
        case .live, .reconnecting: return "Stop"
        case .stopping: return "Stopping…"
        }
    }

    private var buttonColor: Color {
        switch model.phase {
        case .idle: return .roomTeal
        case .starting, .stopping: return .roomAmber
        case .live, .reconnecting: return .roomRed
        }
    }

    private var buttonInk: Color {
        switch model.phase {
        case .live, .reconnecting: return .white
        case .idle, .starting, .stopping: return .roomNavy
        }
    }

    private var buttonLocked: Bool {
        switch model.phase {
        case .starting, .stopping:
            return true
        case .idle:
            return model.url.isEmpty
        case .live, .reconnecting:
            return false
        }
    }

    private var mixRow: some View {
        HStack(spacing: 10) {
            Button {
                model.setMuted(!model.muted)
            } label: {
                Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(model.muted ? Color.roomPink : Color.white.opacity(0.12))
                    .foregroundStyle(model.muted ? Color.roomNavy : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.muted ? "Unmute" : "Mute")
            Slider(
                value: Binding(
                    get: { model.gain },
                    set: { model.setGain($0) }
                ),
                in: BroadcastGain.range(music: model.musicActive)
            )
            .tint(Color.roomTeal)
            .accessibilityLabel("Mic gain")
            Text(BroadcastGain.label(model.gain))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var musicPicker: some View {
        Picker("Sound", selection: Binding(
            get: { model.musicPreferred },
            set: { model.setMusicPreferred($0) }
        )) {
            Text("Voice").tag(false)
            Text("Music").tag(true)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .disabled(model.phase == .starting || model.phase == .stopping)
        .accessibilityLabel("Voice or music")
    }

    private var qrCard: some View {
        Group {
            if let image = model.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.60 }
                    .accessibilityLabel("QR code for the listener page")
            }
        }
    }

    private var shareButton: some View {
        Button {
            shareURL = model.url
        } label: {
            Text("Share")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Color.white.opacity(0.12))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.url.isEmpty)
    }

    private var listenerBlock: some View {
        VStack(spacing: 2) {
            Button {
                showStats.toggle()
            } label: {
                Text(model.listenerLabel)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityHint(showStats ? "Hides CPU, heat, and battery" : "Shows CPU, heat, and battery")
            if showStats {
                Text(model.statsText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.muted ? "Sound Source · not sent" : (model.profileText.isEmpty || model.phase == .idle ? "Sound Source" : "Sound · \(model.profileText)"))
                Spacer()
                if model.clipping && !model.muted {
                    Text("Too loud, turn the source down")
                        .lineLimit(1)
                        .foregroundStyle(Color.red)
                } else {
                    Text(model.inputName.isEmpty ? " " : model.inputName)
                        .lineLimit(1)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.7))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(model.muted ? Color.roomPink : (model.clipping ? Color.red : Color.roomTeal))
                        .frame(width: max(0, geo.size.width * CGFloat(model.level)))
                }
            }
            .frame(height: 10)
            .accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int(model.level * 100)) percent")
        }
    }
}

/// Keeps Starting… and Stopping… at full color. The plain style fades a disabled button.
private struct SteadyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
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
    static let roomAmber = Color(red: 1, green: 0.76, blue: 0.18)
    static let roomRed = Color(red: 0.92, green: 0.22, blue: 0.27)
}
