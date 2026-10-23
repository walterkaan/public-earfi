import AppKit
import CoreImage
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

enum QRCodeMaker {
  static func image(text: String, side: CGFloat) -> NSImage? {
    guard let data = text.data(using: .utf8),
      let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scale = side / output.extent.width
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext()
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    let image = NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    image.isTemplate = false
    return image
  }

  static func pngData(text: String, side: Int = 1024, margin: Int = 64) -> Data? {
    let moduleSide = max(64, side - margin * 2)
    guard let modules = image(text: text, side: CGFloat(moduleSide)) else { return nil }
    let canvas = NSImage(size: NSSize(width: side, height: side))
    canvas.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    NSGraphicsContext.current?.imageInterpolation = .none
    let origin = CGFloat(margin)
    modules.draw(
      in: NSRect(x: origin, y: origin, width: CGFloat(moduleSide), height: CGFloat(moduleSide))
    )
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
      return nil
    }
    return rep.representation(using: .png, properties: [:])
  }
}

final class SleepAssertion {
  private var assertionID: IOPMAssertionID = 0
  private var held = false

  func set(enabled: Bool) {
    if enabled {
      acquire()
    } else {
      release()
    }
  }

  private func acquire() {
    guard !held else { return }
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "Broadcasting live audio" as CFString,
      &assertionID
    )
    held = result == kIOReturnSuccess
  }

  func release() {
    guard held else { return }
    IOPMAssertionRelease(assertionID)
    held = false
  }
}

enum PowerStatus {
  static func runningOnBattery() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "batt"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.contains("Battery Power")
  }
}

enum LoginItemController {
  static func apply(_ enabled: Bool) throws {
    let service = SMAppService.mainApp
    if enabled {
      if service.status != .enabled {
        try service.register()
      }
    } else if service.status == .enabled {
      try service.unregister()
    }
  }
}

enum Clipboard {
  static func copy(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }

  static func copyPNG(_ data: Data) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(data, forType: .png)
  }
}
