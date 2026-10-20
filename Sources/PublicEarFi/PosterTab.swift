import PublicEarFiCore
import SwiftUI

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
            Button("Print…") { printPoster() }
            Button("Copy QR image") { copyQR() }
          }
        }
      }
      .frame(minWidth: 280, maxWidth: 340)
      VStack {
        preview
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        Text("Preview/PDF/Print Poster")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var renderModel: PosterRenderModel {
    let paper = model.settings.resolvedPaperSize(
      regionCode: Locale.current.region?.identifier,
      measurementSystemIsUS: Locale.current.measurementSystem == .us
    )
    return PosterRenderModel(
      header: model.settings.posterHeader,
      description: model.settings.posterDescription,
      steps: PosterBuilder.steps(
        instructions: model.settings.posterInstructions,
        show: model.settings.posterShowInstructions,
        networkName: model.settings.posterNetworkName
      ),
      url: model.listenerURL
        ?? "http://<this-mac>:\(model.settings.listenerPort)/\(model.settings.streamName)",
      qr: model.qrImage,
      showFooter: model.settings.posterUseFooter,
      paper: model.settings.posterPaperSize ?? paper
    )
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

  private func printPoster() {
    PosterActions.printPoster(model: printModel) { model.rememberPoster() }
  }

  private var printModel: PosterRenderModel {
    var page = renderModel
    if let url = model.listenerURL, let image = QRCodeMaker.image(text: url, side: 2048) {
      page.qr = image
    }
    return page
  }

  private func copyQR() {
    guard let url = model.listenerURL, let data = QRCodeMaker.pngData(text: url) else { return }
    Clipboard.copyPNG(data)
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
          Text("Public EarFi \(model.versionLabel)").font(.headline)
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

struct LogSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading) {
      Text("Log").font(.headline)
      ScrollView {
        Text(model.logLines.joined(separator: "\n"))
          .font(.system(size: 11, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      HStack {
        Button("Copy diagnostics") { model.copyDiagnostics() }
        Spacer()
        Button("Done") { dismiss() }
      }
    }
    .padding(16)
    .frame(width: 640, height: 420)
  }
}

struct FirstRunSheet: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Public EarFi").font(.title2.bold())
      Text(
        "This app captures the sound desk from an audio interface and shares it with phones on the same Wi-Fi. Listeners open a link. They do not need an account."
      )
      Text(
        "macOS will ask for the microphone so Public EarFi can hear the interface. Allow it. If the firewall is on, a later prompt asks to allow incoming connections for mediamtx. That is expected."
      )
      Text(
        "Pick the USB interface in Settings if the automatic choice is wrong, then press Start Broadcasting."
      )
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Continue") { model.finishFirstRun() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
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
