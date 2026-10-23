import AVFoundation
import Foundation
import os

/// Microphone to 20 ms Opus packets. The system picks the input: built-in mic,
/// wired headset, USB-C, or a Bluetooth headset in call mode.
final class AudioCapture {
    var onPacket: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onInput: ((String) -> Void)?
    var onInterrupted: ((Bool) -> Void)?

    private let log = Logger(subsystem: "channel.roomcast.go", category: "audio")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var encoder: OpusEncoderBox?
    private var pending: [Float] = []
    private var frame = [Float](repeating: 0, count: OpusEncoderBox.frameSamples)
    private var smoothed: Float = 0
    private var lastLevelAt = Date.distantPast
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private let mixLock = NSLock()
    private var gain: Float = 1
    private var sendSilence = false

    /// Gain is applied before the meter and the encoder. Mute still measures
    /// the mic, then encodes silence so the WebRTC session stays up.
    func setMix(gain: Float, muted: Bool) {
        mixLock.lock()
        self.gain = gain
        self.sendSilence = muted
        mixLock.unlock()
    }

    func start() throws {
        if running { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            encoder = try OpusEncoderBox()
            try installTap()
            engine.prepare()
            try engine.start()
            running = true
            observeSession()
            reportInput()
            log.info("capture started")
        } catch {
            teardown()
            throw error
        }
    }

    func stop() {
        guard running || encoder != nil else { return }
        teardown()
        log.info("capture stopped")
    }

    private func teardown() {
        running = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        converter = nil
        targetFormat = nil
        encoder = nil
        pending.removeAll(keepingCapacity: true)
        smoothed = 0
    }

    private func installTap() throws {
        let input = engine.inputNode
        let builtIn = AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            $0.portType == .builtInMic
        }
        // Voice processing helps the built-in mic and fights a headset or a desk mic.
        try? input.setVoiceProcessingEnabled(builtIn)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError(message: "The microphone has no audio format yet. Plug it in and tap Start again.")
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: target) else {
            throw CaptureError(message: "Could not convert the microphone to 48 kHz mono.")
        }
        self.converter = converter
        self.targetFormat = target
        pending.removeAll(keepingCapacity: true)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard running, let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else {
            return
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.floatChannelData else { return }
        let count = Int(converted.frameLength)
        guard count > 0 else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
        if pending.count > 48_000 {
            pending.removeFirst(pending.count - 48_000)
        }
        let frameCount = OpusEncoderBox.frameSamples
        while pending.count >= frameCount {
            for index in 0..<frameCount {
                frame[index] = pending[index]
            }
            pending.removeFirst(frameCount)
            publishFrame()
        }
    }

    private func publishFrame() {
        mixLock.lock()
        let gain = self.gain
        let sendSilence = self.sendSilence
        mixLock.unlock()

        var sum: Float = 0
        for index in frame.indices {
            let heard = min(1, max(-1, frame[index] * gain))
            sum += heard * heard
            frame[index] = sendSilence ? 0 : heard
        }
        let rms = sqrt(sum / Float(frame.count))
        let db = 20 * log10(max(rms, 1e-8))
        let level = min(1, max(0, (db + 50) / 50))
        smoothed = smoothed * 0.65 + level * 0.35
        let now = Date()
        if now.timeIntervalSince(lastLevelAt) > 0.08 {
            lastLevelAt = now
            let shown = smoothed
            onLevel?(shown)
        }
        guard let encoder, let packet = frame.withUnsafeBufferPointer({ buffer -> Data? in
            guard let base = buffer.baseAddress else { return nil }
            return encoder.encode(base)
        }) else { return }
        onPacket?(packet)
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.rebuildEngine()
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard running else { return }
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log.info("audio interrupted")
            onInterrupted?(true)
        case .ended:
            let optionRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
            log.info("interruption ended, should resume \(options.contains(.shouldResume), privacy: .public)")
            resumeAfterInterruption()
        @unknown default:
            break
        }
    }

    private func resumeAfterInterruption() {
        guard running else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try installTap()
                try engine.start()
            }
            reportInput()
            onInterrupted?(false)
        } catch {
            log.error("resume failed: \(error.localizedDescription, privacy: .public)")
            onInterrupted?(true)
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard running else { return }
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override:
            log.info("route changed: \(String(describing: reason), privacy: .public)")
            rebuildEngine()
        default:
            reportInput()
        }
    }

    private func rebuildEngine() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try installTap()
            try engine.start()
            reportInput()
        } catch {
            log.error("route restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reportInput() {
        let names = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName)
        let name = names.isEmpty ? "iPhone microphone" : names.joined(separator: ", ")
        log.info("input \(name, privacy: .public)")
        onInput?(name)
    }
}

struct CaptureError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
