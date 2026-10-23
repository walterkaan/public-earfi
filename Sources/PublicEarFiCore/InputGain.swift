import Foundation

/// Mixes an interleaved frame down to one mono sample.
/// `sum` adds every channel, so a voice on only the left or only the right
/// stays at its own level. `average` divides by the channel count (a
/// one-sided stereo signal is about 6 dB quieter) and is kept for comparison.
public enum MonoDownmix {
  public static func sum(interleaved samples: [Float], channelCount: Int) -> [Float] {
    mix(interleaved: samples, channelCount: channelCount, scale: 1)
  }

  public static func average(interleaved samples: [Float], channelCount: Int) -> [Float] {
    guard channelCount > 0 else { return [] }
    return mix(interleaved: samples, channelCount: channelCount, scale: 1 / Float(channelCount))
  }

  private static func mix(interleaved samples: [Float], channelCount: Int, scale: Float) -> [Float]
  {
    guard channelCount > 0 else { return [] }
    let frames = samples.count / channelCount
    if frames == 0 { return [] }
    if channelCount == 1 {
      return Array(samples.prefix(frames))
    }
    var mono: [Float] = []
    mono.reserveCapacity(frames)
    for frame in 0..<frames {
      var total: Float = 0
      let base = frame * channelCount
      for channel in 0..<channelCount {
        total += samples[base + channel]
      }
      mono.append(total * scale)
    }
    return mono
  }
}

/// Mono sums every device channel. Stereo copies the chosen input and the
/// next one. Both run on the samples we already have, before any resampler.
public enum CaptureMix {
  public static func render(
    interleaved samples: [Float],
    channelCount: Int,
    mode: ChannelMode,
    inputChannel: Int
  ) -> [Float] {
    switch mode {
    case .mono:
      return MonoDownmix.sum(interleaved: samples, channelCount: channelCount)
    case .stereo:
      let indices = CaptureChannelMap.indices(
        mode: .stereo, inputChannel: inputChannel, inputCount: channelCount)
      return select(interleaved: samples, channelCount: channelCount, indices: indices)
    }
  }

  public static func select(interleaved samples: [Float], channelCount: Int, indices: [Int])
    -> [Float]
  {
    guard channelCount > 0, !indices.isEmpty else { return [] }
    let frames = samples.count / channelCount
    if frames == 0 { return [] }
    var output: [Float] = []
    output.reserveCapacity(frames * indices.count)
    for frame in 0..<frames {
      let base = frame * channelCount
      for index in indices {
        let channel = min(max(0, index), channelCount - 1)
        output.append(samples[base + channel])
      }
    }
    return output
  }
}

/// Input boost applied after the mono downmix. 0 dB leaves the samples
/// alone. A soft knee keeps a boosted peak inside ±1 instead of hard-clipping.
public enum InputGain {
  public static let minimumDB = -12.0
  public static let maximumDB = 24.0
  public static let defaultDB = 0.0
  /// Peaks under this pass through. Louder ones bend toward ±1.
  public static let limitThreshold: Float = 0.9

  public static func clamped(_ db: Double) -> Double {
    guard db.isFinite else { return defaultDB }
    return min(maximumDB, max(minimumDB, db))
  }

  public static func label(_ db: Double) -> String {
    String(format: "%+.0f dB", clamped(db))
  }

  public static func linear(_ db: Double) -> Float {
    Float(pow(10, clamped(db) / 20))
  }

  public static func softLimit(_ sample: Float) -> Float {
    let threshold = limitThreshold
    let magnitude = abs(sample)
    if magnitude <= threshold {
      return sample
    }
    let sign: Float = sample < 0 ? -1 : 1
    let headroom = 1 - threshold
    let over = magnitude - threshold
    let shaped = threshold + headroom * (1 - exp(-over / headroom))
    return sign * min(shaped, 1)
  }

  public static func apply(_ samples: [Float], gainDB: Double) -> [Float] {
    let scale = linear(gainDB)
    return samples.map { softLimit($0 * scale) }
  }

  /// Mono mode sums every channel first, then gain and the soft limiter.
  /// A single side is not turned down. A loud sum bends at the limiter
  /// instead of hard-clipping. Stereo keeps the samples it was given.
  public static func render(
    interleaved samples: [Float],
    channelCount: Int,
    downmixToMono: Bool,
    gainDB: Double
  ) -> [Float] {
    let source =
      downmixToMono
      ? MonoDownmix.sum(interleaved: samples, channelCount: channelCount)
      : samples
    return apply(source, gainDB: gainDB)
  }
}

public enum SignalLevel {
  public static func decibels(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return -140 }
    var sum: Float = 0
    for sample in samples {
      sum += sample * sample
    }
    let rms = sqrt(sum / Float(samples.count))
    return Double(20 * log10(max(rms, 1e-7)))
  }
}
