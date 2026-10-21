import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import PublicEarFiCore
import os

/// Captures one Core Audio device and writes 48 kHz little-endian float PCM
/// to ffmpeg's stdin. The device is the HAL device chosen in Settings (by
/// UID), not an entry in ffmpeg's avfoundation list. Mono sums every input
/// channel in this process before the 48 kHz converter.
///
/// Each Start builds a new IOProc on that device and the previous one is
/// destroyed, including after "No audio from". The format is the device's
/// own input. A reused engine used to keep the default microphone's one
/// channel, and widening that format stopped the callback.
///
/// AVFoundation capture inside ffmpeg stamps audio with the host clock in
/// uneven bursts. WebRTC then inserts or drops a frame on a regular period,
/// which is the click, even when the same device is clean in other apps.
/// ffmpeg's f32le demuxer timestamps from the sample count, so this pipe
/// stays on a continuous 20 ms grid.
final class CapturePipe {
  private let makeSession: () -> DeviceInputSession
  private var session: DeviceInputSession?
  private let condition = NSCondition()
  private var formatConverter: AVAudioConverter?
  private var formatTarget: AVAudioFormat?
  private var formatBuffer: AVAudioPCMBuffer?
  private var rateConverter: AVAudioConverter?
  private var rateTarget: AVAudioFormat?
  private var rateBuffer: AVAudioPCMBuffer?
  private var rateInputRate = 0.0
  private var rateChannelCount = 1
  private var outputHandle: FileHandle?
  private var outputFD: Int32 = -1
  private var running = false
  private var stopWriter = false
  private var writerRunning = false
  private var writerDone: DispatchSemaphore?
  private var ring = [UInt8](repeating: 0, count: 256 * 1024)
  private var readPos = 0
  private var writePos = 0
  private var stored = 0
  private var frameBytes = MemoryLayout<Float>.size
  private var channelMode: ChannelMode = .mono
  private var inputChannel = 1
  private var openedInputChannels = 0
  private var openedDeviceChannels = 0
  private let gainLock = NSLock()
  private var gainDB = InputGain.defaultDB
  private let callbackLock = NSLock()
  private var accepting = false
  private var inFlight = 0
  private var formatSummary = "input format unknown"
  private var nativeSummary = ""
  private var openedDeviceName = ""
  private var conversionProblem: String?
  private var consecutiveConversionFailures = 0
  private let level = OSAllocatedUnfairLock(
    initialState: CaptureLevel(decibels: -120, at: .distantPast))
  private let bytesOut = OSAllocatedUnfairLock(initialState: 0)
  private let deliveryLock = NSLock()
  private var callbackCount = 0
  private var framesIn = 0
  private var framesOut = 0
  private var droppedCallbacks = 0
  private var rateNote = "rate conversion not used yet"
  private var openedNative = CaptureStreamDescription(
    sampleRate: 0, channelCount: 0, bitsPerChannel: 0, isFloat: false, isInterleaved: true)

  func bytesWritten() -> Int {
    bytesOut.withLock { $0 }
  }

  func delivery() -> CaptureDelivery {
    deliveryLock.lock()
    let snapshot = CaptureDelivery(
      callbacks: callbackCount,
      framesIn: framesIn,
      framesOut: framesOut,
      dropped: droppedCallbacks,
      bytesWritten: bytesWritten(),
      rateNote: rateNote
    )
    deliveryLock.unlock()
    return snapshot
  }

  var captureIsRunning: Bool { session?.isRunning == true && running }

  init(makeSession: @escaping () -> DeviceInputSession = { HALDeviceInputSession() }) {
    self.makeSession = makeSession
  }

  var openedNativeDescription: CaptureStreamDescription { openedNative }

  func recentDecibels(now: Date = Date()) -> Double {
    level.withLock { state in
      if now.timeIntervalSince(state.at) > 1 { return -120 }
      return state.decibels
    }
  }

  func takeConversionProblem() -> String? {
    callbackLock.lock()
    defer { callbackLock.unlock() }
    let problem = conversionProblem
    conversionProblem = nil
    return problem
  }

  func setGainDB(_ db: Double) {
    gainLock.lock()
    gainDB = InputGain.clamped(db)
    gainLock.unlock()
  }

