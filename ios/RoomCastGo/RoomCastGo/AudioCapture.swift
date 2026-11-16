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
    var onInputGain: ((Bool) -> Void)?
    var onProfile: ((String) -> Void)?
    var onCaptureFailure: ((String) -> Void)?

    static var routeIsUSB: Bool {
        let session = AVAudioSession.sharedInstance()
        if let port = session.currentRoute.inputs.first, isLine(port) { return true }
        return session.availableInputs?.contains(where: isLine) ?? false
    }

    /// Line-level USB and RCA cards, not the built-in mic. These must not
    /// run through voice processing or a full-scale input gain.
    static func isLine(_ port: AVAudioSessionPortDescription) -> Bool {
        if port.portType == .usbAudio || port.portType == .lineIn { return true }
        let name = port.portName.lowercased()
        return name.contains("usb") || name.contains("rca") || name.contains("line in") || name.contains("line-in")
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
    /// Line trim applied before Volume boost when the hardware gain isn't settable.
    private var inputTrim: Float = 0.5
    private var hardwareGainSettable = false
    private var clipHotSince: Date?
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
    private var pullScratch: AVAudioPCMBuffer?
    private var convertOut: AVAudioPCMBuffer?
    private let paceQueue = DispatchQueue(label: "channel.roomcast.go.pace")
    private let paceLock = NSLock()
    private var outbound: [Data] = []
    private var sendScheduled = false
    private var paceStopped = false
    private var framesIn = 0
    private var framesOut = 0
    private var framesQueued = 0
    private var framesDiscarded = 0
    private var packetsSent = 0
    private var packetsDropped = 0
    private var lastReport = Date.distantPast

    /// Lists inputs and prefers a USB or other external port over the built-in mic.
    /// Safe to call before Start. Does not start the audio engine.
    /// When microphone permission is already granted, the session is activated
    /// so `currentRoute` and `availableInputs` include a USB interface that was
    /// plugged in before launch. Session changes run on `audioQueue`.
    func startMonitoringRoutes() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.prepareRouteForReading()
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
            if !self.running {
                self.prepareRouteForReading()
            }
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

    /// Line level, 0...1. When the route can set `inputGain`, that is used.
    /// Otherwise the value attenuates the samples before Volume boost.
    func setInputLevel(_ value: Float) {
        let trimmed = min(1, max(0, value))
        audioQueue.async { [weak self] in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            let settable = session.isInputGainSettable && Self.routeIsUSB
            self.mixLock.lock()
            self.inputTrim = trimmed
            self.hardwareGainSettable = settable
            self.mixLock.unlock()
            if settable {
                try? session.setInputGain(trimmed)
            }
            DispatchQueue.main.async { [weak self] in self?.onInputGain?(settable) }
        }
    }

    /// Volume boost and mute. Line inputs are not levelled: unity is 0 dB.
    /// Call from the main thread; the values are read on the tap thread.
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
            paceLock.lock()
            paceStopped = false
            paceLock.unlock()
            reportInput()
            #if DEBUG
            log.info("capture started")
            #endif
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
            #if DEBUG
            self.log.info("capture stopped")
            #endif
        }
    }

    private func tearDownOnQueue() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        rebuildAgain = false
        running = false
        paceLock.lock()
        outbound.removeAll()
        sendScheduled = false
        paceStopped = true
        paceLock.unlock()
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
        let line = Self.routeIsUSB
        musicActive = musicPreferred && line
        // Line cards clip if the voice processor or AGC is left on. Measurement
        // mode leaves the samples alone. The built-in mic keeps .default.
        try session.setCategory(
            .playAndRecord,
            mode: line ? .measurement : .default,
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
        let settable = session.isInputGainSettable
        mixLock.lock()
        hardwareGainSettable = settable && line
        let trim = inputTrim
        mixLock.unlock()
        if line, settable {
            try? session.setInputGain(trim)
        }
        DispatchQueue.main.async { [weak self] in self?.onInputGain?(settable && line) }
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
            if musicActive, session.maximumInputNumberOfChannels >= 2 {
                try? session.setPreferredInputNumberOfChannels(2)
            }
            engine.prepare()
        }

        // Tap the node's own format (int16, int32, float, interleaved or not).
        // A later converter turns that into float32 at 48 kHz. Reinterpreting
        // the bytes ourselves is what squares off a hot line input.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw CaptureError(message: "The microphone has no audio format yet. Plug it in and tap Start again.")
        }
        logRouteFormat("tap")
        let sourceChannels = hardware.channelCount
        let captureChannels: AVAudioChannelCount = (musicActive && sourceChannels >= 2) ? 2 : 1
        channels = Int(captureChannels)
        let widen = musicActive && channels < 2 && stereoWiden
        encodeChannels = widen ? 2 : channels
        widener.reset()
        encoder = try OpusEncoderBox(music: musicActive, channels: encodeChannels)
        let profile = Self.profileLabel(music: musicActive, stereo: encodeChannels >= 2)
        DispatchQueue.main.async { [weak self] in self?.onProfile?(profile) }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: sourceChannels,
            interleaved: false
        ), let converter = AVAudioConverter(from: hardware, to: target) else {
            throw CaptureError(message: "Could not convert the input to 48 kHz.")
        }
        converter.primeMethod = .none
        self.converter = converter
        self.targetFormat = target
        pullScratch = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 16_384)
        convertOut = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384)
        pending.removeAll(keepingCapacity: true)
        input.removeTap(onBus: 0)
        let bufferSize = sliceFrames(format: hardware, session: session, unit: input.audioUnit)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hardware) { [weak self] buffer, _ in
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
        let incoming = Int(buffer.frameLength)
        guard incoming > 0 else { return }
        framesIn += incoming
        if abs(buffer.format.sampleRate - converter.inputFormat.sampleRate) > 1
            || buffer.format.channelCount != converter.inputFormat.channelCount {
            framesDiscarded += incoming
            noteFormatMismatch()
            return
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let needed = AVAudioFrameCount(ceil(Double(incoming) * ratio)) + 256
        if convertOut == nil || (convertOut?.frameCapacity ?? 0) < needed {
            convertOut = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(needed, 8_192))
        }
        guard let output = convertOut else {
            framesDiscarded += incoming
            return
        }
        var offset: AVAudioFrameCount = 0
        var spins = 0
        while offset < buffer.frameLength && spins < 8 {
            spins += 1
            let before = offset
            output.frameLength = 0
            var convError: NSError?
            converter.convert(to: output, error: &convError) { requested, status in
                if offset >= buffer.frameLength {
                    status.pointee = .noDataNow
                    return nil
                }
                let want = AVAudioFrameCount(max(0, requested))
                if want == 0 {
                    status.pointee = .noDataNow
                    return nil
                }
                let give = min(want, buffer.frameLength - offset)
                guard self.copyIntoScratch(buffer, offset: offset, count: give) else {
                    status.pointee = .noDataNow
                    return nil
                }
                offset += give
                status.pointee = .haveData
                return self.pullScratch
            }
            if convError != nil {
                framesDiscarded += Int(buffer.frameLength - offset)
                break
            }
            let produced = Int(output.frameLength)
            if produced == 0 {
                if offset == before { break }
                continue
            }
            framesOut += produced
            appendConverted(output)
        }
        if offset < buffer.frameLength {
            framesDiscarded += Int(buffer.frameLength - offset)
        }
        maybeLogStats()
    }

    /// The converter asks for a specific frame count. Give it only that many
    /// and keep the rest for the next pull, so a 44.1 kHz buffer is not truncated.
    private func copyIntoScratch(_ buffer: AVAudioPCMBuffer, offset: AVAudioFrameCount, count: AVAudioFrameCount) -> Bool {
        guard count > 0 else { return false }
        if pullScratch == nil || (pullScratch?.frameCapacity ?? 0) < count || pullScratch?.format != buffer.format {
            pullScratch = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(count, 16_384))
        }
        guard let scratch = pullScratch else { return false }
        if buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved,
           let src = buffer.floatChannelData, let dst = scratch.floatChannelData {
            let channelCount = min(Int(buffer.format.channelCount), Int(scratch.format.channelCount))
            let samples = Int(count)
            let start = Int(offset)
            guard channelCount > 0, samples > 0 else { return false }
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel] + start, count: samples)
            }
            scratch.frameLength = count
            return true
        }
        let srcList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
        guard !srcList.isEmpty, srcList.count == dstList.count else { return false }
        let asbd = buffer.format.streamDescription.pointee
        if buffer.format.isInterleaved {
            let bytesPerFrame = Int(asbd.mBytesPerFrame)
            guard bytesPerFrame > 0, let srcData = srcList[0].mData, let dstData = dstList[0].mData else { return false }
            memcpy(dstData, srcData.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame)
        } else {
            let bytesPerSample = max(1, Int(asbd.mBitsPerChannel / 8))
            for index in 0..<srcList.count {
                guard let srcData = srcList[index].mData, let dstData = dstList[index].mData else { return false }
                memcpy(dstData, srcData.advanced(by: Int(offset) * bytesPerSample), Int(count) * bytesPerSample)
            }
        }
        scratch.frameLength = count
        return true
    }

    private func appendConverted(_ output: AVAudioPCMBuffer) {
        guard let src = output.floatChannelData else { return }
        let count = Int(output.frameLength)
        let srcCh = Int(output.format.channelCount)
        guard count > 0, srcCh > 0 else { return }
        let frameCount = OpusEncoderBox.frameSamples
        if channels >= 2 {
            let leftCount = max(1, (srcCh + 1) / 2)
            let rightCount = max(1, srcCh / 2)
            for index in 0..<count {
                var left: Float = 0
                var right: Float = 0
                if srcCh == 1 {
                    left = src[0][index]
                    right = left
                } else {
                    for channel in 0..<leftCount { left += src[channel][index] }
                    left /= Float(leftCount)
                    for channel in leftCount..<srcCh { right += src[channel][index] }
                    right /= Float(max(1, rightCount))
                }
                pending.append(left)
                pending.append(right)
            }
            if pending.count > 96_000 {
                let overflow = pending.count - 96_000
                pending.removeFirst(overflow)
                framesDiscarded += overflow / 2
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
            let scale = 1 / Float(srcCh)
            for index in 0..<count {
                var sum: Float = 0
                for channel in 0..<srcCh { sum += src[channel][index] }
                pending.append(sum * scale)
            }
            if pending.count > 48_000 {
                let overflow = pending.count - 48_000
                pending.removeFirst(overflow)
                framesDiscarded += overflow
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
        let trim: Float = (music && !hardwareGainSettable) ? inputTrim : 1
        mixLock.unlock()

        if leveler {
            var energy: Float = 0
            for index in 0..<sampleCount {
                let sample = frame[index]
                energy += sample * sample
            }
            let rms = sqrt(energy / Float(sampleCount))
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
            if abs(sample) >= 0.99 { hot += 1 }
            let driven = sample * trim * (leveler ? levelerGain : gain)
            let heard = Self.limit(driven)
            heardSum += heard * heard
            frame[index] = sendSilence ? 0 : heard
        }
        let rms = sqrt(heardSum / Float(max(sampleCount, 1)))
        let db = 20 * log10(max(rms, 1e-8))
        let level = min(1, max(0, (db + 60) / 60))
        let now = Date()
        if hot > 0 {
            if clipHotSince == nil { clipHotSince = now }
            if let clipHotSince, now.timeIntervalSince(clipHotSince) > 0.5 {
                clipUntil = now.addingTimeInterval(0.5)
            }
        } else {
            clipHotSince = nil
        }
        if now.timeIntervalSince(lastLevelAt) >= 0.04 {
            lastLevelAt = now
            let shown = level
            let clipping = now < clipUntil
            let clipChanged = clipping != clipShown
            if clipChanged { clipShown = clipping }
            DispatchQueue.main.async { [weak self] in
                self?.onLevel?(shown)
                if clipChanged { self?.onClip?(clipping) }
            }
        }
        guard let encoder else { return }
        let packet: Data?
        if encodeChannels >= 2 && channels < 2 && !sendSilence {
            widener.expand(frame, count: sampleCount, into: &wide)
            for index in 0..<(sampleCount * 2) {
                wide[index] = Self.limit(wide[index])
            }
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
        framesQueued += OpusEncoderBox.frameSamples
        handoff(packet)
    }

    /// Soft ceiling just under full scale. Linear below −1 dB so a normal
    /// line level is not coloured, and a hot sample cannot square off.
    private static func limit(_ sample: Float) -> Float {
        let capped = min(8, max(-8, sample))
        let magnitude = abs(capped)
        if magnitude <= 0.89 { return capped }
        let sign: Float = capped < 0 ? -1 : 1
        let extra = 0.09 * (1 - exp(-(magnitude - 0.89) * 8))
        return sign * (0.89 + extra)
    }

    /// Send each 20 ms packet as soon as it is encoded. A timer that emits one
    /// packet per tick runs slow and the drop-oldest cap then throws audio away.
    /// The serial queue keeps order. Packets are dropped only if more than a
    /// second is already waiting.
    private func handoff(_ packet: Data) {
        paceLock.lock()
        outbound.append(packet)
        let overflow = outbound.count - 50
        if overflow > 0 {
            outbound.removeFirst(overflow)
            packetsDropped += overflow
        }
        let kick = !sendScheduled && !paceStopped
        if kick { sendScheduled = true }
        paceLock.unlock()
        guard kick else { return }
        paceQueue.async { [weak self] in
            self?.drainOutbound()
        }
    }

    private func drainOutbound() {
        while true {
            paceLock.lock()
            if paceStopped || outbound.isEmpty {
                outbound.removeAll(keepingCapacity: true)
                sendScheduled = false
                paceLock.unlock()
                return
            }
            let packet = outbound.removeFirst()
            packetsSent += 1
            paceLock.unlock()
            onPacket?(packet)
        }
    }

    private func maybeLogStats() {
        #if DEBUG
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 5 else { return }
        lastReport = now
        paceLock.lock()
        let sent = packetsSent
        let dropped = packetsDropped
        paceLock.unlock()
        log.info("RoomCast audio in=\(self.framesIn, privacy: .public) converted=\(self.framesOut, privacy: .public) queued=\(self.framesQueued, privacy: .public) discarded=\(self.framesDiscarded, privacy: .public) sent=\(sent, privacy: .public) droppedPkts=\(dropped, privacy: .public)")
        #else
        _ = lastReport
        #endif
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
            self?.audioQueue.async {
                guard let self, self.running, !self.engine.isRunning else { return }
                self.enqueueRebuild(force: true)
            }
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
            self.enqueueRebuild(force: true)
        }
    }

    private func graphMatchesInput() -> Bool {
        guard let converter else { return false }
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        // A zero rate means the format is not readable from this thread.
        // Tearing the engine down on that guess is what made the audio click.
        if hardware.sampleRate <= 0 || hardware.channelCount <= 0 {
            return true
        }
        return hardware.sampleRate == converter.inputFormat.sampleRate
    }

    private func handleInterruption(_ note: Notification) {
        guard running else { return }
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            #if DEBUG
            log.info("audio interrupted")
            #endif
            DispatchQueue.main.async { [weak self] in self?.onInterrupted?(true) }
        case .ended:
            let optionRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
            #if DEBUG
            log.info("interruption ended, should resume \(options.contains(.shouldResume), privacy: .public)")
            #endif
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
            if self.running {
                self.applyPreferredInput()
            } else {
                self.prepareRouteForReading()
            }
            self.reportInput()
            self.logRouteFormat("change \(reason.rawValue)")
            guard self.running else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override:
                #if DEBUG
                self.log.info("route changed: \(String(describing: reason), privacy: .public)")
                #endif
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

    /// Makes the current input readable without starting `AVAudioEngine`.
    /// `setActive` is what fills `availableInputs` for a USB interface that is
    /// already plugged in. It is skipped until the user has already granted
    /// microphone permission, so idle reading does not present the prompt.
    private func prepareRouteForReading() {
        let session = AVAudioSession.sharedInstance()
        ensureCategory()
        let granted = AVAudioApplication.shared.recordPermission == .granted
        if granted {
            try? session.setActive(true)
        }
        applyPreferredInput()
        if granted {
            try? session.setActive(true)
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

    /// Idle and live labels both come from this read.
    private struct InputSnapshot {
        var name: String
        var label: String
        var channels: Int
        var usb: Bool
        var gainSettable: Bool
    }

    private static func inputSnapshot(_ session: AVAudioSession = .sharedInstance()) -> InputSnapshot {
        let preferred = bestInput(session.availableInputs)
        let current = session.currentRoute.inputs.first
        let port: AVAudioSessionPortDescription?
        if let preferred, isExternal(preferred) {
            port = preferred
        } else {
            port = current ?? preferred
        }
        let trimmed = port?.portName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? "iPhone mic" : trimmed
        let count = hardwareChannels(port: port, session: session)
        let usb = routeIsUSB
        return InputSnapshot(
            name: name,
            label: channelLabel(channels: count, port: port),
            channels: count,
            usb: usb,
            gainSettable: usb && session.isInputGainSettable
        )
    }

    private func reportInput() {
        let snap = Self.inputSnapshot()
        #if DEBUG
        log.info("input \(snap.name, privacy: .public)")
        #endif
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onInput?(snap.name)
            self.onHardware?(snap.label, snap.channels)
            self.onUSB?(snap.usb)
            self.onInputGain?(snap.gainSettable)
        }
    }

    /// One line Walter can paste after plugging a card in.
    /// The engine's input node is only read while capture is running. Touching
    /// it while idle builds the input unit and can prompt for the microphone.
    private func logRouteFormat(_ reason: String) {
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.inputs.first
        guard running else {
            log.info("route \(reason, privacy: .public) port=\(port?.portType.rawValue ?? "-", privacy: .public) name=\(port?.portName ?? "-", privacy: .public) portCh=\(port?.channels?.count ?? 0) idle=true")
            return
        }
        let format = engine.inputNode.inputFormat(forBus: 0)
        let bits = format.streamDescription.pointee.mBitsPerChannel
        let kind: String
        switch format.commonFormat {
        case .pcmFormatFloat32: kind = "float32"
        case .pcmFormatFloat64: kind = "float64"
        case .pcmFormatInt16: kind = "int16"
        case .pcmFormatInt32: kind = "int32"
        default: kind = "other"
        }
        log.info("route \(reason, privacy: .public) port=\(port?.portType.rawValue ?? "-", privacy: .public) name=\(port?.portName ?? "-", privacy: .public) portCh=\(port?.channels?.count ?? 0) sessionRate=\(session.sampleRate, privacy: .public) hwRate=\(format.sampleRate, privacy: .public) format=\(kind, privacy: .public) interleaved=\(format.isInterleaved, privacy: .public) ch=\(format.channelCount, privacy: .public) bits=\(bits, privacy: .public) gainSettable=\(session.isInputGainSettable, privacy: .public)")
        #else
        _ = reason
        #endif
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

    private static func profileLabel(music: Bool, stereo: Bool) -> String {
        if !music { return "Voice" }
        if stereo { return "Stereo music" }
        return "Music"
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
