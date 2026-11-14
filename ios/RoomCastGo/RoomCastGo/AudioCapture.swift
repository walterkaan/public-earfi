import AVFoundation
import AudioToolbox
import Foundation
import os

/// Microphone to 20 ms Opus packets. The system picks the input: built-in mic,
/// wired headset, USB-C, or a Bluetooth headset in call mode.
final class AudioCapture {
    var onPacket: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// True while the incoming audio is hitting the ceiling (held ~1 s).
    var onClip: ((Bool) -> Void)?
    private var clipUntil = Date.distantPast
    private var clipShown = false
    var onInput: ((String) -> Void)?
    /// Hardware channel label, then the channel count the port reports.
    var onHardware: ((String, Int) -> Void)?
    var onInterrupted: ((Bool) -> Void)?
    var onUSB: ((Bool) -> Void)?
    var onProfile: ((String) -> Void)?
    var onCaptureFailure: ((String) -> Void)?

    static var routeIsUSB: Bool {
        let session = AVAudioSession.sharedInstance()
        func isUSB(_ port: AVAudioSessionPortDescription) -> Bool {
            port.portType == .usbAudio || port.portName.localizedCaseInsensitiveContains("usb")
        }
        if session.currentRoute.inputs.contains(where: isUSB) { return true }
        return session.availableInputs?.contains(where: isUSB) ?? false
    }

