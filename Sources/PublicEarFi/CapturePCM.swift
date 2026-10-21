import AVFoundation
import Foundation
import PublicEarFiCore

/// Copies an audio tap into an interleaved float array. The tap pointer is
/// only valid for the duration of the callback, so this copies it before
/// returning and never indexes past the buffer's own counts.
enum CapturePCM {
  static func interleavedFloats(from buffer: AVAudioPCMBuffer) -> [Float]? {
    let format = buffer.format
    guard format.commonFormat == .pcmFormatFloat32 else { return nil }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)
    guard frameCount > 0, channelCount > 0 else { return nil }
    // A 2-channel tap can report interleaved while the samples live only in
    // floatChannelData, with an empty AudioBufferList. Reading the list
    // first then drops every callback, so stdin stays empty. Try both.
    if format.isInterleaved {
      if let packed = interleaved(buffer, frameCount: frameCount, channelCount: channelCount) {
        return packed
      }
      return channelPointers(buffer, frameCount: frameCount, channelCount: channelCount)
    }
    if let planar = channelPointers(buffer, frameCount: frameCount, channelCount: channelCount) {
      return planar
    }
    return interleaved(buffer, frameCount: frameCount, channelCount: channelCount)
  }

  private static func interleaved(
    _ buffer: AVAudioPCMBuffer, frameCount: Int, channelCount: Int
  ) -> [Float]? {
    let list = buffer.audioBufferList.pointee
    guard list.mNumberBuffers > 0, let raw = list.mBuffers.mData else { return nil }
    let count = PCMCopy.interleavedSampleCount(
      byteSize: Int(list.mBuffers.mDataByteSize),
      frameCount: frameCount,
      channelCount: channelCount
    )
    guard count > 0 else { return nil }
    let pointer = raw.bindMemory(to: Float.self, capacity: count)
    return Array(UnsafeBufferPointer(start: pointer, count: count))
  }

  /// `floatChannelData` indexes frames directly. `stride` is not a frame
  /// count: on an interleaved stereo buffer it is often 2, and treating it
  /// as the length keeps only two frames.
  private static func channelPointers(
    _ buffer: AVAudioPCMBuffer, frameCount: Int, channelCount: Int
  ) -> [Float]? {
    guard let channels = buffer.floatChannelData else { return nil }
    guard frameCount > 0, channelCount > 0 else { return nil }
    if buffer.format.isInterleaved {
      let source = channels[0]
      var output = [Float]()
      output.reserveCapacity(frameCount * channelCount)
      for frame in 0..<frameCount {
        let base = frame * channelCount
        for channel in 0..<channelCount {
          output.append(source[base + channel])
        }
      }
      return output
    }
    var planar = [[Float]]()
    planar.reserveCapacity(channelCount)
    for channel in 0..<channelCount {
      planar.append(Array(UnsafeBufferPointer(start: channels[channel], count: frameCount)))
    }
    return PCMCopy.interleave(channels: planar, frameCount: frameCount)
  }
}