  /// Starts capture. Returns an error string the UI can show.
  /// Builds a new device session. A failed open destroys that session before
  /// returning, so the next Start is not left with the previous device.
  func start(
    deviceID: AudioDeviceID,
    channelMode: ChannelMode,
    inputChannel: Int,
    output: FileHandle,
    deviceName: String = ""
  ) -> String? {
    stop()
    let session = makeSession()
    self.session = session
    self.channelMode = channelMode
    self.inputChannel = inputChannel
    openedDeviceName = deviceName
    let mono = channelMode == .mono
    let pipeChannels = CaptureFormatPlan.pipeChannels(mono: mono)
    guard pipeChannels > 0 else {
      stop()
      return CaptureFormatPlan.impossibleMessage(
        deviceName: deviceName,
        stream: CaptureStreamDescription(
          sampleRate: 0, channelCount: 0, bitsPerChannel: 0, isFloat: false, isInterleaved: true)
      )
    }
    // Accept buffers before the device starts. The first callbacks can arrive
    // inside start(), and those used to be dropped.
    armWriter(output: output, pipeChannels: pipeChannels)
    let native: CaptureStreamDescription
    switch session.start(
      deviceID: deviceID,
      onBuffer: { [weak self] buffer in
        self?.consume(buffer)
      })
    {
    case .ready(let value):
      native = value
    case .failed(let message):
      stop()
      return settlingMessage(message, deviceName: deviceName)
    }
    guard native.canOpen else {
      stop()
      return CaptureFormatPlan.impossibleMessage(deviceName: deviceName, stream: native)
    }
    nativeSummary = native.summary
    openedNative = native
    running = true
    let inputCount = max(1, native.channelCount)
    openedInputChannels = inputCount
    openedDeviceChannels = inputCount
    let mix =
      mono
      ? "mono sums \(inputCount) of \(openedDeviceChannels) channels"
      : "stereo"
    let note = CaptureDeviceBinding.captureNote(channels: inputCount)
    formatSummary = AudioInputBind.summary(native: native, capture: native) + "; \(mix); \(note)"
    return nil
  }

  /// Opens the same writer `start` uses, without a Core Audio device.
  /// Tests push buffers through mix, resample, and the stdin pipe.
  func startPipe(
    output: FileHandle,
    channelMode: ChannelMode,
    inputChannel: Int,
    deliveringChannels: Int
  ) {
    stop()
    self.channelMode = channelMode
    self.inputChannel = inputChannel
    openedInputChannels = max(1, deliveringChannels)
    openedDeviceChannels = openedInputChannels
    let pipeChannels = CaptureFormatPlan.rateChannels(
      inputChannels: openedInputChannels, mono: channelMode == .mono)
    guard pipeChannels > 0 else { return }
    armWriter(output: output, pipeChannels: pipeChannels)
  }

  func push(_ buffer: AVAudioPCMBuffer) {
    consume(buffer)
  }

  private func armWriter(output: FileHandle, pipeChannels: Int) {
    let descriptor = output.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 {
      _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }
    bytesOut.withLock { $0 = 0 }
    deliveryLock.lock()
    callbackCount = 0
    framesIn = 0
    framesOut = 0
    droppedCallbacks = 0
    rateNote = "rate conversion not used yet"
    deliveryLock.unlock()
    condition.lock()
    frameBytes = max(MemoryLayout<Float>.size, pipeChannels * MemoryLayout<Float>.size)
    readPos = 0
    writePos = 0
    stored = 0
    condition.unlock()
    conversionProblem = nil
    consecutiveConversionFailures = 0
    outputHandle = output
    outputFD = descriptor
    stopWriter = false
    let done = DispatchSemaphore(value: 0)
    writerDone = done
    writerRunning = true
    Thread.detachNewThread { [weak self] in
      self?.writerMain()
      done.signal()
    }
    callbackLock.lock()
    accepting = true
    callbackLock.unlock()
  }

  var openedFormatSummary: String { formatSummary }
  var openedNativeSummary: String { nativeSummary }
  var openedMixNote: String {
    if channelMode == .mono {
      let noun = openedInputChannels == 1 ? "channel" : "channels"
      return "mono sum of \(openedInputChannels) \(noun)"
    }
    return "stereo"
  }

  func stop() {
    callbackLock.lock()
    accepting = false
    running = false
    callbackLock.unlock()
    waitUntilIdle()
    session?.stop()
    session = nil
    stopWriter = true
    outputFD = -1
    condition.lock()
    condition.broadcast()
    condition.unlock()
    if writerRunning {
      _ = writerDone?.wait(timeout: .now() + 2)
      writerRunning = false
    }
    formatConverter = nil
    formatTarget = nil
    formatBuffer = nil
    rateConverter = nil
    rateTarget = nil
    rateBuffer = nil
    rateInputRate = 0
    if let handle = outputHandle {
      outputHandle = nil
      try? handle.close()
    }
    condition.lock()
    readPos = 0
    writePos = 0
    stored = 0
    condition.unlock()
  }

