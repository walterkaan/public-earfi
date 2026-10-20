import Foundation

final class FileLogger {
  private let lock = NSLock()
  private var lines: [String] = []
  private let fileURL: URL
  private let maxBytes = 1_000_000
  private let maxMemory = 2_000
  private let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  init(directory: URL) {
    fileURL = directory.appendingPathComponent("earfi.log")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func log(_ source: String, _ message: String) {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    for piece in trimmed.split(separator: "\n") {
      write(source: source, message: String(piece))
    }
  }

  func recent(_ limit: Int) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return Array(lines.suffix(limit))
  }

  private func write(source: String, message: String) {
    let line: String
    lock.lock()
    line = "\(formatter.string(from: Date())) [\(source)] \(message)"
    lines.append(line)
    if lines.count > maxMemory {
      lines.removeFirst(lines.count - maxMemory)
    }
    lock.unlock()
    appendToDisk(line)
  }

  private func appendToDisk(_ line: String) {
    let data = Data((line + "\n").utf8)
    let manager = FileManager.default
    if !manager.fileExists(atPath: fileURL.path) {
      manager.createFile(atPath: fileURL.path, contents: nil)
    }
    rotateIfNeeded(adding: data.count)
    guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      return
    }
  }

  private func rotateIfNeeded(adding: Int) {
    let size =
      (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
      .intValue ?? 0
    guard size + adding > maxBytes else { return }
    let manager = FileManager.default
    let oldest = fileURL.appendingPathExtension("3")
    try? manager.removeItem(at: oldest)
    for index in stride(from: 2, through: 1, by: -1) {
      let source = fileURL.appendingPathExtension("\(index)")
      let destination = fileURL.appendingPathExtension("\(index + 1)")
      if manager.fileExists(atPath: source.path) {
        try? manager.moveItem(at: source, to: destination)
      }
    }
    try? manager.moveItem(at: fileURL, to: fileURL.appendingPathExtension("1"))
    manager.createFile(atPath: fileURL.path, contents: nil)
  }
}
