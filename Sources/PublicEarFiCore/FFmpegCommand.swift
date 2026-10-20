import Foundation

public enum FFmpegCommand {
  public static func arguments(deviceName: String, settings: AppSettings) -> [String] {
    let pan = panFilter(mode: settings.channelMode, inputChannel: settings.inputChannel)
    // aresample converts the interface's native rate (often 44.1 or 48 kHz
    // float) to an Opus rate. async= is omitted: async=1 fill-and-trims for
    // about one sample of clock skew, and that garbled a 44.1 kHz device
    // that had been forced to 48 kHz. The device rate is left alone.
    return [
      "-hide_banner",
      "-nostdin",
      "-loglevel",
      "warning",
      "-thread_queue_size",
      "4096",
      "-f",
      "avfoundation",
      "-i",
      ":\(deviceName)",
      "-af",
      "\(pan),aresample=\(settings.sampleRate)",
      "-ar",
      String(settings.sampleRate),
      "-ac",
      String(settings.opusChannelCount),
      "-c:a",
      "libopus",
      "-b:a",
      "\(settings.resolvedBitrateKbps)k",
      "-application",
      settings.opusApplication,
      "-frame_duration",
      "20",
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
