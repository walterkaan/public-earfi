import Foundation

public enum FFmpegCommand {
  /// Opus RTP always uses a 48 kHz clock (RFC 7587). The app encodes only at
  /// that rate, in 20 ms frames, so listeners never pick a sample rate.
  public static let sampleRate = 48_000
  public static let frameDurationMilliseconds = 20

  public static func arguments(deviceName: String, settings: AppSettings) -> [String] {
    let pan = panFilter(mode: settings.channelMode, inputChannel: settings.inputChannel)
    // AVFoundation timestamps follow the host and arrive in bursts that are
    // not 20 ms. A USB interface clocked at 48 kHz still drifts against that
    // timeline. WebRTC then inserts or drops a frame on a regular period,
    // which is the click. aresample rebuilds a continuous 48 kHz timeline
    // (async=1 fill/trim, first packet at PTS 0) before Opus packetizes it.
    // Wall-clock timestamps are not used as well: they would feed that same
    // burstiness back into the resampler.
    return [
      "-hide_banner",
      "-nostdin",
      "-loglevel",
      "warning",
      "-thread_queue_size",
      "1024",
      "-f",
      "avfoundation",
      "-i",
      ":\(deviceName)",
      "-af",
      "\(pan),aresample=\(sampleRate):async=1:first_pts=0",
      "-ar",
      String(sampleRate),
      "-ac",
      String(settings.opusChannelCount),
      "-c:a",
      "libopus",
      "-b:a",
      "\(settings.resolvedBitrateKbps)k",
      "-application",
      settings.opusApplication,
      "-frame_duration",
      String(frameDurationMilliseconds),
      "-muxdelay",
      "0",
      "-muxpreload",
      "0",
      "-f",
      "rtsp",
      "-rtsp_transport",
      "tcp",
      "rtsp://127.0.0.1:8554/\(settings.streamName)",
    ]
  }

  public static func panFilter(mode: ChannelMode, inputChannel: Int) -> String {
    let index = max(0, inputChannel - 1)
    switch mode {
    case .mono:
      return "pan=mono|c0=c\(index)"
    case .stereo:
      return "pan=stereo|c0=c\(index)|c1=c\(index + 1)"
    }
  }
}