    private let log = Logger(subsystem: "channel.roomcast.go", category: "audio")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var encoder: OpusEncoderBox?
    private var pending: [Float] = []
    private var frame = [Float](repeating: 0, count: OpusEncoderBox.frameSamples * 2)
    private var channels = 1
    /// Channels handed to Opus. 2 when stereo widen is turning a mono music input into a stereo packet.
    private var encodeChannels = 1
    /// Main thread. Preference, including while USB is unplugged.
    private var musicPreferred = false
    /// Main thread. Music is on only for a USB input.
    private var musicActive = false
    /// Main thread. Applied only for mono music. Default on.
    private var stereoWiden = true
    private var widener = StereoWidener()
    private var wide = [Float](repeating: 0, count: OpusEncoderBox.frameSamples * 2)
    private var routeMonitor: NSObjectProtocol?
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
    private var levelerGain: Float = 1
    private var levelerWasOn = false
    /// Every session and engine mutation. Never the main thread.
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let audioQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "channel.roomcast.go.audio", qos: .userInitiated)
        queue.setSpecific(key: AudioCapture.queueKey, value: 1)
        return queue
    }()
    private var pendingRebuild: DispatchWorkItem?
    private var rebuilding = false
    private var rebuildAgain = false
    private var suppressRoute = false
    private var failedRebuilds = 0
    private var mismatchPosted = false
    private var rebuildForce = false
    private var clearInterruption = false

    /// Lists inputs and prefers a USB or other external port over the built-in mic.
    /// Safe to call before Start. Does not activate the microphone.
    /// Session changes run on `audioQueue`, not the main thread.
    func startMonitoringRoutes() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureCategory()
            self.applyPreferredInput()
            self.reportInput()
            guard self.routeMonitor == nil else { return }
            self.routeMonitor = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] note in
                self?.ingestRouteChange(note)
            }
        }
    }

    func refreshRoute() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureCategory()
            self.applyPreferredInput()
            self.reportInput()
        }
    }

    func setStereoWiden(_ on: Bool) {
        audioQueue.async { [weak self] in
            guard let self, self.stereoWiden != on else { return }
            self.stereoWiden = on
            guard self.running else { return }
            self.enqueueRebuild(force: true)
        }
    }

    /// Music is remembered, and applied only while the input is USB.
    /// A change while running rebuilds capture on the audio queue. The WebRTC sessions stay up.
    func setMusicPreferred(_ preferred: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.musicPreferred = preferred
            let active = preferred && Self.routeIsUSB
            let changed = active != self.musicActive
            self.musicActive = active
            if changed, self.running {
                self.enqueueRebuild(force: true)
            }
        }
    }

    /// Gain is applied before the encoder and the meter, so the bar follows
    /// what listeners hear, including Volume boost. Mute still measures that
    /// signal, then encodes silence so the WebRTC session stays up.
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
        try runOnAudioQueue {
            try self.startOnQueue()
        }
    }

    private func startOnQueue() throws {
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
            tearDownOnQueue()
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
        audioQueue.sync { [weak self] in
            guard let self else { return }
            guard self.running || self.encoder != nil else { return }
            self.tearDownOnQueue()
            self.log.info("capture stopped")
        }
    }

    private func tearDownOnQueue() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        rebuildAgain = false
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
        applyPreferredInput()
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

    private func installTap() throws {
        let input = engine.inputNode
        let session = AVAudioSession.sharedInstance()
        detachSilence()
        // Decide the profile now the session is active and the route is real.
        musicActive = musicPreferred && Self.routeIsUSB
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
            // iOS opens USB inputs as mono unless asked; ask for stereo when the device has it.
            if musicActive, session.maximumInputNumberOfChannels >= 2 {
                try? session.setPreferredInputNumberOfChannels(2)
            }
            engine.prepare()
        }

        // Hardware rate, read after the route has been applied. A cached 48 kHz
        // format crashes installTap when USB unplugs and the mic is 16 or 24 kHz.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw CaptureError(message: "The microphone has no audio format yet. Plug it in and tap Start again.")
        }
        let output = input.outputFormat(forBus: 0)
        let tapFormat: AVAudioFormat?
        let sourceFormat: AVAudioFormat
        if output.sampleRate == hardware.sampleRate, output.channelCount > 0 {
            tapFormat = nil
            sourceFormat = output
        } else {
            guard let requested = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardware.sampleRate,
                channels: hardware.channelCount,
                interleaved: false
            ), requested.sampleRate == hardware.sampleRate, requested.channelCount > 0 else {
                throw CaptureError(message: "The microphone has no audio format yet. Plug it in and tap Start again.")
            }
            tapFormat = requested
            sourceFormat = requested
        }
        let captureChannels: AVAudioChannelCount = (musicActive && sourceFormat.channelCount >= 2) ? 2 : 1
        channels = Int(captureChannels)
        let widen = musicActive && channels < 2 && stereoWiden
        encodeChannels = widen ? 2 : channels
        widener.reset()
        encoder = try OpusEncoderBox(music: musicActive, channels: encodeChannels)
        let kbps = musicActive ? (encodeChannels >= 2 ? 128 : 96) : 32
        let profile = Self.profileLabel(music: musicActive, kbps: kbps)
        DispatchQueue.main.async { [weak self] in self?.onProfile?(profile) }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: captureChannels,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw CaptureError(message: "Could not convert the input to 48 kHz.")
        }
        self.converter = converter
        self.targetFormat = target
        pending.removeAll(keepingCapacity: true)
        input.removeTap(onBus: 0)
        let bufferSize = sliceFrames(format: sourceFormat, session: session, unit: input.audioUnit)
        // nil uses the node's format when it already matches the hardware rate.
        // Otherwise the requested format's sample rate is the hardware rate, never a cached one.
        input.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
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
            noteFormatMismatch()
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

        var heardSum: Float = 0
        var hot = 0
        for index in 0..<sampleCount {
            let sample = frame[index]
            if abs(sample) >= 0.98 { hot += 1 }
            let driven = sample * gain
            let heard: Float
            if leveler {
                heard = softClip(sample * levelerGain)
            } else if music && gain > 1 {
                heard = softClip(driven)
            } else if !music && gain > 1 {
                heard = softClip(driven)
            } else {
                heard = min(1, max(-1, driven))
            }
            heardSum += heard * heard
            frame[index] = sendSilence ? 0 : heard
        }
        // Same 0...1 the background reads: −60 dBFS is 0, full scale is 1,
        // after Volume boost. Speech near the mic lands around 0.4–0.7.
        let rms = sqrt(heardSum / Float(max(sampleCount, 1)))
        let db = 20 * log10(max(rms, 1e-8))
        let level = min(1, max(0, (db + 60) / 60))
        let now = Date()
        if hot >= 3 || (!leveler && gain <= 1 && hot >= 1 && hot >= sampleCount / 200) {
            clipUntil = now.addingTimeInterval(1.0)
        }
        if now.timeIntervalSince(lastLevelAt) >= 0.04 {
            lastLevelAt = now
            let shown = level
            let clipping = now < clipUntil
            let clipChanged = clipping != clipShown
            if clipChanged { clipShown = clipping }
            // Stay off Swift tasks here. The audio thread posts to the main
            // queue; the model smooths there at this ~25 Hz rate.
            DispatchQueue.main.async { [weak self] in
                self?.onLevel?(shown)
                if clipChanged { self?.onClip?(clipping) }
            }
        }
        guard let encoder else { return }
        let packet: Data?
        if encodeChannels >= 2 && channels < 2 && !sendSilence {
            widener.expand(frame, count: sampleCount, into: &wide)
            packet = wide.withUnsafeBufferPointer { buffer -> Data? in
                guard let base = buffer.baseAddress else { return nil }
                return encoder.encode(base)
            }
        } else if encodeChannels >= 2 && sendSilence {
            for index in wide.indices { wide[index] = 0 }
            packet = wide.withUnsafeBufferPointer { buffer -> Data? in
                guard let base = buffer.baseAddress else { return nil }
                return encoder.encode(base)
            }
        } else {
            packet = frame.withUnsafeBufferPointer { buffer -> Data? in
                guard let base = buffer.baseAddress else { return nil }
                return encoder.encode(base)
            }
        }
        guard let packet else { return }
        onPacket?(packet)
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] note in
            self?.audioQueue.async { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] _ in
            self?.enqueueRebuild(force: true)
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueRebuild()
        })
    }

    /// Coalesce plug and unplug bursts, then rebuild off the main thread.
    /// `force` is a real route or interruption. A configuration ping can no-op
    /// when the hardware rate already matches the converter.
    private func enqueueRebuild(force: Bool = false) {
        let schedule = { [weak self] in
            guard let self, self.running else { return }
            if force { self.rebuildForce = true }
            if self.rebuilding {
                self.rebuildAgain = true
                return
            }
            self.pendingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.performRebuild()
            }
            self.pendingRebuild = work
            self.audioQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            schedule()
        } else {
            audioQueue.async(execute: schedule)
        }
    }

    private func noteFormatMismatch() {
        if mismatchPosted { return }
        mismatchPosted = true
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.mismatchPosted = false
            self.enqueueRebuild()
        }
    }

    private func graphMatchesInput() -> Bool {
        guard let converter else { return false }
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        return hardware.sampleRate > 0
            && hardware.channelCount > 0
            && hardware.sampleRate == converter.inputFormat.sampleRate
    }

    private func handleInterruption(_ note: Notification) {
        guard running else { return }
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log.info("audio interrupted")
            DispatchQueue.main.async { [weak self] in self?.onInterrupted?(true) }
        case .ended:
            let optionRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
            log.info("interruption ended, should resume \(options.contains(.shouldResume), privacy: .public)")
            clearInterruption = true
            enqueueRebuild(force: true)
        @unknown default:
            break
        }
    }

    private func ingestRouteChange(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        audioQueue.async { [weak self] in
            guard let self else { return }
            if self.suppressRoute { return }
            self.applyPreferredInput()
            self.reportInput()
            guard self.running else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override:
                self.log.info("route changed: \(String(describing: reason), privacy: .public)")
                self.musicActive = self.musicPreferred && Self.routeIsUSB
                self.enqueueRebuild(force: true)
            default:
                break
            }
        }
    }

    /// Stop, drop the tap, reset, then install against the hardware rate that exists now.
    private func performRebuild() {
        guard running else { return }
        if rebuilding {
            rebuildAgain = true
            return
        }
        let force = rebuildForce
        rebuildForce = false
        if !force, engine.isRunning, graphMatchesInput() {
            return
        }
        rebuilding = true
        suppressRoute = true
        defer {
            suppressRoute = false
            rebuilding = false
            if rebuildAgain {
                rebuildAgain = false
                enqueueRebuild()
            }
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        detachSilence()
        engine.reset()
        do {
            musicActive = musicPreferred && Self.routeIsUSB
            try configureSession()
            try installTap()
            try startEngine()
            failedRebuilds = 0
            reapplyBoost()
            reportInput()
            if clearInterruption {
                clearInterruption = false
                DispatchQueue.main.async { [weak self] in self?.onInterrupted?(false) }
            }
        } catch {
            failedRebuilds += 1
            log.error("route restart failed: \(error.localizedDescription, privacy: .public)")
            if failedRebuilds < 3 {
                enqueueRebuild(force: true)
                return
            }
            failedRebuilds = 0
            running = false
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in
                self?.onCaptureFailure?(message)
            }
        }
    }

    private func runOnAudioQueue(_ body: () throws -> Void) throws {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            try body()
        } else {
            try audioQueue.sync(execute: body)
        }
    }

    /// `kAUVoiceIOProperty_VoiceProcessingEnableAGC` is 2107. Turning it off
    /// leaves echo control on. Returns whether the property took.
    private func setHardwareAGC(_ enabled: Bool) -> Bool {
        // Disabled: on iPhone 15 / iOS 26 setting 2107 on the running voice-processing
        // unit silenced the mic entirely (no meter, no audio). Keep Apple's AGC on and
        // boost above 1x in software with the soft clipper instead.
        return false
    }

    private func setHardwareAGCUnused(_ enabled: Bool) -> Bool {
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

    private func ensureCategory() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
        }
    }

    /// USB and wired inputs win over the built-in mic. The choice is stored
    /// with `setPreferredInput` so the next session activation uses it.
    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        guard let best = Self.bestInput(session.availableInputs) else { return }
        if session.preferredInput?.uid != best.uid {
            try? session.setPreferredInput(best)
        }
    }

    private func reportInput() {
        let session = AVAudioSession.sharedInstance()
        let preferred = Self.bestInput(session.availableInputs)
        let current = session.currentRoute.inputs.first
        let port: AVAudioSessionPortDescription?
        if let preferred, Self.isExternal(preferred) {
            port = preferred
        } else {
            port = current ?? preferred
        }
        let name = port?.portName ?? "Internal Microphone"
        let count = Self.hardwareChannels(port: port, session: session)
        let label = Self.channelLabel(channels: count, port: port)
        log.info("input \(name, privacy: .public)")
        onInput?(name)
        onHardware?(label, count)
        onUSB?(Self.routeIsUSB)
    }

    private static func bestInput(_ inputs: [AVAudioSessionPortDescription]?) -> AVAudioSessionPortDescription? {
        inputs?.min { rank($0) < rank($1) }
    }

    private static func rank(_ port: AVAudioSessionPortDescription) -> Int {
        switch port.portType {
        case .usbAudio:
            return 0
        case .lineIn:
            return 1
        case .headsetMic:
            return 2
        case .builtInMic:
            return 50
        default:
            if port.portName.localizedCaseInsensitiveContains("usb") { return 0 }
            return 10
        }
    }

    private static func isExternal(_ port: AVAudioSessionPortDescription?) -> Bool {
        guard let port else { return false }
        return port.portType != .builtInMic
    }

    /// Built-in ports list several mic positions. Those are not a stereo pair.
    /// A USB or line input's channel list is the hardware width.
    private static func hardwareChannels(port: AVAudioSessionPortDescription?, session: AVAudioSession) -> Int {
        if port?.portType == .builtInMic { return 1 }
        if let listed = port?.channels?.count, listed > 0 { return listed }
        if session.maximumInputNumberOfChannels > 0 { return session.maximumInputNumberOfChannels }
        return 1
    }

    private static func channelLabel(channels: Int, port: AVAudioSessionPortDescription?) -> String {
        let kind = (port == nil || port?.portType == .builtInMic) ? "iPhone mic" : "sound card"
        return channels >= 2 ? "Stereo (\(kind))" : "Mono (\(kind))"
    }

    private static func profileLabel(music: Bool, kbps: Int) -> String {
        if music && kbps == 96 { return "96kbps Music quality" }
        if music { return "\(kbps)kbps Music quality" }
        return "\(kbps) kbps"
    }
}

