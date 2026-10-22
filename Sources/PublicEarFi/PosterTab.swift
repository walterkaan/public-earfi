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
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        Text("Preview and PDF")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        ZStack {
          RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.18, green: 0.43, blue: 0.89))
          Text("EF").font(.headline).foregroundStyle(.white)
        }
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
                  .background(Color.blue.opacity(0.12))
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
        .foregroundStyle(AppChrome.startButton)
      ScrollView {
        Text(model.logLines.joined(separator: "\n"))
          .font(.system(size: 11, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      HStack {
        GreenPushButton("Copy diagnostics") { model.copyDiagnostics() }
        Spacer()
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct FirstRunSheet: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 80, height: 80)
        .frame(maxWidth: .infinity)
      Text("Welcome to RoomCast")
        .font(.title2.bold())
        .frame(maxWidth: .infinity)
      Text(
        "RoomCast sends sound from your Mac to people's phones over your Wi-Fi. That sound gets to the Mac from your Mac’s microphone (or a headset or earbuds), or from a mixing desk for bigger events. Listeners simply scan a provided QR code and listen with earphones on their phone. No sign-in, no cloud involvement. Just you and the listeners."
      )
      .fixedSize(horizontal: false, vertical: true)
      Text("Getting started")
        .font(.headline)
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "1. When you close this window, settings will open. Choose your sound source in Settings, such as a USB audio interface or a microphone, then close the settings window."
        )
        Text("2. Press Start Broadcasting.")
        Text(
          "3. Print the QR poster, or show it on a screen, so people can scan it and listen. The QR code is always also shown on the main window."
        )
      }
      .fixedSize(horizontal: false, vertical: true)
      Text(
        "Two macOS prompts to expect. macOS will ask to let RoomCast use the microphone, so it can hear your sound source. If your firewall is on, it may also ask to allow incoming connections, which is how phones reach this Mac. Choose Allow for both and you’re set to go!"
      )
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Get started") { model.finishFirstRun() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560)
  }
}

struct WhySheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Keep the printed address stable").font(.headline)
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
