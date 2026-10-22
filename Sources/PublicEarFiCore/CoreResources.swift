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

  static func pageStrings(searching root: URL? = nil) -> [String: String] {
    let fallback = ["loadError": "The listener page could not load."]
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
    let nested = "\(packageBundleName).bundle/\(filename)"
    var urls: [URL] = []
    func add(_ root: URL) {
      urls.append(root.appendingPathComponent("Contents/Resources/\(nested)"))
      urls.append(root.appendingPathComponent("Resources/\(nested)"))
      urls.append(root.appendingPathComponent(nested))
    }
    add(Bundle.main.bundleURL)
    if let resources = Bundle.main.resourceURL {
      urls.append(resources.appendingPathComponent(nested))
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

  private static func firstFile(_ filename: String, in roots: [URL]) -> URL? {
    let nested = "\(packageBundleName).bundle/\(filename)"
    let suffixes = [
      filename,
      "Contents/Resources/\(filename)",
      "Resources/\(filename)",
      "Contents/Resources/\(nested)",
      "Resources/\(nested)",
      nested,
    ]
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
