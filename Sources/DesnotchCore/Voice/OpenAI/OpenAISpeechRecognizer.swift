import AVFoundation
import Foundation

/// Microphone source for the cloud recognizer: 16 kHz mono Float chunks, delivered on an
/// arbitrary thread. A seam so the recognizer is testable without a microphone.
protocol VoiceAudioCapturing: AnyObject, Sendable {
    /// Opens the microphone. False when it cannot start (no input device, engine error).
    func start(onChunk: @escaping @Sendable ([Float]) -> Void) -> Bool
    func stop()
}

/// Speech-to-text through the opt-in OpenAI-compatible provider. Audio is captured into memory,
/// and only when the user ends the capture (`endAudio`) is it encoded as a 16 kHz mono WAV in
/// memory and posted to `{base}/audio/transcriptions`. Nothing is written to disk; there are no
/// partial transcripts (the pill shows "Transcribing…"). `cancel` drops the audio and the
/// request. The fixed recognizer hint list is never sent (it stays an on-device-only hint).
/// Thread safety: the current capture is guarded by `lock`.
final class OpenAISpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    private final class Capture {
        let token: UInt64
        let continuation: AsyncStream<SpeechEvent>.Continuation
        var samples: [Float] = []
        var started = false
        var ended = false
        var throttle = EmitThrottle(maxHz: VoiceLimits.meterMaxHz)
        var upload: Task<Void, Never>?

