import SwiftUI
import UIKit

struct BroadcastView: View {
    @State private var confirmStop = false
    @ObservedObject var model: BroadcastModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var shareURL: String?
    @State private var showStats = false
    @State private var liveSince: Date?
    @State private var showSetup = false
    @State private var showPaywall = false

    var body: some View {
        ZStack {
            Color.roomNavy.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("RoomCast Go")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                if model.networkConfirmed {
                    Text(model.sessionName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                mixRow
                if model.networkConfirmed {
                    startRow
                    if model.isOnAir, let since = liveSince {
                        liveLine(since: since)
                        if !model.isPro {
                            freeCountdown(since: since)
                        }
                    }
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
                } else {
                    wifiCard
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
        .overlay {
            if model.wifiDropped && model.isOnAir {
                wifiDropOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.appear()
            if model.isOnAir && liveSince == nil { liveSince = model.startedAt ?? Date() }
        }
        .onChange(of: model.isOnAir) { _, onAir in
            liveSince = onAir ? (model.startedAt ?? liveSince ?? Date()) : nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneBecameActive()
            }
        }
        .sheet(isPresented: sharePresented) {
            ShareSheet(items: [shareURL ?? ""])
        }
        .sheet(isPresented: $showSetup) {
            SetupSheet(model: model)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallSheet(model: model)
        }
        .alert("Free session ended", isPresented: freeLimitPresented) {
            Button("Upgrade") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showPaywall = true
                }
            }
            Button("Restore purchases") { model.restorePro() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(limitMessage)
        }
    }

    private var freeLimitPresented: Binding<Bool> {
        Binding(
            get: { model.freeLimitReached },
            set: { model.freeLimitReached = $0 }
        )
    }

    private var limitMessage: String {
        if let price = model.pro.priceDetail {
            return "Free sessions last 40 minutes. Pro is \(price) and removes the limit."
        }
        return "Free sessions last 40 minutes. Pro removes the limit."
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

    private var startRow: some View {
        HStack(spacing: 10) {
            startButton
            Button {
                showSetup = true
            } label: {
                Text("Setup")
                    .font(.title3.weight(.semibold))
                    .frame(width: 92, height: 52)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(SteadyButtonStyle())
            .accessibilityLabel("Setup")
        }
    }

    private var wifiCard: some View {
        VStack(spacing: 14) {
            if model.networkChoice == .checking {
                ProgressView()
                    .tint(.white)
            }
            Text(model.networkPrompt)
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            if model.networkChoice != .checking {
                if case .offline = model.networkChoice {
                    wifiAction("Check again", action: model.recheckNetwork)
                } else {
                    wifiAction("Continue", action: model.confirmNetwork)
                    if case .unnamedWiFi(let denied) = model.networkChoice, denied {
                        Button("Open Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.roomTeal)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func wifiAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.roomTeal)
                .foregroundStyle(Color.roomNavy)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SteadyButtonStyle())
    }

    private var wifiDropOverlay: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 56, weight: .bold))
                Text("Wi-Fi dropped")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Listeners can’t hear you. Rejoin Wi-Fi or turn Personal Hotspot back on.")
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button {
                    model.stopFromDrop()
                } label: {
                    Text("Stop broadcast")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.white)
                        .foregroundStyle(Color.roomRed)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(SteadyButtonStyle())
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(Color.roomRed)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func freeCountdown(since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let left = max(0, FreeSession.limit - context.date.timeIntervalSince(since))
            VStack(spacing: 8) {
                Text("\(clock(left)) left")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(left < 5 * 60 ? Color.roomPink : Color.white)
                Button {
                    showPaywall = true
                } label: {
                    Text(model.pro.offerText)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.roomTeal)
                        .foregroundStyle(Color.roomNavy)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(SteadyButtonStyle())
            }
            .task(id: Int(context.date.timeIntervalSince(since))) {
                model.enforceFreeLimit(at: context.date)
            }
        }
    }

    private func clock(_ interval: TimeInterval) -> String {
        let secs = max(0, Int(interval.rounded(.down)))
        if secs >= 3600 {
            return String(format: "%d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60)
        }
        return String(format: "%d:%02d", secs / 60, secs % 60)
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
        .alert("Stop the broadcast?", isPresented: $confirmStop) {
            Button("Stop broadcast", role: .destructive) { model.toggle() }
            Button("Keep broadcasting", role: .cancel) {}
        } message: {
            Text("Listeners will lose the sound.")
        }
    }

    private func liveLine(since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let secs = max(0, Int(context.date.timeIntervalSince(since)))
            let time = secs >= 3600
                ? String(format: "%d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60)
                : String(format: "%d:%02d", secs / 60, secs % 60)
            HStack(spacing: 6) {
                Circle().fill(Color.roomRed).frame(width: 8, height: 8)
                Text(model.phase == .reconnecting ? "Reconnecting · \(time)" : "Live · \(time)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    private var sourceName: String {
        model.inputName.isEmpty ? "iPhone mic" : model.inputName
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
            .accessibilityLabel(model.muted ? "Unmute, \(sourceName)" : "Mute, \(sourceName)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Volume boost")
                    Spacer(minLength: 4)
                    Text(sourceName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityHidden(true)
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { model.gain },
                            set: { model.setGain($0) }
                        ),
                        in: BroadcastGain.range(music: model.musicActive)
                    )
                    .tint(Color.roomTeal)
                    .accessibilityLabel("Volume boost")
                    .accessibilityValue(BroadcastGain.label(model.gain))
                    Text(BroadcastGain.label(model.gain))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
            }
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

private struct SetupSheet: View {
    @ObservedObject var model: BroadcastModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Session name")
                        .font(.headline)
                        .foregroundStyle(.white)
                    TextField("Walter's 25th Birthday", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Text("Listeners see this name as the title of the page.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                    Button(action: save) {
                        Text("Save name")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.roomTeal)
                            .foregroundStyle(Color.roomNavy)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(SteadyButtonStyle())
                    ProPanel(model: model)
                }
                .padding(20)
            }
            .background(Color.roomNavy.ignoresSafeArea())
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !loaded else { return }
            draft = model.sessionName
            loaded = true
        }
    }

    private func save() {
        model.setSessionName(draft)
        dismiss()
    }
}

private struct PaywallSheet: View {
    @ObservedObject var model: BroadcastModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ProPanel(model: model)
                    .padding(20)
            }
            .background(Color.roomNavy.ignoresSafeArea())
            .navigationTitle("RoomCast Go Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ProPanel: View {
    @ObservedObject var model: BroadcastModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RoomCast Go Pro")
                .font(.headline)
                .foregroundStyle(.white)
            if model.isPro {
                Text("Pro is active. Broadcasts have no time limit.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                Text("Free sessions last 40 minutes. Pro removes the limit.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                if let price = model.pro.priceDetail {
                    Text(price)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.roomTeal)
                }
                Button {
                    model.purchasePro()
                } label: {
                    Text(model.pro.busy ? "Working…" : model.pro.offerText)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.roomTeal)
                        .foregroundStyle(Color.roomNavy)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(SteadyButtonStyle())
                .disabled(model.pro.busy)
            }
            Button("Restore purchases") {
                model.restorePro()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.roomTeal)
            .disabled(model.pro.busy)
            if !model.pro.status.isEmpty {
                Text(model.pro.status)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
    static let appID = "6826514025"

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
