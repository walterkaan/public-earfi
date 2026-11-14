import SwiftUI
import UIKit

struct BroadcastView: View {
    @State private var confirmStop = false
    @ObservedObject var model: BroadcastModel
    @ObservedObject var store: ProStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var shareURL: String?
    @State private var showStats = false
    @State private var showSetup = false
    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 0) {
            Text("RoomCast Go")
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .padding(.horizontal, 20)
            ScrollView {
                VStack(spacing: 10) {
                    mixRow
                    if model.isOnAir || model.wifiReady {
                        startRow
                        if !model.isOnAir, model.phase == .idle, !store.isPro {
                            Button("Free sessions last 40 minutes. Upgrade") {
                                showPaywall = true
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.roomTeal)
                        }
                    } else {
                        wifiCard
                    }
                    if let detail = detailText {
                        Text(detail)
                            .font(.footnote.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(model.failed ? Color.roomPink : Color.white.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .lineLimit(6)
                    }
                    if model.isOnAir {
                        qrCard(prominent: false)
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
                    Text("Plug in for long events.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 8)
                    if let reviewURL = AppStoreListing.writeReviewURL {
                        Link("Rate RoomCast", destination: reviewURL)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.roomTeal)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            MusicReactiveBackground(level: model.level, live: model.isOnAir)
                .ignoresSafeArea()
        }
        .overlay {
            if model.wifiDown {
                wifiDroppedOverlay
            } else if model.networkChanged {
                wifiChangedOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.appear()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneBecameActive()
            }
        }
        .onChange(of: model.freeLimitHit) { _, hit in
            if hit { showPaywall = true }
        }
        .sheet(isPresented: sharePresented) {
            ShareSheet(items: [shareURL ?? ""])
        }
        .sheet(isPresented: $showSetup) {
            SetupSheet(model: model)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: store)
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
            if model.status != "Ready" { return model.status }
            return model.wifiReady ? model.networkNote : nil
        }
    }

    private var startRow: some View {
        HStack(spacing: 10) {
            startButton
            Button {
                showSetup = true
            } label: {
                Text("Setup")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 84, height: 52)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Setup")
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
            let time = Self.clock(secs)
            Text(model.phase == .reconnecting ? "Reconnecting \(time)" : time)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityLabel(model.phase == .reconnecting ? "Reconnecting \(time)" : "Elapsed \(time)")
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
                    .foregroundStyle(micInk)
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
                if model.canWiden {
                    Toggle("Stereo widen", isOn: Binding(
                        get: { model.stereoWiden },
                        set: { model.setStereoWiden($0) }
                    ))
                    .font(.caption.weight(.semibold))
                    .tint(Color.roomTeal)
                }
            }
        }
    }

    private var micInk: Color {
        if model.muted { return .roomNavy }
        if model.inputHeard { return Color(red: 0.28, green: 0.82, blue: 0.42) }
        return Color.white.opacity(0.38)
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

    private func qrCard(prominent: Bool) -> some View {
        let side = Self.qrSide(prominent: prominent)
        return Group {
            if let image = model.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
                    .padding(10)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(prominent ? "New QR code for the listener page" : "QR code for the listener page")
            }
        }
        .frame(width: side + 20, height: side + 20)
        .layoutPriority(1)
    }

    /// A fixed square, not a fitted image, so a shorter layout cannot shrink the code.
    private static func qrSide(prominent: Bool) -> CGFloat {
        let width = UIScreen.main.bounds.width
        if prominent {
            return min(380, width - 36)
        }
        // Two thirds of the previous fixed live-screen code, still a fixed square.
        return min(300, width * 0.74) * 2 / 3
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
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Button {
                    showStats.toggle()
                } label: {
                    Text(model.listenerLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityHint(showStats ? "Hides CPU, heat, and battery" : "Shows CPU, heat, and battery")
                if let since = model.startedAt {
                    liveLine(since: since)
                }
            }
            .frame(maxWidth: .infinity)
            if !store.isPro, let since = model.startedAt {
                HStack(spacing: 8) {
                    freeMinutes(since: since)
                    Button("Upgrade") { showPaywall = true }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.roomTeal)
                }
            }
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
            Text(soundLine)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Level")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
            if model.clipping && !model.muted {
                Text("Too loud, turn the source down")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(model.muted ? Color.roomPink : (model.clipping ? Color.red : Color.roomTeal))
                                .frame(width: max(0, geo.size.width * CGFloat(min(1, model.level))))
                        }
                    }
                    .clipShape(Capsule())
                    .accessibilityLabel("Level")
                    .accessibilityValue("\(Int(model.level * 100)) percent")
                if model.inputSilent && !model.muted {
                    Text("No sound")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.roomAmber)
                        .fixedSize()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func freeMinutes(since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 30)) { context in
            let remaining = BroadcastLimits.freeSeconds - context.date.timeIntervalSince(since)
            let minutes = remaining <= 0 ? 0 : Int((remaining / 60).rounded(.up))
            Text("Free · \(minutes) min remaining")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(minutes <= 5 ? Color.roomAmber : Color.roomTeal)
        }
    }

    private static func clock(_ secs: Int) -> String {
        let secs = max(0, secs)
        if secs >= 3600 {
            return String(format: "%d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60)
        }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private var wifiTitle: String {
        switch model.wifiPrompt {
        case .checking:
            return "Checking Wi-Fi…"
        case .ssid(let name):
            return "Broadcast on \(name) Wi-Fi?"
        case .hotspot:
            return "Broadcast on Personal Hotspot?"
        case .unnamed:
            return "Broadcast on this Wi-Fi?"
        case .noNetwork:
            return "No Wi-Fi network"
        }
    }

    private var wifiDetail: String? {
        switch model.wifiPrompt {
        case .hotspot:
            return "Listeners must join this iPhone’s hotspot."
        case .unnamed(true):
            return "Location access is off, so the network name can’t be read."
        case .unnamed(false):
            return "The network name can’t be read."
        case .noNetwork:
            return "Join a Wi-Fi network, or turn on Personal Hotspot."
        case .checking, .ssid:
            return nil
        }
    }

    private var wifiCard: some View {
        VStack(spacing: 14) {
            if model.wifiPrompt == .checking {
                ProgressView()
                    .tint(.white)
            }
            Text(wifiTitle)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            if let wifiDetail {
                Text(wifiDetail)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
            }
            if wifiCanContinue {
                Button("Continue") { model.confirmWifi() }
                    .buttonStyle(GateButtonStyle(fill: .roomTeal, ink: .roomNavy))
                Button("Change Wi-Fi") { openAppSettings() }
                    .buttonStyle(GateButtonStyle(fill: Color.white.opacity(0.12), ink: .white))
            }
            if case .unnamed(true) = model.wifiPrompt {
                Button("Open Settings") { openAppSettings() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.roomTeal)
            }
            Button {
                model.recheckWifi()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.roomTeal)
            .accessibilityLabel("Refresh Wi-Fi")
            .disabled(model.wifiPrompt == .checking)
        }
        .padding(16)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var wifiCanContinue: Bool {
        switch model.wifiPrompt {
        case .ssid, .hotspot, .unnamed:
            return true
        case .checking, .noNetwork:
            return false
        }
    }

    private var soundLine: String {
        if model.muted { return "Sound Muted" }
        guard model.isOnAir else { return "Sound Source" }
        let quality = model.musicActive ? "Music quality" : "Voice"
        let width = model.hardwareChannels >= 2 ? "Stereo" : "Mono"
        let device = model.hardwareLabel.localizedCaseInsensitiveContains("iPhone") ? "Mic" : "USB"
        return "\(quality) · \(width) · \(device)"
    }

    private var wifiChangedOverlay: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Color.roomAmber)
                    Text("Wi-Fi changed")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text("The network changed. Listeners must rejoin with this code.")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                    qrCard(prominent: true)
                    Text(model.url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button("Dismiss") { model.dismissNetworkChange() }
                        .buttonStyle(GateButtonStyle(fill: .roomTeal, ink: .roomNavy))
                }
                .padding(24)
                .background(Color.roomNavy, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.roomAmber, lineWidth: 3)
                )
                .padding(20)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var wifiDroppedOverlay: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(Color.roomPink)
                Text("Wi-Fi dropped")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Listeners can’t hear you until this iPhone is back on Wi-Fi or Personal Hotspot.")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(28)
            .background(Color.roomNavy, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.roomPink, lineWidth: 3)
            )
            .padding(20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Wi-Fi dropped. Listeners can’t hear you until this iPhone is back on Wi-Fi or Personal Hotspot.")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Keeps Starting… and Stopping… at full color. The plain style fades a disabled button.
private struct SteadyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct GateButtonStyle: ButtonStyle {
    var fill: Color
    var ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(fill)
            .foregroundStyle(ink)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct SetupSheet: View {
    @ObservedObject var model: BroadcastModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var backgroundMode: MusicBackdropPreference

    init(model: BroadcastModel) {
        self.model = model
        _draft = State(initialValue: model.sessionName)
        _backgroundMode = State(initialValue: .stored)
        let teal = UIColor(red: 47 / 255, green: 208 / 255, blue: 189 / 255, alpha: 1)
        let navy = UIColor(red: 22 / 255, green: 26 / 255, blue: 66 / 255, alpha: 1)
        UISegmentedControl.appearance().selectedSegmentTintColor = teal
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: navy], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes(
            [.foregroundColor: UIColor.white.withAlphaComponent(0.85)],
            for: .normal
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.soundSourceName)
                        .font(.body)
                    Text("Plug in external mic or USB sound card now")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Sound source")
                }
                Section {
                    TextField("Broadcast title", text: $draft)
                        .textInputAutocapitalization(.words)
                        .onChange(of: draft) { _, value in
                            if value.count > SessionName.limit {
                                draft = String(value.prefix(SessionName.limit))
                            }
                        }
                } header: {
                    Text("Broadcast title")
                } footer: {
                    Text("Listeners see this name as the title on the join page. A change while you are live is used the next time the broadcast starts.")
                }
                Section {
                    Picker("Background", selection: $backgroundMode) {
                        ForEach(MusicBackdropPreference.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.roomTeal)
                    .onChange(of: backgroundMode) { _, mode in
                        mode.save()
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Auto is gentle on battery and richer while charging. It moves with the sound while you are live.")
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.roomNavy, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setSessionName(draft)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            draft = model.sessionName
            backgroundMode = MusicBackdropPreference.stored
        }
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
