import Foundation
import PublicEarFiCore

struct HelperLocations: Equatable {
  var mediamtx: URL
  var ffmpeg: URL
}

enum HelperLocator {
  static func locate() -> HelperLocations? {
    guard let mediamtx = executable("mediamtx"), let ffmpeg = executable("ffmpeg") else {
      return nil
    }
    return HelperLocations(mediamtx: mediamtx, ffmpeg: ffmpeg)
  }

  static func executable(_ name: String) -> URL? {
    var candidates: [URL] = []
    if let override = ProcessInfo.processInfo.environment["PUBLIC_EARFI_HELPERS"], !override.isEmpty
    {
      candidates.append(URL(fileURLWithPath: override).appendingPathComponent(name))
    }
    let bundle = Bundle.main.bundleURL
    candidates.append(bundle.appendingPathComponent("Contents/Helpers/\(name)"))
    if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
      candidates.append(executable.appendingPathComponent("../Helpers/\(name)").standardizedFileURL)
      candidates.append(executable.appendingPathComponent(name))
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }
}

enum BundledResources {
  static func licensesDirectory() -> URL? {
    var candidates: [URL] = []
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appendingPathComponent("Licenses"))
      candidates.append(resources.appendingPathComponent("Resources/Licenses"))
    }
    candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Licenses"))
    if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
      candidates.append(
        executable.appendingPathComponent("../Resources/Licenses").standardizedFileURL)
      let siblings =
        (try? FileManager.default.contentsOfDirectory(
          at: executable, includingPropertiesForKeys: nil)) ?? []
      for bundle in siblings where bundle.pathExtension == "bundle" {
        candidates.append(bundle.appendingPathComponent("Licenses"))
        candidates.append(bundle.appendingPathComponent("Resources/Licenses"))
        candidates.append(bundle.appendingPathComponent("Contents/Resources/Licenses"))
      }
    }
    return candidates.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("credits.json").path)
    }
  }

  static func credits() -> CreditsDocument? {
    guard let directory = licensesDirectory() else { return nil }
    return try? CreditsDocument.load(from: directory.appendingPathComponent("credits.json"))
  }

  static func licenseText(for component: CreditComponent) -> String {
    guard !component.licenseFile.isEmpty, let directory = licensesDirectory() else { return "" }
    let url = directory.appendingPathComponent(component.licenseFile)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }
}
