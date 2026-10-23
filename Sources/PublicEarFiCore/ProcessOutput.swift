import Foundation

/// Splits process output into lines without using `String.Index`.
///
/// A read that ends on `\n` cannot be cut with
/// `removeSubrange(...index(after: newline))`. That range runs through
/// `endIndex`, and `String.index(after:)` traps. ffmpeg also ends progress
/// lines with `\r` alone. Bytes are split on both, and a UTF-8 sequence that
/// straddles two reads stays buffered until the line is complete.
public struct ProcessOutputBuffer {
  private var pending = Data()
  private var history = Data()
  public let historyLimit: Int

  public init(historyLimit: Int = 4_000) {
    self.historyLimit = historyLimit
  }

  public mutating func reset() {
    pending.removeAll(keepingCapacity: false)
    history.removeAll(keepingCapacity: false)
  }

  /// Complete lines. A `\r\n` pair is one break. The incomplete tail, including
  /// a partial UTF-8 sequence, is kept for the next chunk.
  public mutating func append(_ chunk: Data) -> [String] {
    guard !chunk.isEmpty else { return [] }
    pending.append(contentsOf: chunk)
    remember(chunk)
    let bytes = [UInt8](pending)
    var lines: [String] = []
    var start = 0
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 0x0A || byte == 0x0D {
        if index > start {
          lines.append(String(decoding: bytes[start..<index], as: UTF8.self))
        }
        index += 1
        if byte == 0x0D, index < bytes.count, bytes[index] == 0x0A {
          index += 1
        }
        start = index
      } else {
        index += 1
      }
    }
    pending = start == 0 ? pending : Data(bytes[start...])
    return lines
  }

  /// Bytes after the last line break, decoded lossily.
  public var remainder: String {
    String(decoding: pending, as: UTF8.self)
  }

  /// Recent raw output, capped, for the MediaMTX bind check.
  public var excerpt: String {
    String(decoding: history, as: UTF8.self)
  }

  private mutating func remember(_ chunk: Data) {
    guard historyLimit > 0 else { return }
    history.append(contentsOf: chunk)
    if history.count > historyLimit {
      history.removeFirst(history.count - historyLimit)
    }
  }
}
