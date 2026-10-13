import XCTest
@testable import DesnotchCore

final class VoiceAIWireTests: XCTestCase {
    private let base = URL(string: "https://api.example.test/v1")!

    // MARK: WAV encoder

    func testWAVHeaderIsCanonicalPCM16Mono() throws {
        let samples: [Int16] = [0, 1, -1, Int16.max, Int16.min]
        let wav = WAVEncoder.encode(samples, sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(readUInt32(wav, 4), UInt32(36 + samples.count * 2))
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(readUInt32(wav, 16), 16)
        XCTAssertEqual(readUInt16(wav, 20), 1)
        XCTAssertEqual(readUInt16(wav, 22), 1)
        XCTAssertEqual(readUInt32(wav, 24), 16_000)
        XCTAssertEqual(readUInt32(wav, 28), 32_000)
        XCTAssertEqual(readUInt16(wav, 32), 2)
        XCTAssertEqual(readUInt16(wav, 34), 16)
        XCTAssertEqual(String(data: wav.subdata(in: 36..<40), encoding: .ascii), "data")
        XCTAssertEqual(readUInt32(wav, 40), UInt32(samples.count * 2))
        let decoded = (0..<samples.count).map { Int16(bitPattern: readUInt16(wav, 44 + $0 * 2)) }
        XCTAssertEqual(decoded, samples)
    }

    func testPCM16ClampsAndScales() {
        XCTAssertEqual(WAVEncoder.pcm16([0, 1, -1, 2, -2, 0.5, .nan]), [0, 32_767, -32_767, 32_767, -32_767, 16_384, 0])
    }

    func testEmptyWAVIsJustTheHeader() {
        let wav = WAVEncoder.encode([], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44)
        XCTAssertEqual(readUInt32(wav, 40), 0)
    }

    // MARK: Request shapes

    func testTranscriptionRequestShape() throws {
        let wav = WAVEncoder.encode([1, 2, 3], sampleRate: 16_000)
        let request = OpenAIAudioWire.transcription(
            base: base, key: "sk-test", model: "gpt-4o-mini-transcribe", language: "id", wav: wav, boundary: "B0UND"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B0UND")
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav"))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nid\r\n"))
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        XCTAssertTrue(text.hasSuffix("--B0UND--\r\n"))
        XCTAssertNotNil(body.range(of: wav))
        XCTAssertFalse(text.contains("Interseptor"), "the on-device hint list is never sent")
    }

