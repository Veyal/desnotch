import XCTest
@testable import DesnotchCore

final class VoiceAISpeechTests: XCTestCase {
    private let base = "https://api.example.test/v1"

    private func recognizer(
        key: String? = "sk-test",
        audio: AIFakeAudioCapture,
        session: URLSession,
        language: String = "",
        microphone: Bool = true
    ) -> OpenAISpeechRecognizer {
        OpenAISpeechRecognizer(
            config: VoiceAIConfigBox(VoiceAIConfig(baseURL: base, sttModel: "whisper-1", language: language)),
            keys: AIMemoryKeyStore(key),
            session: session,
            audio: audio,
            microphoneAuthorized: { microphone }
        )
    }

    private func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) / 10)) * 0.4 }
    }

    // MARK: Speech-to-text

    func testCaptureUploadsOneWAVAfterEndAudio() async throws {
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, ["text": "buka safari"])])
        let session = AIStubURLProtocol.session()
        let audio = AIFakeAudioCapture()
        let stt = recognizer(audio: audio, session: session, language: "id")
        let stream = stt.start(localeIdentifier: "en-US", contextualStrings: VoiceLexicon.contextualStrings)
        audio.push(speech(0.5))
        audio.push(speech(0.5))
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty, "nothing is sent while the user is still talking")
        stt.endAudio()
        let events = await collect(stream)
        XCTAssertEqual(events.first, .captureStarted)
        XCTAssertTrue(events.contains { if case .level = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .partial = $0 { return true }; return false })
        XCTAssertEqual(events.last, .final("buka safari"))
        XCTAssertEqual(audio.stopCount, 1)
        let request = try XCTUnwrap(AIStubURLProtocol.requests.first)
        XCTAssertEqual(AIStubURLProtocol.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(AIStubURLProtocol.requestBodies.first)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nid\r\n"))
        XCTAssertFalse(text.contains("herdr"), "the recognizer hint list never leaves the Mac")
        let wavSize = 44 + 16_000 * 2
        XCTAssertGreaterThan(body.count, wavSize)
        session.invalidateAndCancel()
    }

    func testAudioIsCappedAtTheUploadLimit() async throws {
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, ["text": "ok"])])
        let session = AIStubURLProtocol.session()
        let audio = AIFakeAudioCapture()
        let stt = recognizer(audio: audio, session: session)
        let stream = stt.start(localeIdentifier: "en-US", contextualStrings: [])
        for _ in 0..<40 { audio.push(speech(1)) }
        stt.endAudio()
        _ = await collect(stream)
        let body = try XCTUnwrap(AIStubURLProtocol.requestBodies.first)
        XCTAssertLessThan(body.count, 44 + VoiceAILimits.maxSamples * 2 + 2_000)
        XCTAssertGreaterThanOrEqual(body.count, 44 + VoiceAILimits.maxSamples * 2)
        session.invalidateAndCancel()
    }

    func testTooLittleAudioIsNoSpeechAndNothingIsSent() async {
        AIStubURLProtocol.reset([])
        let session = AIStubURLProtocol.session()
        let audio = AIFakeAudioCapture()
        let stt = recognizer(audio: audio, session: session)
        let stream = stt.start(localeIdentifier: "en-US", contextualStrings: [])
        audio.push(speech(0.05))
        stt.endAudio()
        let events = await collect(stream)
        XCTAssertEqual(events.last, .final(""))
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty)
        session.invalidateAndCancel()
    }

    func testCancelDropsTheAudioAndSendsNothing() async {
        AIStubURLProtocol.reset([])
        let session = AIStubURLProtocol.session()
        let audio = AIFakeAudioCapture()
        let stt = recognizer(audio: audio, session: session)
        let stream = stt.start(localeIdentifier: "en-US", contextualStrings: [])
        audio.push(speech(1))
        stt.cancel()
        let events = await collect(stream)
        XCTAssertFalse(events.contains { if case .final = $0 { return true }; return false })
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty)
        session.invalidateAndCancel()
    }

    func testCancelDuringUploadEndsWithoutAFinal() async {
        AIStubURLProtocol.reset([.hang])
        let session = AIStubURLProtocol.session()
        let audio = AIFakeAudioCapture()
        let stt = recognizer(audio: audio, session: session)
        let stream = stt.start(localeIdentifier: "en-US", contextualStrings: [])
        audio.push(speech(1))
        stt.endAudio()
        await waitForRequest()
        stt.cancel()
        let events = await collect(stream)
        XCTAssertFalse(events.contains { if case .final = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false })
        session.invalidateAndCancel()
    }

    func testTranscriptionErrorsMapToProviderFailures() async {
        let session = AIStubURLProtocol.session()
        let cases: [(AIStubURLProtocol.Reply, ProviderFailure)] = [
            (AIStubURLProtocol.json(401, ["error": ["message": "bad key"]]), .unauthorized),
            (AIStubURLProtocol.json(413, [:]), .audioTooLarge),
            (.fail(.timedOut), .timeout),
            (.fail(.notConnectedToInternet), .network),
            (AIStubURLProtocol.json(200, ["unexpected": true]), .badResponse)
        ]
        for (reply, expected) in cases {
            AIStubURLProtocol.reset([reply])
            let audio = AIFakeAudioCapture()
            let stt = recognizer(audio: audio, session: session)
            let stream = stt.start(localeIdentifier: "en-US", contextualStrings: [])
            audio.push(speech(1))
            stt.endAudio()
            let events = await collect(stream)
            XCTAssertEqual(events.last, .failed(.provider(expected)))
        }
        session.invalidateAndCancel()
    }

    func testNotSetUpFailsBeforeTheMicrophoneOpens() async {
        AIStubURLProtocol.reset([])
        let session = AIStubURLProtocol.session()
        let audio = AIFakeAudioCapture()
        let noKey = recognizer(key: nil, audio: audio, session: session)
        let missing = await collect(noKey.start(localeIdentifier: "en-US", contextualStrings: []))
        XCTAssertEqual(missing, [.failed(.provider(.keyMissing))])
        let denied = recognizer(audio: audio, session: session, microphone: false)
        let mic = await collect(denied.start(localeIdentifier: "en-US", contextualStrings: []))
        XCTAssertEqual(mic, [.failed(.permissionDenied(.microphone))])
        XCTAssertEqual(audio.startCount, 0)
        let broken = AIFakeAudioCapture()
        broken.opens = false
        let failed = await collect(recognizer(audio: broken, session: session).start(localeIdentifier: "en-US", contextualStrings: []))
        XCTAssertEqual(failed, [.failed(.unavailable(.recognizer))])
        session.invalidateAndCancel()
    }

    // MARK: Spoken replies

    func testReplyIsFetchedAndPlayedFromMemory() async throws {
        let mp3 = Data([0x49, 0x44, 0x33, 0x04])
        AIStubURLProtocol.reset([.respond(status: 200, body: mp3, headers: ["Content-Type": "audio/mpeg"])])
        let session = AIStubURLProtocol.session()
        let player = AIFakePlayer(outcome: .finished)
        let fallback = CoordRecordingSynth()
        fallback.gated = false
        let tts = OpenAISpeechSynthesizer(
            config: VoiceAIConfigBox(VoiceAIConfig(baseURL: base, ttsVoice: "nova")),
            keys: AIMemoryKeyStore("sk-test"), session: session, player: player, fallback: fallback
        )
        let finished = await tts.speak("Volume 30", localeIdentifier: "en-US")
        XCTAssertTrue(finished)
        XCTAssertEqual(player.played, [mp3])
        XCTAssertTrue(fallback.spoken.isEmpty)
        let body = AITestJSON.object(try XCTUnwrap(AIStubURLProtocol.requestBodies.first))
        XCTAssertEqual(body["voice"] as? String, "nova")
        XCTAssertEqual(body["input"] as? String, "Volume 30")
        session.invalidateAndCancel()
    }

    func testReplyFallsBackToTheMacOSVoiceOnFailure() async {
        let session = AIStubURLProtocol.session()
        let replies: [AIStubURLProtocol.Reply] = [
            AIStubURLProtocol.json(500, [:]), .fail(.timedOut), .respond(status: 200, body: Data(), headers: [:])
        ]
        for reply in replies {
            AIStubURLProtocol.reset([reply])
            let player = AIFakePlayer(outcome: .finished)
            let fallback = CoordRecordingSynth()
            fallback.gated = false
            let tts = OpenAISpeechSynthesizer(
                config: VoiceAIConfigBox(VoiceAIConfig(baseURL: base)),
                keys: AIMemoryKeyStore("sk-test"), session: session, player: player, fallback: fallback
            )
            let finished = await tts.speak("Halo", localeIdentifier: "id-ID")
            XCTAssertTrue(finished)
            XCTAssertEqual(fallback.spoken.map(\.text), ["Halo"])
            XCTAssertEqual(fallback.spoken.map(\.locale), ["id-ID"])
            XCTAssertTrue(player.played.isEmpty)
        }
        session.invalidateAndCancel()
    }

    func testUndecodableAudioAndMissingKeyFallBack() async {
        AIStubURLProtocol.reset([.respond(status: 200, body: Data([1, 2, 3]), headers: [:])])
        let session = AIStubURLProtocol.session()
        let fallback = CoordRecordingSynth()
        fallback.gated = false
        let badAudio = OpenAISpeechSynthesizer(
            config: VoiceAIConfigBox(VoiceAIConfig(baseURL: base)), keys: AIMemoryKeyStore("sk-test"),
            session: session, player: AIFakePlayer(outcome: .failed), fallback: fallback
        )
        _ = await badAudio.speak("one", localeIdentifier: "en-US")
        let noKey = OpenAISpeechSynthesizer(
            config: VoiceAIConfigBox(VoiceAIConfig()), keys: AIMemoryKeyStore(),
            session: session, player: AIFakePlayer(outcome: .finished), fallback: fallback
        )
        _ = await noKey.speak("two", localeIdentifier: "en-US")
        XCTAssertEqual(fallback.spoken.map(\.text), ["one", "two"])
        XCTAssertEqual(AIStubURLProtocol.requests.count, 1, "no request without a key")
        session.invalidateAndCancel()
    }

    func testStopCancelsTheRequestAndDoesNotFallBack() async {
        AIStubURLProtocol.reset([.hang])
        let session = AIStubURLProtocol.session()
        let player = AIFakePlayer(outcome: .finished)
        let fallback = CoordRecordingSynth()
        fallback.gated = false
        let tts = OpenAISpeechSynthesizer(
            config: VoiceAIConfigBox(VoiceAIConfig(baseURL: base)), keys: AIMemoryKeyStore("sk-test"),
            session: session, player: player, fallback: fallback
        )
        let speaking = Task { await tts.speak("a long reply", localeIdentifier: "en-US") }
        await waitForRequest()
        tts.stop()
        let finished = await speaking.value
        XCTAssertFalse(finished)
        XCTAssertTrue(fallback.spoken.isEmpty)
        XCTAssertTrue(player.played.isEmpty)
        XCTAssertGreaterThanOrEqual(player.stopCount, 1)
        XCTAssertGreaterThanOrEqual(fallback.stopCount, 1)
        session.invalidateAndCancel()
    }

    /// Yields until the stub has seen a request (bounded).
    private func waitForRequest() async {
        for _ in 0..<2_000 where AIStubURLProtocol.requests.isEmpty {
            await Task.yield()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { continuation.resume() }
            }
        }
        XCTAssertFalse(AIStubURLProtocol.requests.isEmpty)
    }
}

