import Foundation

/// The device's own input format. Public EarFi converts this to 48 kHz.
/// It does not change the interface clock.
public struct CaptureStreamDescription: Equatable, Sendable {
  public var sampleRate: Double
  public var channelCount: Int
  public var bitsPerChannel: Int
  public var isFloat: Bool
  public var isInterleaved: Bool

  public init(
    sampleRate: Double,
    channelCount: Int,
    bitsPerChannel: Int,
    isFloat: Bool,
    isInterleaved: Bool
  ) {
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.bitsPerChannel = bitsPerChannel
    self.isFloat = isFloat
    self.isInterleaved = isInterleaved
  }

  public var canOpen: Bool {
    sampleRate.isFinite && sampleRate > 0 && channelCount > 0
  }

  public var summary: String {
    let rate: String
    if sampleRate.isFinite, sampleRate.rounded() == sampleRate, sampleRate < 1_000_000 {
      rate = String(Int(sampleRate))
    } else {
      rate = String(format: "%.1f", sampleRate)
    }
    let kind = isFloat ? "float" : "integer"
    let layout = isInterleaved ? "interleaved" : "non-interleaved"
    let channels = channelCount == 1 ? "1 channel" : "\(channelCount) channels"
    return "\(rate) Hz, \(bitsPerChannel)-bit \(kind), \(channels), \(layout)"
  }
}

/// How a device format becomes 48 kHz float for ffmpeg.
/// An interleaved float layout is only requested for one or two channels.
/// Wider devices use non-interleaved float, because the interleaved
/// initializer cannot represent them. Mono sums every channel in our own
/// code before the rate converter, so the converter never picks channel 0.
public enum CaptureFormatPlan {
  public static let encodeRate = 48_000.0
  public static let silenceDB = -50.0
  /// Once the no-signal line is showing, the level has to rise to here
  /// before it can clear. A reading that jitters around `silenceDB` stays put.
  public static let silenceClearDB = -40.0
  public static let silenceWarningSeconds: TimeInterval = 5
  public static let silenceClearSeconds: TimeInterval = 2

  /// Channels the 48 kHz converter is allowed to see, after our mix.
  /// Mono is already one channel. Stereo is the chosen pair.
  public static func rateChannels(inputChannels: Int, mono: Bool) -> Int {
    guard inputChannels > 0 else { return 0 }
    return mono ? 1 : 2
  }

  /// Source channel for each output channel, in order. A shorter map would
  /// keep channel 0 and drop the rest, which is the one-sided mono bug.
  public static func identityChannelMap(channelCount: Int) -> [Int] {
    guard channelCount > 0 else { return [] }
    return Array(0..<channelCount)
  }

  public static func pipeChannels(mono: Bool) -> Int {
    mono ? 1 : 2
  }

  /// `true` means try interleaved float first. More than two channels are
  /// non-interleaved only.
  public static func interleavedChoices(channelCount: Int) -> [Bool] {
    guard channelCount > 0 else { return [] }
    if channelCount <= 2 { return [true, false] }
    return [false]
  }

  /// Opening the device is a configuration failure. Retrying it leaves
  /// "Retrying" on screen for a format the app cannot use.
  public static func shouldRetry(message: String) -> Bool {
    let folded = message.lowercased()
    let permanent = [
      "could not build",
      "could not convert",
      "cannot convert",
      "no input",
      "did not open",
      "not connected",
      "could not map",
      "could not open",
      "cannot use",
      "allow the microphone",
      "has no input",
      "not reaching",
    ]
    return !permanent.contains { folded.contains($0) }
  }

  public static func impossibleMessage(deviceName: String, stream: CaptureStreamDescription)
    -> String
  {
    let name = deviceName.isEmpty ? "The selected audio device" : deviceName
    if !stream.canOpen {
      return "\(name) has no input Public EarFi can open. Pick another device in Settings."
    }
    return
      "\(name) is sending \(stream.summary). Public EarFi cannot convert that to 48 kHz. Pick another device, or choose a different format in Audio MIDI Setup. The app does not change the device's sample rate."
  }

  public static func conversionStoppedMessage(deviceName: String, summary: String) -> String {
    let name = deviceName.isEmpty ? "this device" : deviceName
    return
      "Audio from \(name) is not reaching the broadcast (\(summary)). Check the selected input. Public EarFi does not change the device's sample rate."
  }
}

/// Shows the no-signal line only after sustained quiet, and keeps it up
/// until the signal has been back for a moment. A single loud frame, or a
/// level that jitters around the threshold, does not flip the line.
public struct SilenceWatch: Equatable {
  public var showing = false
  public var quietSince: Date?
  public var heardSince: Date?

  public init() {}

  public mutating func reset() {
    showing = false
    quietSince = nil
    heardSince = nil
  }

  public mutating func update(decibels: Double, now: Date) {
    let silent =
      showing
      ? decibels < CaptureFormatPlan.silenceClearDB
      : decibels < CaptureFormatPlan.silenceDB
    if silent {
      heardSince = nil
      if quietSince == nil { quietSince = now }
      if let quietSince,
        now.timeIntervalSince(quietSince) >= CaptureFormatPlan.silenceWarningSeconds
      {
        showing = true
      }
      return
    }
    quietSince = nil
    guard showing else {
      heardSince = nil
      return
    }
    if heardSince == nil { heardSince = now }
    if let heardSince, now.timeIntervalSince(heardSince) >= CaptureFormatPlan.silenceClearSeconds {
      showing = false
      self.heardSince = nil
    }
  }
}