    func testTranscriptionOmitsLanguageForAutoDetectAndKeyForLocalServer() throws {
        let local = URL(string: "http://localhost:8080/v1")!
        let request = OpenAIAudioWire.transcription(
            base: local, key: nil, model: "whisper-1", language: "", wav: Data(), boundary: "B"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let text = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"language\""))
    }

    func testSpeechRequestShape() throws {
        let request = OpenAIAudioWire.speech(base: base, key: "sk-test", model: "gpt-4o-mini-tts", voice: "alloy", input: "Halo")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/audio/speech")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = AITestJSON.object(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(body["voice"] as? String, "alloy")
        XCTAssertEqual(body["input"] as? String, "Halo")
        XCTAssertEqual(body["response_format"] as? String, "mp3")
    }

    func testTranscriptTextParsing() {
        XCTAssertEqual(OpenAIAudioWire.transcriptText(Data(#"{"text":"buka safari"}"#.utf8)), "buka safari")
        XCTAssertNil(OpenAIAudioWire.transcriptText(Data(#"{"nope":1}"#.utf8)))
        XCTAssertNil(OpenAIAudioWire.transcriptText(Data("not json".utf8)))
    }

    // MARK: Endpoint rule

    func testHTTPSIsRequiredExceptForThisMac() {
        XCTAssertNotNil(try? VoiceAIEndpoint.validate("https://api.openai.com/v1").get())
        XCTAssertNotNil(try? VoiceAIEndpoint.validate("https://openrouter.ai/api/v1").get())
        XCTAssertNotNil(try? VoiceAIEndpoint.validate("http://localhost:1234/v1").get())
        XCTAssertNotNil(try? VoiceAIEndpoint.validate("http://127.0.0.1:11434/v1").get())
        XCTAssertNotNil(try? VoiceAIEndpoint.validate("http://[::1]:8080/v1").get())
        for bad in [
            "http://api.openai.com/v1", "http://192.168.1.5:1234/v1", "http://localhost.example.com/v1",
            "ftp://localhost/v1", "api.openai.com/v1", "", "https://user:pass@api.openai.com/v1",
            "https://api.openai.com/v1?x=1", "https://api.openai.com/v1#frag", "file:///etc/passwd"
        ] {
            XCTAssertEqual(failure(of: VoiceAIEndpoint.validate(bad)), .endpointInvalid, bad)
        }
    }

    func testReadinessNeedsAKeyOnlyForRemoteEndpoints() {
        let empty = AIMemoryKeyStore()
        XCTAssertEqual(VoiceAIReadiness.check(base: "https://api.openai.com/v1", keys: empty), .keyMissing)
        XCTAssertNil(VoiceAIReadiness.check(base: "http://localhost:1234/v1", keys: empty))
        XCTAssertEqual(VoiceAIReadiness.check(base: "http://example.com/v1", keys: AIMemoryKeyStore("k")), .endpointInvalid)
        XCTAssertNil(VoiceAIReadiness.check(base: "https://api.openai.com/v1", keys: AIMemoryKeyStore("k", base: "https://api.openai.com/v1")))
        XCTAssertEqual(empty.readCount, 0, "the preflight check never reads the secret")
    }

    // MARK: Key format and reply shaping

    func testKeyFormatRejectsWhitespaceAndControlCharacters() {
        XCTAssertEqual(VoiceAIKeyFormat.normalized("  sk-abc123 \n"), "sk-abc123")
        XCTAssertNil(VoiceAIKeyFormat.normalized(""))
        XCTAssertNil(VoiceAIKeyFormat.normalized("sk abc"))
        XCTAssertNil(VoiceAIKeyFormat.normalized("sk-abc\r\nX-Evil: 1"))
        XCTAssertNil(VoiceAIKeyFormat.normalized(String(repeating: "a", count: VoiceAIKeyFormat.maxLength + 1)))
    }

    func testReplyShaperStripsMarkdownAndBoundsToTheReplyCap() {
        XCTAssertEqual(VoiceAIReplyShaper.shape("**Halo!**\n\n# Cuaca\n- cerah `hari ini`"), "Halo! Cuaca - cerah hari ini")
        let long = String(repeating: "Kalimat pendek. ", count: 60)
        let shaped = VoiceAIReplyShaper.shape(long)
        XCTAssertLessThanOrEqual(shaped.count, VoiceLimits.maxReplyCharacters)
        XCTAssertTrue(shaped.hasSuffix("."))
        let noStops = String(repeating: "kata ", count: 200)
        let cut = VoiceAIReplyShaper.shape(noStops)
        XCTAssertLessThanOrEqual(cut.count, VoiceLimits.maxReplyCharacters)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    // MARK: HTTP error mapping

    func testStatusAndErrorMapping() {
        XCTAssertEqual(VoiceAIHTTP.classify(status: 401), .unauthorized)
        XCTAssertEqual(VoiceAIHTTP.classify(status: 403), .unauthorized)
        XCTAssertEqual(VoiceAIHTTP.classify(status: 404), .notFound)
        XCTAssertEqual(VoiceAIHTTP.classify(status: 413), .audioTooLarge)
        XCTAssertEqual(VoiceAIHTTP.classify(status: 429), .rateLimited)
        XCTAssertEqual(VoiceAIHTTP.classify(status: 500), .httpError)
        XCTAssertEqual(VoiceAIHTTP.classify(URLError(.timedOut)), .failed(.timeout))
        XCTAssertEqual(VoiceAIHTTP.classify(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(VoiceAIHTTP.classify(URLError(.cannotFindHost)), .failed(.network))
        XCTAssertEqual(VoiceAIHTTP.classify(CancellationError()), .cancelled)
    }

    func testFailureCodesCarryNoPayload() {
        for failure in ProviderFailure.allCases {
            XCTAssertEqual(VoiceFailure.provider(failure).code, "provider.\(failure.rawValue)")
            XCTAssertFalse(VoiceFailure.provider(failure).userMessage.isEmpty)
        }
        XCTAssertEqual(VoiceFailure.preflightRefused(.providerKeyMissing).userMessage, "AI provider isn't set up")
    }

    func testSessionIsEphemeralAndStoresNothing() {
        let session = VoiceAIHTTP.makeSession()
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        session.invalidateAndCancel()
    }

    func testRedirectsAreRefused() async {
        AIStubURLProtocol.reset([
            .respond(status: 302, body: Data(), headers: ["Location": "https://evil.example.test/steal"])
        ])
        let session = AIStubURLProtocol.session()
        let request = OpenAIAudioWire.models(base: base, key: "sk-test")
        let response = await VoiceAIHTTP.send(request, session: session, maxBytes: 1_000)
        if case .status(let status, _) = response {
            XCTAssertEqual(status, 302)
        } else {
            XCTFail("expected the 302 to be reported, got \(response)")
        }
        XCTAssertEqual(AIStubURLProtocol.requests.count, 1)
        XCTAssertEqual(AIStubURLProtocol.requests.first?.url?.host, "api.example.test")
        session.invalidateAndCancel()
    }

    func testOversizedBodyIsRejected() async {
        AIStubURLProtocol.reset([.respond(status: 200, body: Data(count: 2_000), headers: [:])])
        let session = AIStubURLProtocol.session()
        let response = await VoiceAIHTTP.send(OpenAIAudioWire.models(base: base, key: nil), session: session, maxBytes: 1_000)
        XCTAssertEqual(response, .failed(.badResponse))
        session.invalidateAndCancel()
    }

    func testConnectionTesterReportsCategoryOnly() async {
        let session = AIStubURLProtocol.session()
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, ["data": []])])
        let ok = await VoiceAIConnectionTester.test(
            .openAICompatible, config: VoiceAIConfig(baseURL: base.absoluteString), keys: AIMemoryKeyStore("sk-test"), session: session
        )
        XCTAssertEqual(ok, .ok)
        XCTAssertEqual(AIStubURLProtocol.requests.first?.url?.absoluteString, "https://api.example.test/v1/models")
        XCTAssertEqual(AIStubURLProtocol.requests.first?.httpMethod, "GET")
        AIStubURLProtocol.reset([AIStubURLProtocol.json(401, ["error": ["message": "Incorrect API key sk-test"]])])
        let denied = await VoiceAIConnectionTester.test(
            .openAICompatible, config: VoiceAIConfig(baseURL: base.absoluteString), keys: AIMemoryKeyStore("sk-test"), session: session
        )
        XCTAssertEqual(denied, .failed(.unauthorized))
        XCTAssertEqual(VoiceAIConnectionTester.message(denied), "AI provider rejected the key")
        XCTAssertFalse(VoiceAIConnectionTester.message(denied).contains("sk-test"))
        let missing = await VoiceAIConnectionTester.test(
            .anthropic, config: VoiceAIConfig(), keys: AIMemoryKeyStore(), session: session
        )
        XCTAssertEqual(missing, .failed(.keyMissing))
        session.invalidateAndCancel()
    }

    func testAnthropicConnectionTestUsesItsOwnHeaders() async throws {
        let session = AIStubURLProtocol.session()
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, ["data": []])])
        let result = await VoiceAIConnectionTester.test(
            .anthropic, config: VoiceAIConfig(), keys: AIMemoryKeyStore.anthropic("ant-key"), session: session
        )
        XCTAssertEqual(result, .ok)
        let request = try XCTUnwrap(AIStubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "ant-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        session.invalidateAndCancel()
    }

    private func failure(of result: Result<URL, ProviderFailure>) -> ProviderFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let bytes = [UInt8](data.subdata(in: offset..<(offset + 2)))
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }
}
