import Foundation

/// `Process.terminationStatus` raises `NSInvalidArgumentException` if the
/// task is still running or was never launched. Callers must use this
/// instead of reading the status themselves. `startFFmpeg` hits that when
/// the stream is not ready yet and ffmpeg is still alive.
public enum ProcessExit {
  public static func statusIfExited(
    isRunning: Bool,
    wasLaunched: Bool,
    status: () -> Int32
  ) -> Int32? {
    guard wasLaunched, !isRunning else { return nil }
    return status()
  }

  /// Detail for the Start path that waits until ffmpeg's stream is ready.
  public static func ffmpegNotReadyDetail(isRunning: Bool, wasLaunched: Bool, status: Int32?)
    -> String
  {
    if let status, wasLaunched, !isRunning {
      return "exited with status \(status)"
    }
    return "the stream was not ready within 5 s"
  }
}

public enum RestartBackoff {
  public static let steps: [TimeInterval] = [1, 2, 4, 8, 16, 30]
  public static let problemAfter = 5
  public static let stableResetSeconds: TimeInterval = 60

  public static func delay(forFailureCount failureCount: Int) -> TimeInterval {
    let index = min(max(failureCount, 1), steps.count) - 1
    return steps[index]
  }

  public static func showsProblem(failureCount: Int) -> Bool {
    failureCount >= problemAfter
  }

  public static func shouldResetCounter(stableFor seconds: TimeInterval) -> Bool {
    seconds >= stableResetSeconds
  }
}

public struct StallDetector: Equatable {
  public var lastBytes: UInt64?
  public var unchangedSince: Date?
  public var window: TimeInterval

  public init(window: TimeInterval = 6) {
    self.window = window
  }

  public mutating func observe(bytes: UInt64, now: Date) -> Bool {
    if lastBytes != bytes {
      lastBytes = bytes
      unchangedSince = now
      return false
    }
    if unchangedSince == nil {
      unchangedSince = now
      return false
    }
    guard let unchangedSince else { return false }
    return now.timeIntervalSince(unchangedSince) >= window
  }

  public mutating func reset() {
    lastBytes = nil
    unchangedSince = nil
  }
}

public enum HealthText {
  public static func restarted(component: String, count: Int, limit: Int, time: String) -> String {
    "\(time) \(component) restarted after exit (\(count)/\(limit)) — OK"
  }

  public static func stalled(time: String) -> String {
    "\(time) audio stalled, restarting ffmpeg"
  }

  public static func waiting(deviceName: String) -> String {
    "Audio interface unplugged, waiting for \(deviceName)…"
  }

  public static func problem(component: String) -> String {
    "\(component) keeps stopping. Still retrying every 30 s."
  }

  /// Shown on every failed attempt, including the 5 s "stream not ready" timeout.
  /// The recovered "— OK" line is only for a restart that has not failed again.
  public static func retrying(
    component: String,
    detail: String,
    count: Int,
    limit: Int,
    time: String,
    extra: String?
  ) -> String {
    var lines = ["\(time) \(component): \(detail) (\(count)/\(limit)). Retrying."]
    if let extra {
      let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        let cap = 220
        lines.append(trimmed.count > cap ? String(trimmed.prefix(cap)) + "…" : trimmed)
      }
    }
    if count >= limit {
      lines.append("Still retrying every 30 s.")
    }
    return lines.joined(separator: "\n")
  }
}

public enum StreamLog {
  public static func isFrameDrop(_ line: String) -> Bool {
    let folded = line.lowercased()
    if folded.contains("thread message queue blocking") { return true }
    if folded.contains("aresample") && (folded.contains("drift") || folded.contains("queue")) {
      return true
    }
    return false
  }

  public static func isFailure(_ line: String) -> Bool {
    let folded = line.lowercased()
    if folded.contains("no decoder") { return true }
    if folded.contains("error") { return true }
    if folded.contains("invalid argument") { return true }
    if folded.contains("failed") { return true }
    return false
  }
}
