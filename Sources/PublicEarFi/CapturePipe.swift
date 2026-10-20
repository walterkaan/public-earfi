import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import PublicEarFiCore

/// Captures one Core Audio device and writes 48 kHz little-endian float PCM
/// to ffmpeg's stdin. The device is the HAL device chosen in Settings (by
/// UID), not an entry in ffmpeg's avfoundation list.
///
/// AVFoundation capture inside ffmpeg stamps audio with the host clock in
/// uneven bursts. WebRTC then inserts or drops a frame on a regular period,
/// which is the click, even when the same device is clean in other apps.
/// ffmpeg's f32le demuxer timestamps from the sample count, so this pipe
/// stays on a continuous 20 ms grid.
final class CapturePipe {
  private let engine = AVAudioEngine()
  private let condition = NSCondition()
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private var convertedBuffer: AVAudioPCMBuffer?
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
  private var captureChannels = 1
  private var downmixToMono = false
  private let gainLock = NSLock()
  private var gainDB = InputGain.defaultDB
  private let callbackLock = NSLock()
  private var accepting = false
  private var inFlight = 0
  private var tapInstalled = false

  func setGainDB(_ db: Double) {
    gainLock.lock()
    gainDB = InputGain.clamped(db)
    gainLock.unlock()
  }

  /// Starts capture. Returns an error string the UI can show.
  func start(
    deviceID: AudioDeviceID,
    channelMode: ChannelMode,
    inputChannel: Int,
    output: FileHandle
  ) -> String? {
    stop()
    guard AudioDeviceList.isAlive(deviceID) else {
      return "The selected audio device is not connected."
    }
    let input = engine.inputNode
    guard let audioUnit = input.audioUnit else {
      return "The audio engine has no input."
    }
    var identifier = deviceID
    let setStatus = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &identifier,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard setStatus == noErr else {
      return "Could not open the selected audio device."
    }
    let hardware = input.outputFormat(forBus: 0)
    guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
      return "The audio device has no input stream."
    }
    let inputCount = Int(hardware.channelCount)
    let mono = channelMode == .mono
    let map = CaptureChannelMap.indices(
      mode: channelMode,
      inputChannel: inputChannel,
      inputCount: inputCount
    )
    guard !map.isEmpty, map.allSatisfy({ $0 >= 0 && $0 < inputCount }) else {
      return "Could not map the selected input channel."
    }
    let convertCount = mono ? inputCount : map.count
    let channels = AVAudioChannelCount(convertCount)
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(FFmpegCommand.sampleRate),
        channels: channels,
        interleaved: true
      )
    else {
      return "Could not build the 48 kHz capture format."
    }
    guard let converter = AVAudioConverter(from: hardware, to: target) else {
      return "Could not convert the device audio to 48 kHz."
    }
    converter.channelMap = map.map { NSNumber(value: $0) }
    downmixToMono = mono
    captureChannels = convertCount
    let ratio = Double(FFmpegCommand.sampleRate) / hardware.sampleRate
    let capacity = AVAudioFrameCount(ceil(8_192 * ratio) + 32)
    guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
      return "Could not build the 48 kHz capture format."
    }
    let descriptor = output.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 {
      _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }
    condition.lock()
    let pipeChannels = mono ? 1 : map.count
    frameBytes = max(MemoryLayout<Float>.size, pipeChannels * MemoryLayout<Float>.size)
    readPos = 0
    writePos = 0
    stored = 0
    condition.unlock()
    self.converter = converter
    self.targetFormat = target
    self.convertedBuffer = converted
    self.outputHandle = output
    self.outputFD = descriptor
    stopWriter = false
    let done = DispatchSemaphore(value: 0)
    writerDone = done
    writerRunning = true
    Thread.detachNewThread { [weak self] in
      self?.writerMain()
      done.signal()
    }

    input.installTap(onBus: 0, bufferSize: 960, format: hardware) { [weak self] buffer, _ in
      self?.consume(buffer)
    }
    tapInstalled = true
    do {
      engine.prepare()
      try engine.start()
      callbackLock.lock()
      accepting = true
      running = true
      callbackLock.unlock()
      return nil
    } catch {
      stop()
      return "Could not start audio capture. Allow the microphone, and check the selected device."
    }
  }

  func stop() {
    callbackLock.lock()
    accepting = false
    let hadTap = tapInstalled
    let wasRunning = running
    tapInstalled = false
    running = false
    callbackLock.unlock()
    waitUntilIdle()
    stopWriter = true
    outputFD = -1
    condition.lock()
    condition.broadcast()
    condition.unlock()
    if hadTap {
      engine.inputNode.removeTap(onBus: 0)
    }
    if wasRunning {
      engine.stop()
    }
    if writerRunning {
      _ = writerDone?.wait(timeout: .now() + 2)
      writerRunning = false
    }
    converter = nil
    targetFormat = nil
    convertedBuffer = nil
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
    guard beginCallback() else { return }
    defer { endCallback() }
    guard let samples = renderWhileAccepted(buffer) else { return }
    emit(samples)
  }

  /// Converter and the converted buffer stay alive until `stop` has seen
  /// `inFlight` drop to zero. The copy is bounded by the buffer's own size.
  private func renderWhileAccepted(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    callbackLock.lock()
    defer { callbackLock.unlock() }
    guard accepting, let converter, let targetFormat else { return nil }
    let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
    let needed = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
    let output: AVAudioPCMBuffer
    if let converted = convertedBuffer, needed <= converted.frameCapacity {
      output = converted
    } else if let larger = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: needed) {
      convertedBuffer = larger
      output = larger
    } else {
      return nil
    }
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
      return buffer
    }
    guard error == nil, status != .error, output.frameLength > 0 else { return nil }
    return CapturePCM.interleavedFloats(from: output)
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
    let rendered = InputGain.render(
      interleaved: samples,
      channelCount: captureChannels,
      downmixToMono: downmixToMono,
      gainDB: currentGain()
    )
    guard !rendered.isEmpty else { return }
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

  private func writerMain() {
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
        continue
      }
      if result < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      return false
    }
    return true
  }
}
