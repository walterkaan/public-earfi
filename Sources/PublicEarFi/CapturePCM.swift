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
    if format.isInterleaved || buffer.floatChannelData == nil {
      return interleaved(buffer, frameCount: frameCount, channelCount: channelCount)
    }
    return planar(buffer, frameCount: frameCount, channelCount: channelCount)
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

  private static func planar(
    _ buffer: AVAudioPCMBuffer, frameCount: Int, channelCount: Int
  ) -> [Float]? {
    guard let channels = buffer.floatChannelData else { return nil }
    let frames = PCMCopy.planarFrameCount(frameLength: frameCount, stride: Int(buffer.stride))
    guard frames > 0 else { return nil }
    let available = Int(buffer.audioBufferList.pointee.mNumberBuffers)
    let usableChannels = min(channelCount, max(0, available))
    guard usableChannels > 0 else { return nil }
    var planar = [[Float]]()
    planar.reserveCapacity(usableChannels)
    for channel in 0..<usableChannels {
      planar.append(Array(UnsafeBufferPointer(start: channels[channel], count: frames)))
    }
    return PCMCopy.interleave(channels: planar, frameCount: frames)
  }
}
