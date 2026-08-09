import XCTest
@testable import DesnotchCore

final class SpeechFoundationTests: XCTestCase {
    private final class Transport: SpeechHTTPTransport {
        var responses: [(Data, URLResponse)] = []
        var errors: [Error] = []
        var requests: [URLRequest] = []
        var requestedMaxBytes: Int?
        func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
            requests.append(request)
            requestedMaxBytes = maxBytes
            if !errors.isEmpty { throw errors.removeFirst() }
            return responses.removeFirst()
        }
    }
    private final class Recorder: SpeechRecording {
        var isRecording = false
        var onAutoStop: (() -> Void)?
        func start() async throws { isRecording = true }
        func stop() async throws -> URL { isRecording = false; return URL(fileURLWithPath: "/tmp/test.wav") }
        func cancel() { isRecording = false }
        func triggerAutoStop() { isRecording = false; onAutoStop?() }
    }
    private final class Paster: AccessibilityPasting {
        var isTrusted = true; var values: [String] = []
        func requestTrust() -> Bool { true }
        func paste(_ text: String) -> Bool { values.append(text); return true }
    }

    func testMultipartContainsFileModelAndJSONFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let body = try SpeechTranscriptionClient.multipartBody(fileURL: url, model: "test-model", boundary: "abc")
        let string = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(string.contains("name=\"model\"")); XCTAssertTrue(string.contains("test-model"))
        XCTAssertTrue(string.contains("name=\"response_format\"")); XCTAssertTrue(string.contains("json"))
        XCTAssertTrue(string.contains("filename=\"audio.wav\"")); XCTAssertTrue(body.suffix(12).contains(0x03))
    }

    func testMultipartRejectsModelHeaderInjection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(
            try SpeechTranscriptionClient.multipartBody(fileURL: url, model: "safe\r\ninjected", boundary: "abc")
        ) { error in
            XCTAssertEqual(error as? SpeechTranscriptionError, .invalidModel)
        }
    }

    func testProviderRootAndV1BaseResolveToSameEndpoint() {
        XCTAssertEqual(
            SpeechTranscriptionClient.transcriptionURL(baseURL: URL(string: "https://example.com")!).absoluteString,
            "https://example.com/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            SpeechTranscriptionClient.transcriptionURL(baseURL: URL(string: "https://example.com/v1")!).absoluteString,
            "https://example.com/v1/audio/transcriptions"
        )
    }

    func testProviderURLRequiresTLSUnlessLoopbackAndRejectsCredentialsOrQuery() {
        XCTAssertTrue(SpeechTranscriptionClient.isAllowedProviderURL(URL(string: "https://provider.example/v1")!))
        XCTAssertTrue(SpeechTranscriptionClient.isAllowedProviderURL(URL(string: "http://localhost:8080")!))
        XCTAssertFalse(SpeechTranscriptionClient.isAllowedProviderURL(URL(string: "http://provider.example")!))
        XCTAssertFalse(SpeechTranscriptionClient.isAllowedProviderURL(URL(string: "https://user:pass@provider.example")!))
        XCTAssertFalse(SpeechTranscriptionClient.isAllowedProviderURL(URL(string: "https://provider.example?key=secret")!))
    }

    func testOversizedTranscriptIsRejectedBeforeControllerPaste() async throws {
        let recorder = Recorder(); let paster = Paster()
        let controller = await MainActor.run {
            DictationController(recorder: recorder, transcriber: StubTranscriber(value: String(repeating: "x", count: SpeechTranscriptionClient.maxTranscriptBytes + 1)), paster: paster)
        }
        await MainActor.run { controller.start() }
        try await waitUntil { controller.state == .recording(.dictate) }
        await MainActor.run { controller.stop() }
        try await waitUntil { if case .error = controller.state { return true }; return false }
        await MainActor.run { XCTAssertTrue(paster.values.isEmpty); if case .error = controller.state {} else { XCTFail("expected error") } }
    }

    func testTranscriptionParsesJSONAndRetriesTransientHTTPFailure() async throws {
        let transport = Transport(); let endpoint = URL(string: "https://example.com")!
        transport.responses = [
            (Data("{}".utf8), HTTPURLResponse(url: endpoint, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data("{\"text\":\"hello\"}".utf8), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        ]
        let client = SpeechTranscriptionClient(baseURL: endpoint, apiKey: { "secret" }, transport: transport)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let transcript = try await client.transcribe(fileURL: file)
        XCTAssertEqual(transcript, "hello")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requestedMaxBytes, SpeechTranscriptionClient.maxResponseBytes)
    }

    func testTranscriptionFailureDoesNotRetryPermanentStatus() async throws {
        let transport = Transport(); let endpoint = URL(string: "https://example.com")!
        transport.responses = [(Data(), HTTPURLResponse(url: endpoint, statusCode: 400, httpVersion: nil, headerFields: nil)!)]
        let client = SpeechTranscriptionClient(baseURL: endpoint, apiKey: { "secret" }, transport: transport)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        do { _ = try await client.transcribe(fileURL: file); XCTFail("expected error") } catch let error as SpeechTranscriptionError { XCTAssertEqual(error, .httpStatus(400)) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testTranscriptionRequiresAPIKeyBeforeNetworkRequest() async throws {
        let transport = Transport()
        let client = SpeechTranscriptionClient(apiKey: { nil }, transport: transport)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await client.transcribe(fileURL: file)
            XCTFail("expected missing key")
        } catch let error as SpeechTranscriptionError {
            XCTAssertEqual(error, .missingAPIKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMalformedResponseFails() {
        XCTAssertThrowsError(try SpeechTranscriptionClient.text(from: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? SpeechTranscriptionError, .malformedResponse)
        }
    }

    func testCancelledTranscriptionDoesNotRetry() async throws {
        final class SlowTransport: SpeechHTTPTransport {
            func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return (
                    Data(),
                    URLResponse(
                        url: URL(string: "https://example.com")!,
                        mimeType: nil,
                        expectedContentLength: 0,
                        textEncodingName: nil
                    )
                )
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let client = SpeechTranscriptionClient(apiKey: { "secret" }, transport: SlowTransport())
        let task = Task { try await client.transcribe(fileURL: file) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    @MainActor func testControllerTransitionsToSuccessAndCanCancel() async throws {
        let recorder = Recorder(); let paster = Paster(); let client = StubTranscriber()
        let controller = DictationController(recorder: recorder, transcriber: client, paster: paster)
        controller.start(); try await waitUntil { controller.state == .recording(.dictate) }
        controller.stop(); try await waitUntil { controller.state == .success(.dictate, "dictated") }
        XCTAssertEqual(paster.values, ["dictated"])
        controller.start(); controller.cancel(); XCTAssertEqual(controller.state, .idle)
    }

    @MainActor func testRecorderAutoStopContinuesIntoTranscription() async throws {
        let recorder = Recorder(); let paster = Paster()
        let controller = DictationController(recorder: recorder, transcriber: StubTranscriber(), paster: paster)
        controller.start()
        try await waitUntil { controller.state == .recording(.dictate) }
        recorder.triggerAutoStop()
        try await waitUntil { controller.state == .success(.dictate, "dictated") }
        XCTAssertEqual(paster.values, ["dictated"])
    }

    @MainActor func testTalkToAgentPublishesTranscriptWithoutPasting() async throws {
        let recorder = Recorder(); let paster = Paster(); let client = StubTranscriber()
        let controller = DictationController(recorder: recorder, transcriber: client, paster: paster)
        var received: String?
        controller.onTranscript = { mode, text in
            XCTAssertEqual(mode, .talkToAgent)
            received = text
        }
        controller.start(mode: .talkToAgent)
        try await waitUntil { controller.state == .recording(.talkToAgent) }
        controller.stop()
        try await waitUntil { controller.state == .success(.talkToAgent, "dictated") }
        XCTAssertEqual(received, "dictated")
        XCTAssertTrue(paster.values.isEmpty)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
    private final class StubTranscriber: SpeechTranscribing {
        let value: String
        init(value: String = "dictated") { self.value = value }
        func transcribe(fileURL: URL) async throws -> String { value }
    }
}
