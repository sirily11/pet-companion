import AVFoundation
import Darwin
import Combine

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isMicrophoneEnabled = false
    @Published private(set) var isListeningPaused = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var microphoneLevel: Float = 0
    var onInputAudio: ((Data) -> Void)?
    var onLipFrame: ((LipFrame) -> Void)?
    var onError: ((String) -> Void)?
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var queuedFrames: AVAudioFrameCount = 0
    private var generation = UUID()
    private var demoGeneration = UUID()
    private var captureGeneration = UUID()
    private var isReceivingResponseAudio = false
    private var resumeListeningTask: Task<Void, Never>?
    private var lipTimer: Timer?
    private var playbackLatency: TimeInterval = 0
    private var queuedLips: [(time: TimeInterval, frame: LipFrame)] = []

    init(outputVolume: Float = 1) {
        playbackEngine.mainMixerNode.outputVolume = outputVolume
        playbackEngine.attach(player)
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: outputFormat)
        player.installTap(onBus: 0, bufferSize: 480, format: outputFormat) { [weak self] buffer, renderTime in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let frames = PlaybackLipEnvelope.frames(samples: samples, sampleRate: buffer.format.sampleRate)
            let hostTime = renderTime.isHostTimeValid ? AVAudioTime.seconds(forHostTime: renderTime.hostTime) : AVAudioTime.seconds(forHostTime: mach_absolute_time())
            Task { @MainActor in
                guard let self, self.isSpeaking else { return }
                self.queuedLips += frames.map { (hostTime + self.playbackLatency + $0.offset, $0.frame) }
                if self.queuedLips.count > 500 { self.queuedLips.removeFirst(self.queuedLips.count - 500) }
            }
        }
        lipTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.presentLipFrame() }
        }
    }

    private func presentLipFrame() {
        guard isSpeaking else { queuedLips.removeAll(); return }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        var latest: LipFrame?
        while let next = queuedLips.first, next.time <= now {
            latest = next.frame
            queuedLips.removeFirst()
        }
        if let latest { onLipFrame?(latest) }
    }

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func startCapture() throws {
        isMicrophoneEnabled = true
        guard !isListeningPaused else { return }
        do { try startInputCapture() }
        catch { isMicrophoneEnabled = false; throw error }
    }

    private func startInputCapture() throws {
        guard !isCapturing else { return }
        let input = captureEngine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioError.noInput
        }
        captureGeneration = UUID()
        let token = captureGeneration
        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / sourceFormat.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, output.frameLength > 0,
                  let pointer = output.audioBufferList.pointee.mBuffers.mData else { return }
            let data = Data(bytes: pointer, count: Int(output.frameLength) * 2)
            let frame = LipSyncAnalyzer.analyze(PCM16.decode(data))
            Task { @MainActor in
                guard let self, self.isCapturing, !self.isListeningPaused,
                      self.captureGeneration == token else { return }
                self.microphoneLevel = frame.open
                self.onInputAudio?(data)
            }
        }
        do {
            captureEngine.prepare()
            try captureEngine.start()
            isCapturing = true
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stopCapture() {
        isMicrophoneEnabled = false
        stopInputCapture()
    }

    private func stopInputCapture() {
        captureGeneration = UUID()
        guard isCapturing else { return }
        captureEngine.stop()
        captureEngine.inputNode.removeTap(onBus: 0)
        isCapturing = false
        microphoneLevel = 0
    }

    func beginResponse() {
        isReceivingResponseAudio = true
        pauseListening()
    }

    func finishResponse() {
        isReceivingResponseAudio = false
        resumeListeningIfReady()
    }

    private func pauseListening() {
        resumeListeningTask?.cancel(); resumeListeningTask = nil
        guard !isListeningPaused else { return }
        isListeningPaused = true
        stopInputCapture()
    }

    private func resumeListeningIfReady() {
        guard isListeningPaused, !isReceivingResponseAudio, queuedFrames == 0 else { return }
        resumeListeningTask?.cancel()
        let token = generation
        resumeListeningTask = Task { [weak self] in
            // Let the final sound decay before reopening the microphone.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.generation == token,
                  !self.isReceivingResponseAudio, self.queuedFrames == 0 else { return }
            self.resumeListeningTask = nil
            self.isListeningPaused = false
            guard self.isMicrophoneEnabled else { return }
            do { try self.startInputCapture() }
            catch { self.isMicrophoneEnabled = false; self.onError?(error.localizedDescription) }
        }
    }

    func playPCM(_ data: Data) throws {
        let samples = PCM16.decode(data)
        guard !samples.isEmpty else { return }
        try schedule(samples, sampleRate: 24_000)
    }

    private func schedule(_ samples: [Float], sampleRate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { source in input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count) }
        let output: AVAudioPCMBuffer
        if sampleRate == 24_000 {
            output = input
        } else {
            guard let converter = AVAudioConverter(from: format, to: outputFormat),
                  let converted = AVAudioPCMBuffer(pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 24_000 / sampleRate)) + 32) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true; status.pointee = .haveData; return input
            }
            if let error { throw error }
            output = converted
        }
        guard queuedFrames + output.frameLength < 24_000 * 30 else { throw AudioError.backlog }
        if !playbackEngine.isRunning {
            try playbackEngine.start()
            playbackLatency = playbackEngine.outputNode.presentationLatency
        }
        let frameCount = output.frameLength
        let token = generation
        pauseListening()
        queuedFrames += frameCount
        isSpeaking = true
        player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.queuedFrames -= min(self.queuedFrames, frameCount)
                if self.queuedFrames == 0 {
                    self.isSpeaking = false; self.onLipFrame?(.silence)
                    self.resumeListeningIfReady()
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    func stopPlayback() {
        generation = UUID(); demoGeneration = UUID()
        resumeListeningTask?.cancel(); resumeListeningTask = nil
        isReceivingResponseAudio = false
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        queuedFrames = 0
        queuedLips.removeAll()
        isSpeaking = false
        onLipFrame?(.silence)
        resumeListeningIfReady()
    }

    func playDemo() {
        stopPlayback()
        let token = demoGeneration
        let utterance = AVSpeechUtterance(string: "Hello! I'm your little cat companion. Tell me about your day. We can wave, look curious, or get a little sleepy together.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.47
        synthesizer.write(utterance) { [weak self] audio in
            guard let buffer = audio as? AVAudioPCMBuffer, buffer.frameLength > 0 else { return }
            let samples: [Float]
            if let floats = buffer.floatChannelData {
                samples = Array(UnsafeBufferPointer(start: floats[0], count: Int(buffer.frameLength)))
            } else if let ints = buffer.int16ChannelData {
                samples = UnsafeBufferPointer(start: ints[0], count: Int(buffer.frameLength)).map { Float($0) / 32768 }
            } else { return }
            let sampleRate = buffer.format.sampleRate
            Task { @MainActor in
                guard let self, self.demoGeneration == token else { return }
                do { try self.schedule(samples, sampleRate: sampleRate) }
                catch { self.stopPlayback(); self.onError?(error.localizedDescription) }
            }
        }
    }
}

enum AudioError: LocalizedError {
    case noInput, backlog
    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone is available. Choose an input device in System Settings."
        case .backlog: "Audio arrived faster than playback could handle. Please reconnect."
        }
    }
}