/// Mono-compatible widener. The mid is the dry sample, undelayed. A high-passed
/// copy is delayed ~12 ms and added to the left and subtracted from the right,
/// so (left + right) / 2 is the original with no comb filter. The delay is only
/// on that side signal, so the packet clock stays on the existing 20 ms frame.
private struct StereoWidener {
    static let delaySamples = 12 * 48
    private var line = [Float](repeating: 0, count: delaySamples)
    private var cursor = 0
    private var previous: Float = 0
    private var highpass: Float = 0
    /// One-pole highpass near 200 Hz at 48 kHz. Bass stays in the center.
    private let pole: Float = 0.974

    mutating func reset() {
        line = [Float](repeating: 0, count: Self.delaySamples)
        cursor = 0
        previous = 0
        highpass = 0
    }

    mutating func expand(_ mono: [Float], count: Int, into stereo: inout [Float]) {
        let mid: Float = 0.85
        let sideGain: Float = 0.4
        let n = min(count, mono.count)
        if stereo.count < n * 2 { return }
        for index in 0..<n {
            let sample = mono[index]
            let filtered = pole * (highpass + sample - previous)
            previous = sample
            highpass = filtered
            let delayed = line[cursor]
            line[cursor] = filtered
            cursor += 1
            if cursor == Self.delaySamples { cursor = 0 }
            let side = delayed * sideGain
            stereo[index * 2] = mid * sample + side
            stereo[index * 2 + 1] = mid * sample - side
        }
    }
}

struct CaptureError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
