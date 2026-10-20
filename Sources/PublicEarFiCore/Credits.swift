import Foundation

public struct CreditComponent: Codable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var version: String
  public var license: String
  public var copyright: String
  public var url: String
  public var licenseFile: String
  public var notes: String
  public var configureFlags: String?

  public init(
    id: String,
    name: String,
    version: String,
    license: String,
    copyright: String,
    url: String,
    licenseFile: String,
    notes: String,
    configureFlags: String? = nil
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.license = license
    self.copyright = copyright
    self.url = url
    self.licenseFile = licenseFile
    self.notes = notes
    self.configureFlags = configureFlags
  }
}

public struct CreditsDocument: Codable, Equatable {
  public var components: [CreditComponent]

  public init(components: [CreditComponent]) {
    self.components = components
  }

  public static func load(from url: URL) throws -> CreditsDocument {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CreditsDocument.self, from: data)
  }

  public func component(_ id: String) -> CreditComponent? {
    components.first { $0.id == id }
  }

  public func plainText(licenseBodies: [String: String] = [:]) -> String {
    var blocks: [String] = []
    for component in components {
      var lines = [
        "\(component.name) \(component.version)".trimmingCharacters(in: .whitespaces),
        "Licence: \(component.license)",
        component.copyright,
      ]
      if !component.url.isEmpty { lines.append(component.url) }
      if !component.notes.isEmpty { lines.append(component.notes) }
      if let flags = component.configureFlags, !flags.isEmpty {
        lines.append("Configure flags: \(flags)")
      }
      if let body = licenseBodies[component.id], !body.isEmpty {
        lines.append("")
        lines.append(body)
      }
      blocks.append(lines.joined(separator: "\n"))
    }
    return blocks.joined(separator: "\n\n")
  }
}

public enum CreditsRules {
  public static let requiredIDs = ["public-earfi", "mediamtx", "ffmpeg", "libopus", "qr"]
  public static let ffmpegStatement =
    "This software uses code of FFmpeg (ffmpeg.org) licensed under the LGPL v2.1 or later. It is built without GPL or non-free components."

  public static func missingIDs(_ document: CreditsDocument) -> [String] {
    let present = Set(document.components.map(\.id))
    return requiredIDs.filter { !present.contains($0) }
  }
}
