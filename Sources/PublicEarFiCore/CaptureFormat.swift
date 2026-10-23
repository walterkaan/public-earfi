import Foundation

/// The device's own input format. RoomCast converts this to 48 kHz.
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

/// How the selected device is opened. The channel count is that device's own
/// input, read after the device is chosen. A previous engine, or the system
/// default microphone, is `staleChannels` and is not applied. Capture does
/// not widen a client format.
public enum CaptureDeviceBinding {
  public static func bound(
    device: CaptureStreamDescription, staleChannels: Int
  ) -> CaptureStreamDescription? {
    guard device.canOpen else { return nil }
    _ = staleChannels
    return device
  }

  public static func captureNote(channels: Int) -> String {
    let count = max(0, channels)
    let noun = count == 1 ? "channel" : "channels"
    return "native capture, \(count) \(noun)"
  }
}

/// Counters from the tap through stdin, so a silent 48 kHz device can be
/// told apart from a tap that never ran.
public struct CaptureDelivery: Equatable {
  public var callbacks: Int
  public var framesIn: Int
  public var framesOut: Int
  public var dropped: Int
  public var bytesWritten: Int
  public var rateNote: String

  public init(
    callbacks: Int = 0,
    framesIn: Int = 0,
    framesOut: Int = 0,
    dropped: Int = 0,
    bytesWritten: Int = 0,
    rateNote: String = "rate conversion not used yet"
  ) {
    self.callbacks = callbacks
    self.framesIn = framesIn
    self.framesOut = framesOut
    self.dropped = dropped
    self.bytesWritten = bytesWritten
    self.rateNote = rateNote
  }

  public var line: String {
    "callbacks \(callbacks), frames in \(framesIn), frames out \(framesOut), dropped \(dropped), stdin bytes \(bytesWritten), \(rateNote)"
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
  /// Wait after a format or alive notification so a Bluetooth headset can
  /// finish switching to the hands-free profile before capture reopens.
  public static let formatSettleSeconds: TimeInterval = 1
  public static let formatRebuildWindow: TimeInterval = 30
  public static let formatRebuildLimit = 3
  /// A call-mode switch can notify several times. Allow more than the
  /// wired-device limit so that burst does not stop the broadcast.
  public static let bluetoothFormatRebuildLimit = 6
  public static let inputSettleRetries = 6

  public static func rebuildLimit(bluetooth: Bool) -> Int {
    bluetooth ? bluetoothFormatRebuildLimit : formatRebuildLimit
  }

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
  /// A headset that is still switching to call mode is the exception:
  /// `notReadyMessage` stays retryable for a few attempts.
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
      return "\(name) has no input RoomCast can open. Pick another device in Settings."
    }
    return
      "\(name) is sending \(stream.summary). RoomCast cannot convert that to 48 kHz. Pick another device, or choose a different format in Audio MIDI Setup. The app does not change the device's sample rate."
  }

  /// Zero channels, or an unreadable format, while the device is still
  /// connected. Wording avoids the permanent phrases in `shouldRetry`.
  public static func notReadyMessage(deviceName: String) -> String {
    let name = deviceName.isEmpty ? "The selected audio device" : deviceName
    return "\(name) is still switching its input. RoomCast will try again shortly."
  }

  public static func isInputSettling(_ message: String) -> Bool {
    message.lowercased().contains("still switching its input")
  }

  /// Shown once when capture opened but ffmpeg received no samples.
  /// Start must not keep restarting on this.
  public static func noAudioMessage(deviceName: String) -> String {
    let name = deviceName.isEmpty ? "the selected input" : deviceName
    return "No audio from \(name)."
  }

  public static func inputGaveUpMessage(deviceName: String) -> String {
    let name = deviceName.isEmpty ? "The selected audio device" : deviceName
    return
      "\(name) did not present an input RoomCast could use. Pick it again in Settings, or choose another microphone. The app does not change the device's sample rate."
  }

  public static func conversionStoppedMessage(deviceName: String, summary: String) -> String {
    let name = deviceName.isEmpty ? "this device" : deviceName
    return
      "Audio from \(name) is not reaching the broadcast (\(summary)). Check the selected input. RoomCast does not change the device's sample rate."
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

/// Core Audio transport four-character codes. Names stay generic.
/// `blea` is Bluetooth LE; the symbol is not required, so older SDKs still compile.
public enum AudioTransportLabel {
  public static let bluetooth = fourCC("blue")
  public static let bluetoothLE = fourCC("blea")
  public static let builtIn = fourCC("bltn")
  public static let usb = fourCC("usb ")
  public static let aggregate = fourCC("grup")
  public static let autoAggregate = fourCC("fgrp")
  public static let virtual = fourCC("virt")

  public static func fourCC(_ text: String) -> UInt32 {
    var value: UInt32 = 0
    let bytes = Array(text.utf8.prefix(4))
    for byte in bytes {
      value = (value << 8) | UInt32(byte)
    }
    if bytes.count < 4 {
      value <<= UInt32((4 - bytes.count) * 8)
    }
    return value
  }

  public static func isBluetooth(_ raw: UInt32) -> Bool {
    raw == bluetooth || raw == bluetoothLE
  }

  public static func describe(_ raw: UInt32) -> String {
    let name: String
    if isBluetooth(raw) {
      name = "Bluetooth"
    } else if raw == builtIn {
      name = "Built-in"
    } else if raw == usb {
      name = "USB"
    } else if raw == aggregate || raw == autoAggregate {
      name = "Aggregate"
    } else if raw == virtual {
      name = "Virtual"
    } else {
      name = "Unknown"
    }
    let code = fourChar(raw).trimmingCharacters(in: .whitespaces)
    let visible = code.isEmpty ? String(format: "0x%08X", raw) : code
    return "\(name) (\(visible))"
  }

  private static func fourChar(_ raw: UInt32) -> String {
    let bytes = [
      UInt8((raw >> 24) & 0xFF),
      UInt8((raw >> 16) & 0xFF),
      UInt8((raw >> 8) & 0xFF),
      UInt8(raw & 0xFF),
    ]
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
      return String(format: "0x%08X", raw)
    }
    return String(bytes: bytes, encoding: .utf8) ?? String(format: "0x%08X", raw)
  }
}

/// How many capture reopens a format-change burst may cause.
public struct FormatRebuildBudget: Equatable {
  public private(set) var marks: [Date]
  public var limit: Int
  public var window: TimeInterval

  public init(limit: Int, window: TimeInterval = CaptureFormatPlan.formatRebuildWindow) {
    self.marks = []
    self.limit = limit
    self.window = window
  }

  /// True when another reopen is allowed. A full window does not record a mark.
  public mutating func allow(at now: Date) -> Bool {
    marks.removeAll { now.timeIntervalSince($0) > window }
    guard marks.count < limit else { return false }
    marks.append(now)
    return true
  }
}
