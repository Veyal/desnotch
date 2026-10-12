import AVFoundation
import Foundation
import Speech

struct CaptureBook<Payload> {
    private var nextToken: UInt64 = 1
    private(set) var currentToken: UInt64?
    private var currentPayload: Payload?

    mutating func begin(payload: Payload) -> (token: UInt64, replaced: Payload?) {
        let token = nextToken
        nextToken &+= 1
        let replaced = currentPayload
        currentToken = token
        currentPayload = payload
        return (token, replaced)
    }

    func payload(forToken token: UInt64) -> Payload? {
        guard let currentToken, currentToken == token else { return nil }
        return currentPayload
    }

    mutating func take(token: UInt64) -> Payload? {
        guard let currentToken, currentToken == token else { return nil }
        let payload = currentPayload
        self.currentToken = nil
        self.currentPayload = nil
        return payload
    }

    mutating func takeCurrent() -> Payload? {
        guard let currentToken else { return nil }
        return take(token: currentToken)
    }
}

enum SpeechDecision {
    /// nil = nothing to emit. `text` is `result?.bestTranscription.formattedString`, nil when the handler got an error and no result.
    static func event(text: String?, isFinal: Bool, errorPresent: Bool, endAudioCalled: Bool, lastPartial: String) -> SpeechEvent? {
        if errorPresent {
            if endAudioCalled {
                return .final(lastPartial)
            } else {
                return .failed(.unavailable(.recognizer))
            }
        }
        if let text {
            if isFinal {
                return .final(text)
            } else {
                return .partial(text)
            }
        }
        return nil
    }

    /// true for `.final` and `.failed`: the capture is over, tear down and finish the stream.
    static func isTerminal(_ event: SpeechEvent) -> Bool {
        switch event {
        case .final, .failed:
            return true
        case .captureStarted, .level, .partial:
            return false
        }
    }
}

/// Microphone capture and on-device recognition using AVFoundation and SFSpeechRecognizer.
/// Thread safety: all mutable capture state is guarded by an internal NSLock.
final class AppleSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    private final class CaptureState {
        let continuation: AsyncStream<SpeechEvent>.Continuation
        let request: SFSpeechAudioBufferRecognitionRequest
        let recognizer: SFSpeechRecognizer
        let engine: AVAudioEngine
        var task: SFSpeechRecognitionTask?
        var throttle = EmitThrottle(maxHz: VoiceLimits.meterMaxHz)
        var hasEmittedCaptureStarted = false
        var endAudioCalled = false
        var lastPartial = ""
        var tapInstalled = false