  private func consume(_ buffer: AVAudioPCMBuffer) {
    recordArrival(frames: Int(buffer.frameLength))
    guard beginCallback() else {
      recordDrop()
      return
    }
    defer { endCallback() }
    guard let samples = renderWhileAccepted(buffer) else {
      recordDrop()
      return
    }
    let outChannels = channelMode == .mono ? 1 : 2
    recordOutput(frames: samples.count / max(1, outChannels))
    emit(samples)
  }

  /// Copies every channel, sums or selects in our code, then resamples.
  /// The rate converter always has the same channel count on both sides.
  /// Converters stay alive until `stop` has seen `inFlight` drop to zero.
  private func renderWhileAccepted(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    callbackLock.lock()
    defer { callbackLock.unlock() }
    guard accepting else { return nil }
    let channels = Int(buffer.format.channelCount)
    guard channels > 0, let deviceFloats = floatSamples(from: buffer) else {
      noteConversionFailure()
      return nil
    }
    let mixed = CaptureMix.render(
      interleaved: deviceFloats,
      channelCount: channels,
      mode: channelMode,
      inputChannel: inputChannel
    )
    let mixedChannels = CaptureFormatPlan.rateChannels(
      inputChannels: channels, mono: channelMode == .mono)
    let frames = deviceFloats.count / channels
    guard mixedChannels > 0, frames > 0, mixed.count == frames * mixedChannels else {
      noteConversionFailure()
      return nil
    }
    guard
      let resampled = resample(mixed, channels: mixedChannels, sampleRate: buffer.format.sampleRate)
    else {
      noteConversionFailure()
      return nil
    }
    consecutiveConversionFailures = 0
    return resampled
  }