/// Fake microphone: `push` delivers a chunk as the real tap would. Thread safety: `lock`.
final class AIFakeAudioCapture: VoiceAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable ([Float]) -> Void)?
    private var starts = 0
    private var stops = 0
    private var opensValue = true

    var opens: Bool {
        get { lock.lock(); defer { lock.unlock() }; return opensValue }
        set { lock.lock(); opensValue = newValue; lock.unlock() }
    }

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }

    func start(onChunk: @escaping @Sendable ([Float]) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        starts += 1
        guard opensValue else { return false }
        sink = onChunk
        return true
    }

    func stop() {
        lock.lock(); stops += 1; sink = nil; lock.unlock()
    }

    func push(_ chunk: [Float]) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?(chunk)
    }
}

/// Fake player with a fixed outcome. Thread safety: `lock`.
final class AIFakePlayer: VoiceAudioPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: VoicePlaybackOutcome
    private var data: [Data] = []
    private var stops = 0

    init(outcome: VoicePlaybackOutcome) {
        self.outcome = outcome
    }

    var played: [Data] { lock.lock(); defer { lock.unlock() }; return data }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }

    func play(_ data: Data) async -> VoicePlaybackOutcome {
        record(data)
        return outcome
    }

    func stop() {
        lock.lock(); stops += 1; lock.unlock()
    }

    private func record(_ clip: Data) {
        lock.lock()
        if outcome != .failed { data.append(clip) }
        lock.unlock()
    }
}
