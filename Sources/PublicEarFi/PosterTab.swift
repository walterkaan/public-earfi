import PublicEarFiCore
import SwiftUI

enum PosterDocument {
  @MainActor
  static func renderModel(from model: AppModel, highResolutionQR: Bool) -> PosterRenderModel {
    let paper = model.settings.resolvedPaperSize(
      regionCode: Locale.current.region?.identifier,
      measurementSystemIsUS: Locale.current.measurementSystem == .us
    )
    var page = PosterRenderModel(
      header: model.settings.posterHeader,
      description: model.settings.posterDescription,
      steps: PosterBuilder.steps(
        instructions: model.settings.posterInstructions,
        show: model.settings.posterShowInstructions,
        networkName: model.settings.posterNetworkName
      ),
      url: model.listenerURL
        ?? "http://<this-mac>:\(model.settings.listenerPort)/",
      qr: model.qrImage,
      showFooter: model.settings.posterUseFooter,
      paper: model.settings.posterPaperSize ?? paper
    )
    if highResolutionQR, let url = model.listenerURL,
      let image = QRCodeMaker.image(text: url, side: 2048)
    {
      page.qr = image
    }
    return page
  }
}

struct PosterTab: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          Text("Header").font(.caption).foregroundStyle(.secondary)
          TextField("Listen live on your phone", text: headerBinding)
          Text("Description").font(.caption).foregroundStyle(.secondary)
          TextField("Today's talk, live in this room", text: descriptionBinding, axis: .vertical)
            .lineLimit(3...6)
          Toggle("Show instructions", isOn: showInstructionsBinding)
          TextEditor(text: instructionsBinding)
            .font(.system(size: 12))
            .frame(minHeight: 110)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3)))
          Button("Restore default instructions") { model.restoreInstructions() }
            .font(.caption)
          Text("Wi-Fi network name (optional)").font(.caption).foregroundStyle(.secondary)
          HStack {
            TextField("Network name", text: networkBinding)
            if let ssid = model.knownSSID, !ssid.isEmpty {
              Button("Use current network name") { model.useCurrentNetworkName() }
            }
          }
          Text(
            "Password, security, and hidden network are in Settings → Poster. The main-window PDF has a join code when this name is filled in. This window's PDF does not include the password."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          LabeledRow(title: "Paper") {
            Picker("Paper", selection: paperBinding) {
              Text("A4").tag(PaperSize.a4)
              Text("Letter").tag(PaperSize.letter)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
          }
          LabeledRow(title: "Address") {
            Picker("Address", selection: styleBinding) {
              Text("IP").tag(URLStyle.ip)
              Text(".local").tag(URLStyle.localHostname)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
          }
          Toggle("Show footer", isOn: footerBinding)
          if model.settings.urlStyle == .localHostname {
            Text("Some Android phones can't open .local addresses.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let stale = model.staleAddress {
            WarningBanner(text: stale.message) { model.showWhy = true }
          }
          HStack {
            Button("Export PDF…") { export() }
            Button("Copy QR image") { model.copyQRImage() }
          }
        }
      }
      .frame(minWidth: 280, maxWidth: 340)
      VStack {
        preview
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(AppChrome.card)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        Text("Preview and PDF")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(AppChrome.window)
    .sheet(isPresented: $model.showWhy) { WhySheet() }
  }

  private var renderModel: PosterRenderModel {
    PosterDocument.renderModel(from: model, highResolutionQR: false)
  }

  private var preview: some View {
    GeometryReader { geometry in
      let page = renderModel
      let scale = min(
        geometry.size.width / page.paper.widthPoints,
        geometry.size.height / page.paper.heightPoints
      )
      PosterPage(model: page)
        .scaleEffect(scale, anchor: .top)
        .frame(
          width: page.paper.widthPoints * scale, height: page.paper.heightPoints * scale,
          alignment: .top
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .shadow(radius: 4)
    }
    .padding(12)
  }

  private func export() {
    PosterActions.exportPDF(model: printModel) { model.rememberPoster() }
  }

  private var printModel: PosterRenderModel {
    PosterDocument.renderModel(from: model, highResolutionQR: true)
  }

  private var headerBinding: Binding<String> {
    Binding(
      get: { model.settings.posterHeader },
      set: { value in model.mutate { $0.posterHeader = value } })
  }
  private var descriptionBinding: Binding<String> {
    Binding(
      get: { model.settings.posterDescription },
      set: { value in model.mutate { $0.posterDescription = value } })
  }
  private var instructionsBinding: Binding<String> {
    Binding(
      get: { model.settings.posterInstructions },
      set: { value in model.mutate { $0.posterInstructions = value } })
  }
  private var showInstructionsBinding: Binding<Bool> {
    Binding(
      get: { model.settings.posterShowInstructions },
      set: { value in model.mutate { $0.posterShowInstructions = value } })
  }
  private var networkBinding: Binding<String> {
    Binding(
      get: { model.settings.posterNetworkName },
      set: { value in model.mutate { $0.posterNetworkName = value } })
  }
  private var paperBinding: Binding<PaperSize> {
    Binding(
      get: {
        model.settings.resolvedPaperSize(
          regionCode: Locale.current.region?.identifier,
          measurementSystemIsUS: Locale.current.measurementSystem == .us
        )
      },
      set: { value in model.mutate { $0.posterPaperSize = value } }
    )
  }
  private var styleBinding: Binding<URLStyle> {
    Binding(
      get: { model.settings.urlStyle }, set: { value in model.mutate { $0.urlStyle = value } })
  }
  private var footerBinding: Binding<Bool> {
    Binding(
      get: { model.settings.posterUseFooter },
      set: { value in model.mutate { $0.posterUseFooter = value } })
  }
}

struct CreditsSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 44, height: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text("RoomCast \(model.versionLabel)").font(.headline)
          Text("Copyright (c) 2026 Walter Kaan · MIT License")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("github.com/walterkaan/public-earfi") { model.openGitHub() }
            .buttonStyle(.link)
        }
      }
      if let credits = model.credits {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(credits.components) { component in
              HStack(alignment: .top) {
                Text(
                  component.version.isEmpty
                    ? component.name : "\(component.name) \(component.version)"
                )
                .frame(width: 150, alignment: .leading)
                Text(component.license)
                  .font(.caption)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(AppChrome.primary.opacity(0.22))
                  .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(component.notes)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                if !component.licenseFile.isEmpty {
                  Button("View licence") { model.selectedLicense = component }
                }
              }
              .padding(.vertical, 6)
              Divider()
            }
          }
        }
      } else {
        Text("Licence files were not found in the app bundle.")
      }
      if let component = model.selectedLicense {
        Text("\(component.name) — \(component.license)")
          .font(.headline)
        ScrollView {
          Text(BundledResources.licenseText(for: component))
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minHeight: 160, maxHeight: 240)
      }
      HStack {
        Button("Copy all notices") { model.copyNotices() }
        Button("Open THIRD_PARTY_NOTICES on GitHub") { model.openNotices() }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 760, height: 520)
  }
}