        init(token: UInt64, continuation: AsyncStream<SpeechEvent>.Continuation) {
            self.token = token
            self.continuation = continuation
        }
    }

    private let config: VoiceAIConfigBox
    private let keys: VoiceAIKeyStoring
    private let session: URLSession
    private let audio: VoiceAudioCapturing
    private let microphoneAuthorized: @Sendable () -> Bool
    private let lock = NSLock()
    private var current: Capture?
    private var nextToken: UInt64 = 1

    init(
        config: VoiceAIConfigBox,
        keys: VoiceAIKeyStoring,
        session: URLSession,
        audio: VoiceAudioCapturing,
        microphoneAuthorized: @escaping @Sendable () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    ) {
        self.config = config
        self.keys = keys
        self.session = session
        self.audio = audio
        self.microphoneAuthorized = microphoneAuthorized
    }

    func start(localeIdentifier: String, contextualStrings: [String]) -> AsyncStream<SpeechEvent> {
        cancel()
        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream()
        guard microphoneAuthorized() else {
            continuation.yield(.failed(.permissionDenied(.microphone)))
            continuation.finish()
            return stream
        }
        // Fail before the microphone opens when the provider is not set up.
        if let failure = VoiceAIReadiness.check(base: config.current().baseURL, keys: keys) {
            continuation.yield(.failed(.provider(failure)))
            continuation.finish()
            return stream
        }
        let token = register(continuation)
        continuation.onTermination = { [weak self] _ in
            self?.cancel(token: token)
        }
        let opened = audio.start { [weak self] chunk in
            self?.receive(chunk, token: token)
        }
        if !opened {
            if let capture = take(token: token) {
                capture.continuation.yield(.failed(.unavailable(.recognizer)))
                capture.continuation.finish()
            }
        }
        return stream
    }

    func endAudio() {
        guard let (token, samples) = markEnded() else { return }
        audio.stop()
        guard samples.count >= VoiceAILimits.minSamples else {
            finish(token: token, with: .final(""))
            return
        }
        let snapshot = config.current()
        let keys = self.keys
        let session = self.session
        let task = Task { [weak self] in
            let event = await Self.transcribe(samples, config: snapshot, keys: keys, session: session)
            guard let event else { return }
            self?.finish(token: token, with: event)
        }
        attach(task, token: token)
    }

    func cancel() {
        guard let capture = takeCurrent() else { return }
        teardown(capture)
    }

    /// One upload. Nil when cancelled (the stream was already finished by `cancel`).
    static func transcribe(
        _ samples: [Float], config: VoiceAIConfig, keys: VoiceAIKeyStoring, session: URLSession
    ) async -> SpeechEvent? {
        let ready: VoiceAIReadiness.Ready
        switch VoiceAIReadiness.resolve(base: config.baseURL, keys: keys) {
        case .failure(let failure): return .failed(.provider(failure))
        case .success(let value): ready = value
        }
        let wav = WAVEncoder.encode(WAVEncoder.pcm16(samples), sampleRate: VoiceAILimits.sampleRate)
        let request = OpenAIAudioWire.transcription(
            base: ready.base, key: ready.key, model: config.sttModel, language: config.language, wav: wav
        )
        switch await VoiceAIHTTP.send(request, session: session, maxBytes: VoiceAILimits.maxJSONBytes) {
        case .ok(let data):
            guard let text = OpenAIAudioWire.transcriptText(data) else { return .failed(.provider(.badResponse)) }
            return .final(text)
        case .status(let status, _):
            return .failed(.provider(VoiceAIHTTP.classify(status: status)))
        case .failed(let failure):
            return .failed(.provider(failure))
        case .cancelled:
            return nil
        }
    }

    // MARK: - Capture state (every access under `lock`, in synchronous helpers)

    private func register(_ continuation: AsyncStream<SpeechEvent>.Continuation) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        current = Capture(token: token, continuation: continuation)
        return token
    }

    private func receive(_ chunk: [Float], token: UInt64) {
        var events: [SpeechEvent] = []
        var continuation: AsyncStream<SpeechEvent>.Continuation?
        lock.lock()
        if let capture = current, capture.token == token, !capture.ended {
            continuation = capture.continuation
            if !capture.started {
                capture.started = true
                events.append(.captureStarted)
            }
            let room = VoiceAILimits.maxSamples - capture.samples.count
            if room > 0 {
                capture.samples.append(contentsOf: chunk.prefix(room))
            }
            if !chunk.isEmpty, capture.throttle.shouldEmit(at: ProcessInfo.processInfo.systemUptime) {
                let sum = chunk.reduce(Float(0)) { $0 + $1 * $1 }
                events.append(.level(LevelMeter.level(fromRMS: sqrt(sum / Float(chunk.count)))))
            }
        }
        lock.unlock()
        guard let continuation else { return }
        for event in events { continuation.yield(event) }
    }

    /// Marks the capture ended and hands out its audio; later chunks are ignored.
    private func markEnded() -> (UInt64, [Float])? {
        lock.lock()
        defer { lock.unlock() }
        guard let capture = current, !capture.ended else { return nil }
        capture.ended = true
        let samples = capture.samples
        capture.samples.removeAll()
        return (capture.token, samples)
    }

    private func attach(_ task: Task<Void, Never>, token: UInt64) {
        lock.lock()
        let attached: Bool
        if let capture = current, capture.token == token {
            capture.upload = task
            attached = true
        } else {
            attached = false
        }
        lock.unlock()
        if !attached { task.cancel() }
    }

    private func finish(token: UInt64, with event: SpeechEvent) {
        guard let capture = take(token: token) else { return }
        capture.continuation.yield(event)
        capture.continuation.finish()
    }

    private func take(token: UInt64) -> Capture? {
        lock.lock()
        defer { lock.unlock() }
        guard let capture = current, capture.token == token else { return nil }
        current = nil
        return capture
    }

    private func takeCurrent() -> Capture? {
        lock.lock()
        defer { lock.unlock() }
        let capture = current
        current = nil
        return capture
    }

    private func cancel(token: UInt64) {
        guard let capture = take(token: token) else { return }
        teardown(capture)
    }

    private func teardown(_ capture: Capture) {
        if !capture.ended { audio.stop() }
        capture.upload?.cancel()
        capture.continuation.finish()
    }
}

/// The real microphone: `AVAudioEngine` input converted to 16 kHz mono Float in memory.
/// Thread safety: the engine is guarded by `lock`.
final class EngineAudioCapture: VoiceAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?

    func start(onChunk: @escaping @Sendable ([Float]) -> Void) -> Bool {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(VoiceAILimits.sampleRate),
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return false }
        converter.downmix = true
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            // One input buffer per call. A reference flag, not a captured `var`, so the input
            // block stays valid if the SDK marks it `@Sendable`.
            let fed = ConverterFeed()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if fed.done {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fed.done = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil,
                  let channel = output.floatChannelData?[0], output.frameLength > 0
            else { return }
            onChunk(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        store(engine)
        return true
    }

    func stop() {
        guard let engine = take() else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func store(_ engine: AVAudioEngine) {
        lock.lock()
        self.engine = engine
        lock.unlock()
    }

    private func take() -> AVAudioEngine? {
        lock.lock()
        defer { lock.unlock() }
        let engine = self.engine
        self.engine = nil
        return engine
    }
}

/// Single-use flag for one `AVAudioConverter.convert` call; it never leaves the audio tap
/// callback that created it, so it needs no lock.
private final class ConverterFeed: @unchecked Sendable {
    var done = false
}
