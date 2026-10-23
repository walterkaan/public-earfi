import Foundation

/// How many samples a capture callback may read. The byte size, the frame
/// length, and the planar stride can disagree; reading past the shortest of
/// them walks off the audio buffer and corrupts the heap.
public enum PCMCopy {
  public static func interleavedSampleCount(
    byteSize: Int, frameCount: Int, channelCount: Int
  ) -> Int {
    guard byteSize >= MemoryLayout<Float>.size, frameCount > 0, channelCount > 0 else {
      return 0
    }
    let fromBytes = byteSize / MemoryLayout<Float>.size
    return min(fromBytes, frameCount * channelCount)
  }

  public static func planarFrameCount(frameLength: Int, stride: Int) -> Int {
    guard frameLength > 0, stride > 0 else { return 0 }
    return min(frameLength, stride)
  }

  /// Interleaves planar channels. Each channel is read only up to its own
  /// length, and never past `frameCount`. A short channel is filled with 0.
  public static func interleave(channels: [[Float]], frameCount: Int) -> [Float] {
    guard frameCount > 0, !channels.isEmpty else { return [] }
    let channelCount = channels.count
    var output = [Float](repeating: 0, count: frameCount * channelCount)
    for (channelIndex, channel) in channels.enumerated() {
      let count = min(frameCount, channel.count)
      guard count > 0 else { continue }
      for frame in 0..<count {
        output[frame * channelCount + channelIndex] = channel[frame]
      }
    }
    return output
  }
}