        init(
            continuation: AsyncStream<SpeechEvent>.Continuation,
            request: SFSpeechAudioBufferRecognitionRequest,
            recognizer: SFSpeechRecognizer,
            engine: AVAudioEngine
        ) {
            self.continuation = continuation
            self.request = request
            self.recognizer = recognizer
            self.engine = engine
        }
    }

    private let lock = NSLock()
    private var book = CaptureBook<CaptureState>()

    init() {}

    func start(localeIdentifier: String, contextualStrings: [String]) -> AsyncStream<SpeechEvent> {
        cancel()

        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream()

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            continuation.yield(.failed(.permissionDenied(.microphone)))
            continuation.finish()
            return stream
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        guard speechStatus == .authorized else {
            continuation.yield(.failed(.permissionDenied(.speech)))
            continuation.finish()
            return stream
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            continuation.yield(.failed(.unavailable(.recognizer)))
            continuation.finish()
            return stream
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        request.addsPunctuation = false

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            continuation.yield(.failed(.unavailable(.recognizer)))
            continuation.finish()
            return stream
        }

        let state = CaptureState(
            continuation: continuation,
            request: request,
            recognizer: recognizer,
            engine: engine
        )

        lock.lock()
        let beginResult = book.begin(payload: state)
        lock.unlock()

        let token = beginResult.token
        let replacedState = beginResult.replaced

        if let replaced = replacedState {
            replaced.task?.cancel()
            if replaced.tapInstalled {
                replaced.engine.stop()
                replaced.engine.inputNode.removeTap(onBus: 0)
            }
            replaced.continuation.finish()
        }

        continuation.onTermination = { [weak self] _ in
            self?.cancel(token: token)
        }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            var eventToEmit: SpeechEvent?
            var terminal = false
            var cont: AsyncStream<SpeechEvent>.Continuation?
            var eng: AVAudioEngine?
            var shouldRemoveTap = false

            self.lock.lock()
            if let current = self.book.payload(forToken: token) {
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let errorPresent = (error != nil)
                if let event = SpeechDecision.event(
                    text: text,
                    isFinal: isFinal,
                    errorPresent: errorPresent,
                    endAudioCalled: current.endAudioCalled,
                    lastPartial: current.lastPartial
                ) {
                    eventToEmit = event
                    if SpeechDecision.isTerminal(event) {
                        terminal = true
                        if let taken = self.book.take(token: token) {
                            cont = taken.continuation
                            eng = taken.engine
                            shouldRemoveTap = taken.tapInstalled
                        }
                    } else {
                        if case .partial(let partialText) = event {
                            current.lastPartial = partialText
                        }
                        cont = current.continuation
                    }
                }
            }
            self.lock.unlock()

            if let eventToEmit, let cont {
                cont.yield(eventToEmit)
                if terminal {
                    cont.finish()
                    if let eng, shouldRemoveTap {
                        eng.stop()
                        eng.inputNode.removeTap(onBus: 0)
                    }
                }
            }
        }
        state.task = task

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            var req: SFSpeechAudioBufferRecognitionRequest?
            var cont: AsyncStream<SpeechEvent>.Continuation?
            var shouldEmitStarted = false
            var shouldEmitLevel = false

            self.lock.lock()
            if let current = self.book.payload(forToken: token) {
                req = current.request
                cont = current.continuation
                if !current.hasEmittedCaptureStarted {
                    current.hasEmittedCaptureStarted = true
                    shouldEmitStarted = true
                }
                let now = ProcessInfo.processInfo.systemUptime
                if current.throttle.shouldEmit(at: now) {
                    shouldEmitLevel = true
                }
            }
            self.lock.unlock()

            guard let req, let cont else { return }
            req.append(buffer)

            if shouldEmitStarted {
                cont.yield(.captureStarted)
            }

            if shouldEmitLevel, let channel = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                if frames > 0 {
                    var sum: Float = 0
                    for i in 0..<frames {
                        let sample = channel[i]
                        sum += sample * sample
                    }
                    let rms = sqrt(sum / Float(frames))
                    cont.yield(.level(LevelMeter.level(fromRMS: rms)))
                }
            }
        }
        state.tapInstalled = true

        do {
            try engine.start()
        } catch {
            var cont: AsyncStream<SpeechEvent>.Continuation?
            self.lock.lock()
            if let taken = self.book.take(token: token) {
                cont = taken.continuation
            }
            self.lock.unlock()

            inputNode.removeTap(onBus: 0)
            task.cancel()
            if let cont {
                cont.yield(.failed(.unavailable(.recognizer)))
                cont.finish()
            }
        }

        return stream
    }

    func endAudio() {
        var req: SFSpeechAudioBufferRecognitionRequest?
        var eng: AVAudioEngine?
        var shouldRemoveTap = false

        lock.lock()
        if let token = book.currentToken, let state = book.payload(forToken: token) {
            state.endAudioCalled = true
            req = state.request
            eng = state.engine
            if state.tapInstalled {
                state.tapInstalled = false
                shouldRemoveTap = true
            }
        }
        lock.unlock()

        if let eng, shouldRemoveTap {
            eng.stop()
            eng.inputNode.removeTap(onBus: 0)
        }
        req?.endAudio()
    }

    func cancel() {
        var stateToClean: CaptureState?

        lock.lock()
        stateToClean = book.takeCurrent()
        lock.unlock()

        guard let state = stateToClean else { return }
        state.task?.cancel()
        if state.tapInstalled {
            state.engine.stop()
            state.engine.inputNode.removeTap(onBus: 0)
        }
        state.continuation.finish()
    }

    private func cancel(token: UInt64) {
        var stateToClean: CaptureState?

        lock.lock()
        stateToClean = book.take(token: token)
        lock.unlock()

        guard let state = stateToClean else { return }
        state.task?.cancel()
        if state.tapInstalled {
            state.engine.stop()
            state.engine.inputNode.removeTap(onBus: 0)
        }
        state.continuation.finish()
    }
}