struct LogWindow: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading) {
      Text("Log")
        .font(.headline)
        .foregroundStyle(AppChrome.heading)
      ScrollView {
        Text(model.logLines.joined(separator: "\n"))
          .font(.system(size: 11, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      HStack {
        TintedPushButton("Copy diagnostics") { model.copyDiagnostics() }
        Spacer()
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(AppChrome.window)
    .background(EscapeCloser {})
  }
}

struct FirstRunSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 36, height: 36)
          .accessibilityLabel("RoomCast")
        Text("Welcome to RoomCast")
          .font(.title3.bold())
          .foregroundStyle(AppChrome.heading)
      }
      Text(
        "RoomCast sends sound from your Mac to people's phones over Wi-Fi. No sign-in, no account, and the Wi-Fi doesn't need internet."
      )
      .helperText()
      .foregroundStyle(.white)
      Text(
        "Sound can come from the Mac's microphone, an application, a headset or earbuds, or a mixing desk for larger events."
      )
      .helperText()
      VStack(alignment: .leading, spacing: 6) {
        welcomeStep(
          "1", symbol: "mic.fill", title: "Pick your sound source",
          detail: nil)
        welcomeStep(
          "2", symbol: "dot.radiowaves.left.and.right", title: "Start broadcasting",
          detail: nil)
        welcomeStep(
          "3", symbol: "qrcode", title: "Share the QR",
          detail:
            "Print the poster or show it. Guests scan to join the Wi-Fi, then scan to listen with earphones."
        )
      }
      HStack {
        Spacer()
        TintedPushButton("Close") { dismiss() }
        GreenPushButton("Choose Sound Source") {
          model.finishFirstRun()
          dismiss()
        }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(AppChrome.window)
    .onChange(of: model.showFirstRun) { show in
      if !show { dismiss() }
    }
    .onDisappear {
      // Closing the window (red button or Close) clears the flag so auto-start can run.
      if model.showFirstRun { model.showFirstRun = false }
    }
  }

  private func welcomeStep(
    _ number: String, symbol: String, title: LocalizedStringKey, detail: String?
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(AppChrome.heading)
        .frame(width: 28, height: 28)
        .background(Circle().fill(AppChrome.heading.opacity(0.16)))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        (Text(verbatim: "\(number). ") + Text(title))
          .font(.system(size: 15, weight: .semibold))
        if let detail {
          Text(detail).helperText()
        }
      }
    }
  }
}

struct WhySheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Keep the printed address stable").font(.headline).foregroundStyle(AppChrome.heading)
      Text(
        "The poster QR code contains this Mac’s current IP address. If the address changes, phones still looking at the old poster cannot connect."
      )
      Text("• Ask the venue for a DHCP reservation for this Mac (recommended).")
      Text("• Or set a manual IP in System Settings → Network.")
      Text(
        "• Or switch the poster address to the .local hostname. iPhone and Mac resolve it. Many Android phones and guest networks do not."
      )
      Text("Guest Wi-Fi with client isolation, and separate VLANs, also block listeners.")
        .foregroundStyle(.secondary)
      HStack {
        Button("Open the README") { model.openGitHub() }
        Spacer()
        Button("Done") { dismiss() }
      }
    }
    .padding(20)
    .frame(width: 480)
  }
}

struct QRSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 16) {
      if let image = model.qrImage {
        Image(nsImage: image)
          .interpolation(.none)
          .resizable()
          .frame(width: 420, height: 420)
      }
      Text(model.listenerURL ?? "")
        .font(.title3.monospaced().bold())
        .textSelection(.enabled)
      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(24)
    .frame(minWidth: 520, minHeight: 560)
    .background(Color.white)
  }
}
