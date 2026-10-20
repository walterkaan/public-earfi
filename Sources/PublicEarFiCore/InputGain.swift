import Foundation

/// Averages every channel of an interleaved frame into one mono sample.
/// Stereo is (L+R)/2. One channel is copied through.
public enum MonoDownmix {
  public static func average(interleaved samples: [Float], channelCount: Int) -> [Float] {
    guard channelCount > 0 else { return [] }
    let frames = samples.count / channelCount
    if frames == 0 { return [] }
    if channelCount == 1 {
      return Array(samples.prefix(frames))
    }
    var mono: [Float] = []
    mono.reserveCapacity(frames)
    let scale = 1 / Float(channelCount)
    for frame in 0..<frames {
      var sum: Float = 0
      let base = frame * channelCount
      for channel in 0..<channelCount {
        sum += samples[base + channel]
      }
      mono.append(sum * scale)
    }
    return mono
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

  /// Mono mode averages every channel first. Stereo keeps the mapped pair.
  /// Gain and the soft limiter run after that.
  public static func render(
    interleaved samples: [Float],
    channelCount: Int,
    downmixToMono: Bool,
    gainDB: Double
  ) -> [Float] {
    let source =
      downmixToMono
      ? MonoDownmix.average(interleaved: samples, channelCount: channelCount)
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
