import Foundation

public enum FFmpegCommand {
  /// Opus RTP always uses a 48 kHz clock (RFC 7587). The app encodes only at
  /// that rate, in 20 ms frames, so listeners never pick a sample rate.
  public static let sampleRate = 48_000
  public static let frameDurationMilliseconds = 20

  /// ffmpeg reads raw PCM on stdin. The app captures with Core Audio.
  /// AVFoundation's ffmpeg device is not used: it stamps audio with the host
  /// clock in uneven bursts, and WebRTC turns that into a regular click even
  /// when the USB device itself is a steady 48 kHz (the same device is clean
  /// in other apps).
  public static func arguments(settings: AppSettings) -> [String] {
    [
      "-hide_banner",
      "-nostdin",
      "-loglevel",
      "warning",
      "-thread_queue_size",
      "1024",
      "-f",
      "f32le",
      "-ar",
      String(sampleRate),
      "-ac",
      String(settings.opusChannelCount),
      "-i",
      "pipe:0",
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
}

public enum CaptureChannelMap {
  /// Zero-based device channels to copy into the pipe.
  /// Mono keeps the desk input chosen in Settings. Stereo takes that
  /// channel and the next one.
  public static func indices(mode: ChannelMode, inputChannel: Int, inputCount: Int) -> [Int] {
    let count = max(1, inputCount)
    let first = min(max(0, inputChannel - 1), count - 1)
    switch mode {
    case .mono:
      return [first]
    case .stereo:
      return [first, min(first + 1, count - 1)]
    }
  }
}
