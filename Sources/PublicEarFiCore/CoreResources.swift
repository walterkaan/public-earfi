import Foundation

/// Anchor for locating the SwiftPM resource bundle without calling
/// `Bundle.module`. That accessor traps when the bundle is missing.
final class CoreResourceAnchor: NSObject {}

/// Listener-page files. The packaged app keeps loose copies in
/// Contents/Resources and the SwiftPM bundle beside them. A missing file
/// returns nil. Nothing here calls `Bundle.module`.
enum CoreResources {
  static let packageBundleName = "PublicEarFi_PublicEarFiCore"

  static func faviconDataURI(searching root: URL? = nil) -> String {
    guard let url = file(name: "favicon", extension: "png", searching: root),
      let data = try? Data(contentsOf: url), !data.isEmpty
    else { return "" }
    return "data:image/png;base64," + data.base64EncodedString()
  }


  static let artworkSizes = [96, 192, 256, 512]

  static func artworkPNG(size: Int, searching root: URL? = nil) -> Data? {
    guard artworkSizes.contains(size),
      let url = file(name: "artwork-\(size)", extension: "png", searching: root),
      let data = try? Data(contentsOf: url), !data.isEmpty
    else { return nil }
    return data
  }

  static func pageStrings(searching root: URL? = nil) -> [String: String] {
    let fallback = [
      "loadError": "The listener page could not load.",
      "poweredBy": "Powered by RoomCast",
      "tapToListen": "Tap to listen",
      "waiting": "Waiting for the host to start…",
      "keepOpen": "Keep this screen open. Earbuds work best.",
      "play": "Play",
      "pause": "Pause",
    ]
    guard let url = file(name: "ListenerPage.en", extension: "json", searching: root),
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return fallback }
    return fallback.merging(object) { _, new in new }
  }

  /// Loose app resources first, then `PublicEarFi_PublicEarFiCore.bundle`.
  /// `root` limits the search to one directory, for tests and for a built app.
  static func file(name: String, extension ext: String, searching root: URL? = nil) -> URL? {
    let filename = "\(name).\(ext)"
    if let root {
      return firstFile(filename, in: [root])
    }
    if let loose = looseFile(filename) { return loose }
    return bundledFile(filename)
  }

  private static func looseFile(_ filename: String) -> URL? {
    var urls: [URL] = []
    let stem = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    if let url = Bundle.main.url(forResource: stem, withExtension: ext.isEmpty ? nil : ext) {
      urls.append(url)
    }
    if let resources = Bundle.main.resourceURL {
      urls.append(resources.appendingPathComponent(filename))
    }
    urls.append(
      Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(filename)"))
    if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
      urls.append(
        executable.appendingPathComponent("../Resources/\(filename)").standardizedFileURL)
    }
    return urls.first(where: isFile)
  }

  private static func bundledFile(_ filename: String) -> URL? {
    var urls: [URL] = []
    func add(_ root: URL) {
      for suffix in bundleSuffixes(filename) {
        urls.append(root.appendingPathComponent(suffix))
      }
    }
    add(Bundle.main.bundleURL)
    if let resources = Bundle.main.resourceURL {
      add(resources)
    }
    if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
      var cursor = executable
      for _ in 0..<8 {
        add(cursor)
        cursor.deleteLastPathComponent()
      }
    }
    var cursor = Bundle(for: CoreResourceAnchor.self).bundleURL
    for _ in 0..<8 {
      add(cursor)
      cursor.deleteLastPathComponent()
    }
    return urls.first(where: isFile)
  }

  /// macOS keeps bundle files in Contents/Resources. A flat bundle keeps them
  /// at its root. Loose app files stay ahead of either layout.
  private static func bundleSuffixes(_ filename: String) -> [String] {
    let bundle = "\(packageBundleName).bundle"
    let inside = "\(bundle)/Contents/Resources/\(filename)"
    let flat = "\(bundle)/\(filename)"
    return [
      "Contents/Resources/\(inside)",
      "Contents/Resources/\(flat)",
      "Resources/\(inside)",
      "Resources/\(flat)",
      inside,
      flat,
    ]
  }

  private static func firstFile(_ filename: String, in roots: [URL]) -> URL? {
    let suffixes =
      [
        filename,
        "Contents/Resources/\(filename)",
        "Resources/\(filename)",
      ] + bundleSuffixes(filename)
    for root in roots {
      for suffix in suffixes {
        let url = root.appendingPathComponent(suffix)
        if isFile(url) { return url }
      }
    }
    return nil
  }

  private static func isFile(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
      && !directory.boolValue
  }
}
