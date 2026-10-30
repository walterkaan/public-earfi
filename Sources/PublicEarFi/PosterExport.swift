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
  var footerText: String = PosterBuilder.poweredBy
  var headerPoints: Double = 34
  var stepPoints: Double = 14
  var qrFraction: Double = 0.58
  var codes: [PosterCodeBlock] = []
  var closing: String = ""
  /// Main-window mockup layout (navy header, violet strip, side-by-side cards).
  var usesQuickLayout: Bool = false
}

struct PosterCodeBlock {
  var label: String
  var image: NSImage?
  var lines: [String]
}

private enum PosterInk {
  /// Header band. #1b1840
  static let navy = Color(red: 27 / 255, green: 24 / 255, blue: 64 / 255)
  /// Step badges, tag strip, listen card border. #8b5cf6
  static let violet = Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)
  /// Eyebrow over the headline. #5fe0c8
  static let teal = Color(red: 95 / 255, green: 224 / 255, blue: 200 / 255)
  /// Body copy. #151338
  static let ink = Color(red: 21 / 255, green: 19 / 255, blue: 56 / 255)
  static let muted = Color(red: 74 / 255, green: 70 / 255, blue: 112 / 255)
  static let cardStroke = Color(red: 230 / 255, green: 227 / 255, blue: 245 / 255)
  static let stepFill = Color(red: 243 / 255, green: 241 / 255, blue: 252 / 255)
  static let footer = Color(red: 138 / 255, green: 134 / 255, blue: 168 / 255)
}

struct PosterPage: View {
  var model: PosterRenderModel

  var body: some View {
    if model.usesQuickLayout {
      quickPage
    } else if model.codes.count > 1 {
      twoCodePage
    } else {
      singlePage
    }
  }

  /// 6 cm at 72 pt/in. Printed QR must stay at least this large.
  private var minimumQRPoints: Double { 6.0 / 2.54 * 72.0 }

  private var appIcon: NSImage { NSApp.applicationIconImage }

  private var quickPage: some View {
    let width = model.paper.widthPoints
    let height = model.paper.heightPoints
    let sideInset: Double = 28
    let gap: Double = 18
    let hasWiFi = model.codes.count > 1
    let qrSide = quickQRSide(width: width, sideInset: sideInset, gap: gap, paired: hasWiFi)
    return VStack(spacing: 0) {
      quickHeader
      Text(PosterBuilder.scanTagline)
        .font(.system(size: 18, weight: .heavy))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(PosterInk.violet)
      HStack(alignment: .top, spacing: gap) {
        ForEach(Array(model.codes.enumerated()), id: \.offset) { index, code in
          quickCard(code: code, index: index, qrSide: qrSide, accent: !hasWiFi || index == 1)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, sideInset)
      .padding(.top, 22)
      .padding(.bottom, 10)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      if !model.closing.isEmpty {
        quickClosing
          .padding(.horizontal, sideInset)
          .padding(.bottom, 8)
      }
      if model.showFooter {
        quickFooter
          .padding(.bottom, 18)
          .padding(.top, 4)
      }
    }
    .frame(width: width, height: height, alignment: .top)
    .background(Color.white)
    .foregroundStyle(PosterInk.ink)
    .environment(\.colorScheme, .light)
  }

  private var quickHeader: some View {
    HStack(alignment: .center, spacing: 16) {
      Image(nsImage: appIcon)
        .resizable()
        .interpolation(.high)
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      VStack(alignment: .leading, spacing: 4) {
        Text(PosterBuilder.listenEyebrow)
          .font(.system(size: 11, weight: .bold))
          .tracking(1.2)
          .foregroundStyle(PosterInk.teal)
        Text(model.header)
          .font(.system(size: 28, weight: .bold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .minimumScaleFactor(0.55)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PosterInk.navy)
  }

  private func quickCard(code: PosterCodeBlock, index: Int, qrSide: Double, accent: Bool)
    -> some View
  {
    let number = stepNumber(from: code.label, fallback: index + 1)
    let title = stepTitle(from: code.label)
    let primary = code.lines.first ?? ""
    let secondary = code.lines.dropFirst().first ?? ""
    let extras = Array(code.lines.dropFirst(2))
    return VStack(spacing: 10) {
      stepBadge(number)
      Text(title)
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(PosterInk.ink)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.7)
      if let image = code.image {
        Image(nsImage: image)
          .interpolation(.none)
          .resizable()
          .frame(width: qrSide, height: qrSide)
      }
      Text(primary)
        .font(.system(size: 20, weight: .heavy))
        .foregroundStyle(PosterInk.ink)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.55)
        .frame(maxWidth: .infinity)
      if !secondary.isEmpty {
        secondaryLine(secondary)
      }
      ForEach(Array(extras.enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(PosterInk.muted)
          .multilineTextAlignment(.center)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(accent ? PosterInk.violet : PosterInk.cardStroke, lineWidth: accent ? 3 : 2)
    )
  }

  private func secondaryLine(_ text: String) -> some View {
    let isPasswordBlank = text.hasPrefix("Password:") && text.contains("____")
    let isPassword = text.hasPrefix("Password:")
    return Group {
      if isPassword, let colon = text.firstIndex(of: ":") {
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        HStack(spacing: 4) {
          Text("Password:")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PosterInk.muted)
          Text(isPasswordBlank ? "____________" : value)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(PosterInk.ink)
        }
      } else {
        Text(text)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(PosterInk.muted)
          .multilineTextAlignment(.center)
      }
    }
  }

  private var quickClosing: some View {
    let number = stepNumber(from: model.closing, fallback: 3)
    let title = stepTitle(from: model.closing)
    return HStack(spacing: 14) {
      stepBadge(number)
      Text(title)
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(PosterInk.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous).fill(PosterInk.stepFill)
    )
  }

  private var quickFooter: some View {
    HStack(spacing: 8) {
      Image(nsImage: appIcon)
        .resizable()
        .interpolation(.high)
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
      Text(model.footerText)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(PosterInk.footer)
    }
    .frame(maxWidth: .infinity)
  }

  private func stepBadge(_ number: Int) -> some View {
    Text("\(number)")
      .font(.system(size: 18, weight: .heavy))
      .foregroundStyle(.white)
      .frame(width: 36, height: 36)
      .background(Circle().fill(PosterInk.violet))
  }

  private func stepNumber(from label: String, fallback: Int) -> Int {
    let digits = label.prefix(while: { $0.isNumber })
    return Int(digits) ?? fallback
  }

  private func stepTitle(from label: String) -> String {
    var text = label
    while let first = text.first, first.isNumber || first == "." || first.isWhitespace {
      text.removeFirst()
    }
    return text.isEmpty ? label : text
  }

  private func quickQRSide(width: Double, sideInset: Double, gap: Double, paired: Bool) -> Double {
    let columns = paired ? 2.0 : 1.0
    let inner = width - sideInset * 2 - (paired ? gap : 0)
    let card = inner / columns
    // Card padding 16 each side; keep QR readable and >= 6 cm when space allows.
    let fit = max(120, card - 40)
    return min(fit, max(minimumQRPoints, fit))
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
    if line.hasPrefix("Password") || line == "No password" || line == "Hidden network"
      || line.contains("____")
    {
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
