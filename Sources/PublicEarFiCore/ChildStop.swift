import Foundation

/// How a mediamtx or ffmpeg child is stopped. SIGTERM, then SIGKILL after
/// `grace` if it is still alive. The numbers match Darwin and Linux.
public enum ChildStop {
  public static let termSignal: Int32 = 15
  public static let killSignal: Int32 = 9
  public static let grace: TimeInterval = 2

  public struct Target: Equatable {
    public var pid: Int32
    public var group: Int32

    public init(pid: Int32, group: Int32) {
      self.pid = pid
      self.group = group
    }

    /// Signal the process group only when this pid leads it.
    /// Any other group is the app's, and signaling it would kill RoomCast.
    public var signalTarget: Int32 {
      if pid > 1, group > 1, group == pid {
        return -group
      }
      return pid
    }
  }

  /// True when a recorded pid is still the helper we started.
  /// A reused pid, or a process whose path we cannot read, is left alone.
  public static func shouldReap(pid: Int32, actualPath: String?, expectedPath: String?) -> Bool {
    guard pid > 1, let actualPath, !actualPath.isEmpty else { return false }
    if let expectedPath, !expectedPath.isEmpty, actualPath != expectedPath {
      return false
    }
    return true
  }
}

extension SupervisedPIDs {
  public struct ReapTarget: Equatable {
    public var pid: Int32
    public var group: Int32
    public var executable: String?

    public init(pid: Int32, group: Int32, executable: String?) {
      self.pid = pid
      self.group = group
      self.executable = executable
    }
  }

  public var reapTargets: [ReapTarget] {
    var targets: [ReapTarget] = []
    if let mediamtx {
      targets.append(
        ReapTarget(pid: mediamtx, group: mediamtxGroup ?? 0, executable: mediamtxExecutable))
    }
    if let ffmpeg {
      targets.append(ReapTarget(pid: ffmpeg, group: ffmpegGroup ?? 0, executable: ffmpegExecutable))
    }
    return targets
  }
}
