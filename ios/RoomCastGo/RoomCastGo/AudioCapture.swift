import AVFoundation
import AudioToolbox
import Foundation
import os

/// Microphone to 20 ms Opus packets. The system picks the input: built-in mic,
/// wired headset, USB-C, or a Bluetooth headset in call mode.
final class AudioCapture {
    var onPacket: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onInput: ((String) -> Void)?
    var onInterrupted: ((Bool) -> Void)?
    var onUSB: ((Bool) -> Void)?
    var onCaptureFailure: ((String) -> Void)?

    static var routeIsUSB: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .usbAudio }
    }

    private let log = Logger(subsystem: "channel.roomcast.go", category: "audio")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var encoder: OpusEncoderBox?
    private var pending: [Float] = []
    private var frame = [Float](repeating: 0, count: OpusEncoderBox.frameSamples * 2)
    private var channels = 1
    /// Main thread. Preference, including while USB is unplugged.
    private var musicPreferred = false
    /// Main thread. Music is on only for a USB input.
    private var musicActive = false
    private var applying = false
    private var smoothed: Float = 0
    private var lastLevelAt = Date.distantPast
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private let mixLock = NSLock()
    private var gain: Float = 1
    private var sendSilence = false
    private var useLeveler = false
    private var musicMix = false
    /// Main thread only. True after voice-processing AGC was turned off.
    private var hardwareLeveler = false
    /// Main thread only. Voice processing is on for the built-in mic.
    private var voiceProcessing = false
    /// Silence for the voice-processing output bus. Nil unless that bus is on.
    private var silenceNode: AVAudioSourceNode?
    /// Main thread. Coalesces a graph rebuild after a format change.
    private var rebuildQueued = false
    /// Audio thread only. Smoothed makeup while AGC is off.
    private var levelerGain: Float = 1
    private var levelerWasOn = false

    /// Music is remembered, and applied only while the input is USB.
    /// A change while running restarts capture. The WebRTC sessions stay up.
    func setMusicPreferred(_ preferred: Bool) {
        musicPreferred = preferred
        let active = preferred && Self.routeIsUSB
        let changed = active != musicActive
        musicActive = active
        if changed, running {
            restartRunning()
        }
    }

    /// Gain is applied before the meter and the encoder. Mute still measures
    /// the mic, then encodes silence so the WebRTC session stays up.
    ///
    /// At 1× and below, the built-in mic keeps Apple's voice-processing AGC
    /// (the sensitive, clean sound). Above 1× that AGC is switched off,
    /// because it already holds speech near full scale and a later multiply
    /// only hard-clips. A leveler then aims louder as the slider rises.
    /// Music has no AGC: the slider is 0× to 2×, and above 1× the samples
    /// are soft-clipped. Call this on the main thread.
    func setMix(gain: Float, muted: Bool) {
        let clamped: Float = musicActive ? min(2, max(0, gain)) : min(3, max(0.5, gain))
        let wantLeveler = !musicActive && voiceProcessing && clamped > 1.001
        if wantLeveler != hardwareLeveler {
            if wantLeveler {
                hardwareLeveler = setHardwareAGC(false)
            } else {
                _ = setHardwareAGC(true)
                hardwareLeveler = false
            }
        }
        mixLock.lock()
        self.gain = clamped
        self.sendSilence = muted
        self.useLeveler = hardwareLeveler && wantLeveler
        self.musicMix = musicActive
        mixLock.unlock()
    }

    func start() throws {
        if running { return }
        do {
            // Voice keeps `.default` plus voice processing on the built-in mic.
            // Music uses `.measurement` so USB audio is not gained or denoised.
            // The session is active before the audio unit starts.
            try configureSession()
            observeSession()
            try installTap()
            try startEngine()
            reapplyBoost()
            running = true
            reportInput()
            log.info("capture started")
        } catch {
            teardown()
            throw error
        }
    }

    /// One retry covers the voice-processing unit stopping itself when its
    /// format changes during the first start. Give up if it still will not run.
    private func startEngine() throws {
        do {
            try engine.start()
            if engine.isRunning { return }
        } catch {
            try installTap()
            try engine.start()
            if engine.isRunning { return }
            throw error
        }
        try installTap()
        try engine.start()
        if !engine.isRunning {
            throw CaptureError(message: "The microphone did not start. Tap Start again.")
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
        detachSilence()
        voiceProcessing = false
        hardwareLeveler = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        converter = nil
        targetFormat = nil
        encoder = nil
        pending.removeAll(keepingCapacity: true)
        smoothed = 0
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: musicActive ? .measurement : .default,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        if session.sampleRate == 0 {
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
        }
        guard session.sampleRate > 0 else {
            throw CaptureError(message: "The microphone has no audio format yet. Plug it in and tap Start again.")
        }
        if !musicActive, session.isInputGainSettable {
            try? session.setInputGain(1)
        }
    }

    private func restartRunning() {
        guard running, !applying else { return }
        applying = true
        defer { applying = false }
        teardown()
        do {
            try start()
        } catch {
            log.error("capture restart failed: \(error.localizedDescription, privacy: .public)")
            onCaptureFailure?(error.localizedDescription)
        }
    }

    private func installTap() throws {
        let input = engine.inputNode
        let session = AVAudioSession.sharedInstance()
        detachSilence()
        let builtIn = !musicActive && session.currentRoute.inputs.contains { $0.portType == .builtInMic }
        // Voice processing helps the built-in mic and fights a headset or a desk mic.
        // USB and Music leave the voice-processing unit off, which is the path
        // that does not log `auou/vpio/appl, render err: -1`.
        if builtIn {
            try installVoiceGraph(on: input)
        } else {
            try? input.setVoiceProcessingEnabled(false)
            try? engine.outputNode.setVoiceProcessingEnabled(false)
            voiceProcessing = false
            hardwareLeveler = false
            engine.prepare()
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError(message: "The microphone has no audio format yet. Plug it in and tap Start again.")
        }
        let captureChannels: AVAudioChannelCount = (musicActive && format.channelCount >= 2) ? 2 : 1
        channels = Int(captureChannels)
        encoder = try OpusEncoderBox(music: musicActive, channels: channels)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: captureChannels,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: target) else {
            throw CaptureError(message: "Could not convert the input to 48 kHz.")
        }
        self.converter = converter
        self.targetFormat = target
        pending.removeAll(keepingCapacity: true)
        input.removeTap(onBus: 0)
        let bufferSize = sliceFrames(format: format, session: session, unit: input.audioUnit)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        if voiceProcessing {
            engine.mainMixerNode.outputVolume = 0
        }
    }

    /// The built-in mic's voice-processing unit renders an output bus for the
    /// echo canceller. With no render callback that bus returns -1
    /// (`auou/vpio/appl, render err: -1`) and the capture drops out until the
    /// format settles. A silence source returns `noErr` at the format read
    /// after the session is active. The mixer stays at zero so the reference
    /// is silence and the speaker stays quiet.
    private func installVoiceGraph(on input: AVAudioInputNode) throws {
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            voiceProcessing = false
            hardwareLeveler = false
            log.error("voice processing stayed off: \(error.localizedDescription, privacy: .public)")
            engine.prepare()
            return
        }
        try? engine.outputNode.setVoiceProcessingEnabled(true)
        voiceProcessing = true
        engine.prepare()
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            voiceProcessing = false
            hardwareLeveler = false
            try? input.setVoiceProcessingEnabled(false)
            try? engine.outputNode.setVoiceProcessingEnabled(false)
            throw CaptureError(message: "The microphone has no audio format yet. Plug it in and tap Start again.")
        }
        connectSilence(format: outputFormat)
        engine.prepare()
    }

    private func connectSilence(format: AVAudioFormat) {
        detachSilence()
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                var bytes = Int(buffer.mDataByteSize)
                if bytes == 0 {
                    let channels = Int(max(buffer.mNumberChannels, 1))
                    bytes = Int(frameCount) * channels * MemoryLayout<Float>.size
                }
                if bytes > 0 {
                    memset(data, 0, bytes)
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        silenceNode = source
    }

    private func detachSilence() {
        if let silenceNode {
            engine.disconnectNodeOutput(silenceNode)
            if engine.attachedNodes.contains(silenceNode) {
                engine.detach(silenceNode)
            }
            self.silenceNode = nil
        }
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.mainMixerNode.outputVolume = 1
    }

    /// Tap length follows this slice: the hardware IO size, and never more
    /// than the unit's maximum frames per slice. The callback reads
    /// `buffer.frameLength`, which is the count the unit actually rendered.
    private func sliceFrames(format: AVAudioFormat, session: AVAudioSession, unit: AudioUnit?) -> AVAudioFrameCount {
        let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
        let duration = session.ioBufferDuration > 0 ? session.ioBufferDuration : 0.02
        var frames = AVAudioFrameCount((rate * duration).rounded())
        if frames < 256 { frames = 256 }
        guard let unit else { return frames }
        var maxFrames: UInt32 = 0
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            &propSize
        )
        if status == noErr, maxFrames >= 256 {
            frames = min(frames, AVAudioFrameCount(maxFrames))
        }
        return frames
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard running, let converter, let targetFormat else { return }
        if abs(buffer.format.sampleRate - converter.inputFormat.sampleRate) > 1
            || buffer.format.channelCount != converter.inputFormat.channelCount {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleRebuild()
            }
            return
        }
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
        let frameCount = OpusEncoderBox.frameSamples
        if channels >= 2, converted.format.channelCount >= 2 {
            let right = channel[1]
            for index in 0..<count {
                pending.append(channel[0][index])
                pending.append(right[index])
            }
            if pending.count > 96_000 {
                pending.removeFirst(pending.count - 96_000)
            }
            let pair = frameCount * 2
            while pending.count >= pair {
                for index in 0..<pair {
                    frame[index] = pending[index]
                }
                pending.removeFirst(pair)
                publish(sampleCount: pair)
            }
        } else {
            pending.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
            if pending.count > 48_000 {
                pending.removeFirst(pending.count - 48_000)
            }
            while pending.count >= frameCount {
                for index in 0..<frameCount {
                    frame[index] = pending[index]
                }
                pending.removeFirst(frameCount)
                publish(sampleCount: frameCount)
            }
        }
    }

    private func publish(sampleCount: Int) {
        mixLock.lock()
        let gain = self.gain
        let sendSilence = self.sendSilence
        let leveler = self.useLeveler && sampleCount == OpusEncoderBox.frameSamples
        let music = self.musicMix
        mixLock.unlock()

        if leveler {
            var energy: Float = 0
            for index in 0..<sampleCount {
                let sample = frame[index]
                energy += sample * sample
            }
            let rms = sqrt(energy / Float(sampleCount))
            // 1.5× aims a little hotter than a normal voice-processed
            // level. 3× aims clearly louder. The cap stops a quiet room
            // from being amplified without limit.
            let target = min(0.34, 0.11 * gain)
            let wanted = min(28, target / max(rms, 0.004))
            if levelerWasOn {
                levelerGain += (wanted - levelerGain) * 0.35
            } else {
                levelerGain = wanted
            }
            levelerWasOn = true
        } else {
            levelerWasOn = false
            levelerGain = 1
        }

        var sum: Float = 0
        for index in 0..<sampleCount {
            let driven = frame[index] * gain
            let heard: Float
            if leveler {
                heard = softClip(frame[index] * levelerGain)
            } else if music && gain > 1 {
                heard = softClip(driven)
            } else if !music && gain > 1 {
                heard = softClip(driven)
            } else {
                heard = min(1, max(-1, driven))
            }
            sum += heard * heard
            frame[index] = sendSilence ? 0 : heard
        }
        let rms = sqrt(sum / Float(sampleCount))
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
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRebuild()
        })
    }

    /// The engine stops itself when the built-in route changes sample rate
    /// (48 kHz requested, 24 kHz or 16 kHz hardware). Rebuild on the next
    /// turn so this is not inside `engine.start`.
    private func scheduleRebuild() {
        guard running, !applying, !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildQueued = false
            guard self.running, !self.applying else { return }
            if self.engine.isRunning, self.graphMatchesInput() { return }
            self.rebuildEngine()
        }
    }

    private func graphMatchesInput() -> Bool {
        guard let converter else { return false }
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0
            && format.sampleRate == converter.inputFormat.sampleRate
            && format.channelCount == converter.inputFormat.channelCount
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
                try startEngine()
                reapplyBoost()
            }
            reportInput()
            onInterrupted?(false)
        } catch {
            log.error("resume failed: \(error.localizedDescription, privacy: .public)")
            onInterrupted?(true)
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard running, !applying else { return }
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override:
            log.info("route changed: \(String(describing: reason), privacy: .public)")
            let active = musicPreferred && Self.routeIsUSB
            let profileChanged = active != musicActive
            musicActive = active
            onUSB?(Self.routeIsUSB)
            if profileChanged {
                restartRunning()
            } else {
                rebuildEngine()
            }
        default:
            reportInput()
        }
    }

    private func rebuildEngine() {
        guard running, !applying else { return }
        applying = true
        defer { applying = false }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        detachSilence()
        do {
            try configureSession()
            try installTap()
            try startEngine()
            reapplyBoost()
            reportInput()
        } catch {
            log.error("route restart failed: \(error.localizedDescription, privacy: .public)")
            onCaptureFailure?(error.localizedDescription)
        }
    }

    /// `kAUVoiceIOProperty_VoiceProcessingEnableAGC` is 2107. Turning it off
    /// leaves echo control on. Returns whether the property took.
    private func setHardwareAGC(_ enabled: Bool) -> Bool {
        guard voiceProcessing, let unit = engine.inputNode.audioUnit else { return false }
        var value: UInt32 = enabled ? 1 : 0
        let status = AudioUnitSetProperty(
            unit,
            AudioUnitPropertyID(2107),
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if status != noErr {
            log.error("could not set voice-processing AGC (\(status))")
            return false
        }
        return true
    }

    private func reapplyBoost() {
        mixLock.lock()
        let gain = self.gain
        let muted = self.sendSilence
        mixLock.unlock()
        hardwareLeveler = false
        setMix(gain: gain, muted: muted)
    }

    private func softClip(_ sample: Float) -> Float {
        let drive: Float = 1.2
        return tanhf(sample * drive) / tanhf(drive)
    }

    private func reportInput() {
        let names = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName)
        let name = names.isEmpty ? "iPhone microphone" : names.joined(separator: ", ")
        log.info("input \(name, privacy: .public)")
        onInput?(name)
        onUSB?(Self.routeIsUSB)
    }
}

struct CaptureError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
