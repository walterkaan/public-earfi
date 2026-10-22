import AppKit
import PublicEarFiCore
import SwiftUI
import UniformTypeIdentifiers

struct PosterRenderModel {
  var header: String
  var description: String
  var steps: [String]
  var url: String
  var qr: NSImage?
  var showFooter: Bool
  var paper: PaperSize
  var footerText: String = PosterBuilder.footer
  var headerPoints: Double = 34
  var stepPoints: Double = 14
  var qrFraction: Double = 0.58
  var codes: [PosterCodeBlock] = []
  var closing: String = ""
}

struct PosterCodeBlock {
  var label: String
  var image: NSImage?
  var lines: [String]
}

struct PosterPage: View {
  var model: PosterRenderModel

  var body: some View {
    if model.codes.count > 1 {
      twoCodePage
    } else {
      singlePage
    }
  }

  private var singlePage: some View {
    let width = model.paper.widthPoints
    let height = model.paper.heightPoints
    return VStack(spacing: 16) {
      Text(model.header)
        .font(.system(size: model.headerPoints, weight: .bold))
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .minimumScaleFactor(0.55)
        .frame(maxWidth: .infinity)
      if !model.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(model.description)
          .font(.system(size: 16))
          .multilineTextAlignment(.center)
          .foregroundStyle(Color(white: 0.25))
      }
      if let qr = model.qr {
        Image(nsImage: qr)
          .interpolation(.none)
          .resizable()
          .frame(width: width * model.qrFraction, height: width * model.qrFraction)
      }
      Text(model.url)
        .font(.system(size: 18, weight: .bold, design: .monospaced))
        .multilineTextAlignment(.center)
      if !model.steps.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(model.steps.enumerated()), id: \.offset) { index, step in
            Text("\(index + 1).  \(step)")
              .font(.system(size: model.stepPoints))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 0)
      if model.showFooter {
        Text(model.footerText)
          .font(.system(size: 11))
          .foregroundStyle(Color(white: 0.45))
      }
    }
    .padding(40)
    .frame(width: width, height: height, alignment: .top)
    .background(Color.white)
    .foregroundStyle(Color.black)
    .environment(\.colorScheme, .light)
  }

  private var twoCodePage: some View {
    let width = model.paper.widthPoints
    let height = model.paper.heightPoints
    let side = codeSide(width: width, height: height)
    return VStack(spacing: 8) {
      Text(model.header)
        .font(.system(size: min(model.headerPoints, 36), weight: .bold))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.55)
        .frame(maxWidth: .infinity)
      ForEach(Array(model.codes.enumerated()), id: \.offset) { index, code in
        if index > 0 {
          Divider().overlay(Color.black.opacity(0.35))
        }
        VStack(spacing: 4) {
          Text(code.label)
            .font(.system(size: 20, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
          if let image = code.image {
            Image(nsImage: image)
              .interpolation(.none)
              .resizable()
              .frame(width: side, height: side)
          }
          ForEach(Array(code.lines.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(lineFont(line))
              .multilineTextAlignment(.center)
              .minimumScaleFactor(0.55)
              .lineLimit(3)
              .frame(maxWidth: .infinity)
          }
        }
      }
      if !model.closing.isEmpty {
        Text(model.closing)
          .font(.system(size: model.stepPoints, weight: .semibold))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
      }
      Spacer(minLength: 0)
      if model.showFooter {
        Text(model.footerText)
          .font(.system(size: 11))
          .foregroundStyle(Color(white: 0.45))
      }
    }
    .padding(32)
    .frame(width: width, height: height, alignment: .top)
    .background(Color.white)
    .foregroundStyle(Color.black)
    .environment(\.colorScheme, .light)
  }

  private func lineFont(_ line: String) -> Font {
    if line.hasPrefix("http") {
      return .system(size: 13, weight: .bold, design: .monospaced)
    }
    if line.hasPrefix("Password") || line == "No password" || line == "Hidden network" {
      return .system(size: 15, weight: .semibold)
    }
    return .system(size: 18, weight: .bold)
  }

  private func codeSide(width: Double, height: Double) -> Double {
    let fromHeight = (height - 340) / Double(max(model.codes.count, 1))
    return min(width * 0.42, max(150, fromHeight))
  }
}

@MainActor
enum PosterActions {
  @MainActor
  static func exportPDF(model: PosterRenderModel, remember: @escaping () -> Void) {
    let page = PosterPage(model: model)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "RoomCast poster \(fileDate()).pdf"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      guard let data = pdfData(page: page, paper: model.paper) else { return }
      do {
        try data.write(to: url)
        remember()
      } catch {
        NSSound.beep()
      }
    }
  }

  /// Writes one PDF over the previous file and opens it in the default viewer.
  @MainActor
  static func writeAndOpenPDF(model: PosterRenderModel, url: URL, remember: () -> Void) {
    let page = PosterPage(model: model)
    guard let data = pdfData(page: page, paper: model.paper) else {
      NSSound.beep()
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      remember()
      if !NSWorkspace.shared.open(url) {
        NSSound.beep()
      }
    } catch {
      NSSound.beep()
    }
  }

  @MainActor
  static func pdfData(page: PosterPage, paper: PaperSize) -> Data? {
    let renderer = ImageRenderer(content: page)
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: paper.widthPoints, height: paper.heightPoints)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return nil }
    renderer.render { _, draw in
      context.beginPDFPage(nil)
      draw(context)
      context.endPDFPage()
    }
    context.closePDF()
    let result = data as Data
    return result.isEmpty ? nil : result
  }

  private static func fileDate() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }
}