  /// Integer device audio becomes float at the same rate and the same
  /// channel count. The map is every channel, in order.
  private func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
    if buffer.format.commonFormat == .pcmFormatFloat32,
      let direct = CapturePCM.interleavedFloats(from: buffer)
    {
      return direct
    }
    let channels = Int(buffer.format.channelCount)
    let sampleRate = buffer.format.sampleRate
    guard channels > 0, sampleRate > 0 else { return nil }
    if formatConverter == nil || formatConverter?.inputFormat != buffer.format {
      guard
        let opened = openFormatConverter(
          from: buffer.format, channels: channels, sampleRate: sampleRate)
      else { return nil }
      formatConverter = opened.converter
      formatTarget = opened.target
      formatBuffer = nil
    }
    guard let formatConverter, let formatTarget else { return nil }
    let needed = buffer.frameLength
    let output: AVAudioPCMBuffer
    if let existing = formatBuffer, existing.format == formatTarget,
      needed <= existing.frameCapacity
    {
      output = existing
    } else if let larger = AVAudioPCMBuffer(pcmFormat: formatTarget, frameCapacity: max(needed, 32))
    {
      formatBuffer = larger
      output = larger
    } else {
      return nil
    }
    guard convert(formatConverter, input: buffer, output: output) else { return nil }
    return CapturePCM.interleavedFloats(from: output)
  }

  /// Any device rate, including 16 kHz and 24 kHz mono from a hands-free
  /// Bluetooth profile, is converted to 48 kHz. The hardware clock is not changed.
  private func resample(_ samples: [Float], channels: Int, sampleRate: Double) -> [Float]? {
    guard channels > 0, sampleRate > 0, !samples.isEmpty else { return nil }
    if abs(sampleRate - CaptureFormatPlan.encodeRate) < 1 {
      noteRate("rate conversion skipped at \(Int(sampleRate.rounded())) Hz")
      return samples
    }
    if rateConverter == nil || rateChannelCount != channels || abs(rateInputRate - sampleRate) > 1 {
      guard let opened = openRateConverter(channels: channels, sampleRate: sampleRate) else {
        return nil
      }
      rateConverter = opened.converter
      rateTarget = opened.target
      rateChannelCount = channels
      rateInputRate = sampleRate
      rateBuffer = nil
    }
    guard let rateConverter, let rateTarget,
      let input = interleavedBuffer(samples, channels: channels, sampleRate: sampleRate)
    else { return nil }
    let ratio = CaptureFormatPlan.encodeRate / sampleRate
    let needed = AVAudioFrameCount(ceil(Double(samples.count / channels) * ratio) + 32)
    let output: AVAudioPCMBuffer
    if let existing = rateBuffer, existing.format == rateTarget, needed <= existing.frameCapacity {
      output = existing
    } else if let larger = AVAudioPCMBuffer(pcmFormat: rateTarget, frameCapacity: needed) {
      rateBuffer = larger
      output = larger
    } else {
      return nil
    }
    guard convert(rateConverter, input: input, output: output) else { return nil }
    noteRate(
      "rate conversion \(Int(sampleRate.rounded())) Hz to \(Int(CaptureFormatPlan.encodeRate)) Hz"
    )
    return CapturePCM.interleavedFloats(from: output)
  }

  private func recordArrival(frames: Int) {
    deliveryLock.lock()
    callbackCount += 1
    framesIn += frames
    deliveryLock.unlock()
  }

  private func recordDrop() {
    deliveryLock.lock()
    droppedCallbacks += 1
    deliveryLock.unlock()
  }

  private func recordOutput(frames: Int) {
    deliveryLock.lock()
    framesOut += frames
    deliveryLock.unlock()
  }

  private func noteRate(_ note: String) {
    deliveryLock.lock()
    rateNote = note
    deliveryLock.unlock()
  }

  private func convert(
    _ converter: AVAudioConverter, input: AVAudioPCMBuffer, output: AVAudioPCMBuffer
  ) -> Bool {
    output.frameLength = 0
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return input
    }
    return error == nil && status != .error && output.frameLength > 0
  }

  private func interleavedBuffer(_ samples: [Float], channels: Int, sampleRate: Double)
    -> AVAudioPCMBuffer?
  {
    let frames = samples.count / channels
    guard frames > 0,
      let format = AudioInputBind.floatFormat(
        sampleRate: sampleRate, channels: channels, interleaved: true),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    let byteCount = samples.count * MemoryLayout<Float>.size
    guard let destination = buffer.audioBufferList.pointee.mBuffers.mData,
      Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize) >= byteCount
    else { return nil }
    samples.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      destination.copyMemory(from: base, byteCount: byteCount)
    }
    return buffer
  }

  private func settlingMessage(_ message: String, deviceName: String) -> String {
    guard CaptureFormatPlan.isInputSettling(message) else { return message }
    return CaptureFormatPlan.notReadyMessage(deviceName: deviceName)
  }

  private func noteConversionFailure() {
    consecutiveConversionFailures += 1
    guard consecutiveConversionFailures == 25, conversionProblem == nil else { return }
    conversionProblem = CaptureFormatPlan.conversionStoppedMessage(
      deviceName: openedDeviceName, summary: formatSummary)
  }

  private func openFormatConverter(
    from hardware: AVAudioFormat, channels: Int, sampleRate: Double
  ) -> (converter: AVAudioConverter, target: AVAudioFormat)? {
    guard channels > 0, sampleRate > 0 else { return nil }
    let map = CaptureFormatPlan.identityChannelMap(channelCount: channels)
    for interleaved in CaptureFormatPlan.interleavedChoices(channelCount: channels) {
      guard
        let target = AudioInputBind.floatFormat(
          sampleRate: sampleRate, channels: channels, interleaved: interleaved),
        let converter = AVAudioConverter(from: hardware, to: target)
      else { continue }
      converter.channelMap = map.map { NSNumber(value: $0) }
      return (converter, target)
    }
    return nil
  }

  private func openRateConverter(channels: Int, sampleRate: Double)
    -> (converter: AVAudioConverter, target: AVAudioFormat)?
  {
    guard channels > 0, channels <= 2, sampleRate > 0,
      let source = AudioInputBind.floatFormat(
        sampleRate: sampleRate, channels: channels, interleaved: true),
      let target = AudioInputBind.floatFormat(
        sampleRate: CaptureFormatPlan.encodeRate, channels: channels, interleaved: true),
      let converter = AVAudioConverter(from: source, to: target)
    else { return nil }
    converter.channelMap = CaptureFormatPlan.identityChannelMap(channelCount: channels).map {
      NSNumber(value: $0)
    }
    return (converter, target)
  }

  private func beginCallback() -> Bool {
    callbackLock.lock()
    defer { callbackLock.unlock() }
    guard accepting else { return false }
    inFlight += 1
    return true
  }

  private func endCallback() {
    callbackLock.lock()
    inFlight -= 1
    callbackLock.unlock()
  }

  private func waitUntilIdle() {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      callbackLock.lock()
      let busy = inFlight
      callbackLock.unlock()
      if busy == 0 { return }
      Thread.sleep(forTimeInterval: 0.001)
    }
  }

  private func emit(_ samples: [Float]) {
    let rendered = InputGain.apply(samples, gainDB: currentGain())
    guard !rendered.isEmpty else { return }
    let decibels = SignalLevel.decibels(rendered)
    level.withLock { state in
      state.decibels = decibels
      state.at = Date()
    }
    rendered.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      enqueue(base, count: raw.count)
    }
  }

  private func currentGain() -> Double {
    gainLock.lock()
    defer { gainLock.unlock() }
    return gainDB
  }

  private func enqueue(_ raw: UnsafeRawPointer, count: Int) {
    let frame = frameBytes
    guard frame > 0, count >= frame else { return }
    var length = count - (count % frame)
    var source = raw
    condition.lock()
    defer {
      condition.signal()
      condition.unlock()
    }
    if length > ring.count {
      let keep = (ring.count / frame) * frame
      source = raw.advanced(by: length - keep)
      length = keep
    }
    let free = ring.count - stored
    if length > free {
      var drop = length - free
      let remainder = drop % frame
      if remainder != 0 {
        drop += frame - remainder
      }
      drop = min(drop, (stored / frame) * frame)
      readPos = (readPos + drop) % ring.count
      stored -= drop
    }
    guard length <= ring.count - stored else { return }
    copyIntoRing(source, count: length)
  }

  private func copyIntoRing(_ source: UnsafeRawPointer, count: Int) {
    let tail = min(count, ring.count - writePos)
    ring.withUnsafeMutableBytes { destination in
      guard let base = destination.baseAddress else { return }
      base.advanced(by: writePos).copyMemory(from: source, byteCount: tail)
      if count > tail {
        base.copyMemory(from: source.advanced(by: tail), byteCount: count - tail)
      }
    }
    writePos = (writePos + count) % ring.count
    stored += count
  }

  private func dequeue(into destination: UnsafeMutableRawPointer, capacity: Int) -> Int {
    condition.lock()
    defer { condition.unlock() }
    let frame = frameBytes
    guard frame > 0 else { return 0 }
    let amount = min(stored, capacity) / frame * frame
    guard amount > 0 else { return 0 }
    let tail = min(amount, ring.count - readPos)
    ring.withUnsafeBytes { source in
      guard let base = source.baseAddress else { return }
      destination.copyMemory(from: base.advanced(by: readPos), byteCount: tail)
      if amount > tail {
        destination.advanced(by: tail).copyMemory(from: base, byteCount: amount - tail)
      }
    }
    readPos = (readPos + amount) % ring.count
    stored -= amount
    return amount
  }

  private struct CaptureLevel {
    var decibels: Double
    var at: Date
  }

  private func writerMain() {
    // ffmpeg closes stdin when it exits. A write to that pipe must return
    // EPIPE. The default SIGPIPE would quit the whole app.
    var blocked = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGPIPE)
    _ = pthread_sigmask(SIG_BLOCK, &blocked, nil)
    let scratch = UnsafeMutableRawPointer.allocate(
      byteCount: 8_192, alignment: MemoryLayout<Float>.alignment)
    defer { scratch.deallocate() }
    while !stopWriter {
      condition.lock()
      while stored < frameBytes && !stopWriter {
        condition.wait(until: Date().addingTimeInterval(0.05))
      }
      condition.unlock()
      if stopWriter { break }
      let count = dequeue(into: scratch, capacity: 8_192)
      if count == 0 { continue }
      if !writeAll(scratch, count: count) { break }
    }
  }

  /// Writes one chunk. A short write is retried so a sample is never split
  /// across a dropped tail. Returns false when the pipe is gone.
  private func writeAll(_ raw: UnsafeRawPointer, count: Int) -> Bool {
    var written = 0
    while written < count {
      if stopWriter || outputFD < 0 { return false }
      let descriptor = outputFD
      var polled = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      let ready = poll(&polled, 1, 50)
      if stopWriter || outputFD < 0 { return false }
      if ready == 0 { continue }
      if ready < 0 {
        if errno == EINTR { continue }
        return false
      }
      let result = Darwin.write(descriptor, raw.advanced(by: written), count - written)
      if result > 0 {
        written += result
        bytesOut.withLock { $0 += result }
        continue
      }
      if result < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      return false
    }
    return true
  }
}
