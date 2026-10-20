import AppKit
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
}

struct PosterPage: View {
  var model: PosterRenderModel

  var body: some View {
    let width = model.paper.widthPoints
    let height = model.paper.heightPoints
    VStack(spacing: 16) {
      Text(model.header)
        .font(.system(size: 34, weight: .bold))
        .multilineTextAlignment(.center)
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
          .frame(width: width * 0.58, height: width * 0.58)
      }
      Text(model.url)
        .font(.system(size: 18, weight: .bold, design: .monospaced))
        .multilineTextAlignment(.center)
      if !model.steps.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(model.steps.enumerated()), id: \.offset) { index, step in
            Text("\(index + 1).  \(step)")
              .font(.system(size: 14))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 0)
      if model.showFooter {
        Text(PosterBuilder.footer)
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
}

@MainActor
enum PosterActions {
  @MainActor
  static func exportPDF(model: PosterRenderModel, remember: () -> Void) {
    let page = PosterPage(model: model)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Public EarFi poster \(fileDate()).pdf"
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

  @MainActor
  static func printPoster(model: PosterRenderModel, remember: () -> Void) {
    let page = PosterPage(model: model)
    let view = NSHostingView(rootView: page)
    let size = NSSize(width: model.paper.widthPoints, height: model.paper.heightPoints)
    view.frame = NSRect(origin: .zero, size: size)
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.paperSize = size
    info.orientation = .portrait
    let margin = 15.0 * 72.0 / 25.4
    info.topMargin = margin
    info.bottomMargin = margin
    info.leftMargin = margin
    info.rightMargin = margin
    info.horizontalPagination = .fit
    info.verticalPagination = .fit
    info.isHorizontallyCentered = true
    info.isVerticallyCentered = true
    let operation = NSPrintOperation(view: view, printInfo: info)
    operation.showsPrintPanel = true
    operation.showsProgressPanel = true
    if operation.run() {
      remember()
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
