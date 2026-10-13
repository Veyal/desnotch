import XCTest
@testable import DesnotchCore

final class VoiceChatBackendTests: XCTestCase {
    private let base = "https://api.example.test/v1"

    private func liveBackend(
        _ kind: VoiceChatProviderKind = .openAICompatible,
        openAIKey: String? = "sk-test",
        anthropicKey: String? = "ant-key",
        session: URLSession
    ) -> VoiceChatBackend {
        let config = VoiceAIConfigBox(VoiceAIConfig(chatProvider: kind, baseURL: base))
        return VoiceChatBackend(config: config, providers: [
            OpenAIChatProvider(keys: AIMemoryKeyStore(openAIKey), session: session),
            AnthropicChatProvider(keys: AIMemoryKeyStore.anthropic(anthropicKey), session: session)
        ])
    }

    func testPreflightMapsProviderReadiness() async {
        let session = AIStubURLProtocol.session()
        let ready = await liveBackend(session: session).preflight()
        XCTAssertEqual(ready, .ready(profile: "openAICompatible"))
        let claude = await liveBackend(.anthropic, session: session).preflight()
        XCTAssertEqual(claude, .ready(profile: "anthropic"))
        let noKey = await liveBackend(openAIKey: nil, session: session).preflight()
        XCTAssertEqual(noKey, .refused(.providerKeyMissing))
        let insecure = VoiceChatBackend(
            config: VoiceAIConfigBox(VoiceAIConfig(baseURL: "http://example.com/v1")),
            providers: [OpenAIChatProvider(keys: AIMemoryKeyStore("k"), session: session)]
        )
        let refused = await insecure.preflight()
        XCTAssertEqual(refused, .refused(.providerEndpointInvalid))
        session.invalidateAndCancel()
    }

    func testOpenAITurnEmitsStartedUsageAndABoundedReply() async throws {
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, [
            "choices": [["finish_reason": "stop", "message": ["content": "**Cerah** di Jakarta."]]],
            "usage": ["prompt_tokens": 12, "completion_tokens": 7]
        ])])
        let session = AIStubURLProtocol.session()
        let events = await collect(liveBackend(session: session).submit("cuaca jakarta?"))
        XCTAssertEqual(events, [
            .status("started"),
            .usage(inputTokens: 12, outputTokens: 7, costMicros: 0),
            .finished(summary: "Cerah di Jakarta.")
        ])
        let body = AITestJSON.object(try XCTUnwrap(AIStubURLProtocol.requestBodies.first))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, VoiceChatBackend.systemPrompt)
        XCTAssertEqual(messages.last?["content"] as? String, "cuaca jakarta?")
        XCTAssertNil(body["tools"])
        XCTAssertLessThanOrEqual(VoiceChatBackend.systemPrompt.count, 400)
        session.invalidateAndCancel()
    }

    func testAnthropicIsUsedWhenSelected() async throws {
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, [
            "content": [["type": "text", "text": "Halo!"]], "stop_reason": "end_turn",
            "usage": ["input_tokens": 3, "output_tokens": 2]
        ])])
        let session = AIStubURLProtocol.session()
        let events = await collect(liveBackend(.anthropic, session: session).submit("halo"))
        XCTAssertEqual(events.last, .finished(summary: "Halo!"))
        let request = try XCTUnwrap(AIStubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        let body = AITestJSON.object(try XCTUnwrap(AIStubURLProtocol.requestBodies.first))
        XCTAssertEqual(body["system"] as? String, VoiceChatBackend.systemPrompt)
        XCTAssertEqual(body["model"] as? String, VoiceAIDefaults.anthropicModel)
        session.invalidateAndCancel()
    }

    func testMissingKeyRefusesWithoutSendingOrCounting() async {
        AIStubURLProtocol.reset([])
        let session = AIStubURLProtocol.session()
        let events = await collect(liveBackend(openAIKey: nil, session: session).submit("hi"))
        XCTAssertEqual(events, [.failed(.preflightRefused(.providerKeyMissing))])
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty)
        session.invalidateAndCancel()
    }

    func testHTTPErrorBecomesAProviderFailure() async {
        AIStubURLProtocol.reset([AIStubURLProtocol.json(401, ["error": ["message": "Incorrect API key provided: sk-test"]])])
        let session = AIStubURLProtocol.session()
        let events = await collect(liveBackend(session: session).submit("hi"))
        XCTAssertEqual(events, [.status("started"), .failed(.provider(.unauthorized))])
        session.invalidateAndCancel()
    }

    func testEmptyAnswerIsAFailureNotASilentReply() async {
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, ["choices": [["message": ["content": "  "]]]])])
        let session = AIStubURLProtocol.session()
        let events = await collect(liveBackend(session: session).submit("hi"))
        XCTAssertEqual(events.last, .failed(.provider(.badResponse)))
        session.invalidateAndCancel()
    }

    func testCancelTurnCancelsTheRequest() async {
        AIStubURLProtocol.reset([.hang])
        let session = AIStubURLProtocol.session()
        let backend = liveBackend(session: session)
        let stream = backend.submit("long question")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .status("started"))
        await backend.cancelTurn()
        var rest: [AgentEvent] = []
        while let event = await iterator.next() { rest.append(event) }
        XCTAssertEqual(rest, [.failed(.agentFailed("cancelled"))])
        let report = await backend.emergencyStop()
        XCTAssertEqual(report, EmergencyStopReport())
        session.invalidateAndCancel()
    }

    func testToolHandlerIsIgnoredWhileTheSettingIsOff() async {
        let provider = AIScriptedChatProvider([
            .response(ChatResponse(
                content: [.text("I can only answer."), .toolUse(id: "t1", name: "weather", inputJSON: "{}")],
                stopReason: .toolUse, inputTokens: 0, outputTokens: 0
            ))
        ])
        let tools = AIRecordingToolHandler()
        let backend = VoiceChatBackend(config: VoiceAIConfigBox(), providers: [provider], toolHandler: tools)
        let events = await collect(backend.submit("do it"))
        XCTAssertEqual(events, [.status("started"), .finished(summary: "I can only answer.")])
        XCTAssertEqual(provider.requests.first?.tools, [])
        XCTAssertEqual(provider.requests.first?.system, VoiceChatBackend.systemPrompt)
        XCTAssertTrue(tools.calls.isEmpty)
    }

    func testWithoutAToolHandlerNoToolIsOfferedAndToolCallsAreIgnored() async {
        let provider = AIScriptedChatProvider([
            .response(ChatResponse(
                content: [.text("Sure."), .toolUse(id: "t1", name: "shell", inputJSON: "{}")],
                stopReason: .toolUse, inputTokens: 0, outputTokens: 0
            ))
        ])
        let backend = VoiceChatBackend(config: VoiceAIConfigBox(), providers: [provider])
        let events = await collect(backend.submit("do it"))
        XCTAssertEqual(events, [.status("started"), .finished(summary: "Sure.")])
        XCTAssertEqual(provider.requests.first?.tools, [])
        XCTAssertFalse(events.contains { if case .toolActivity = $0 { return true }; return false })
    }

    func testToolHookRunsTheMultiTurnLoop() async throws {
        let provider = AIScriptedChatProvider([
            .response(ChatResponse(
                content: [.toolUse(id: "t1", name: "weather", inputJSON: #"{"city":"Jakarta"}"#)],
                stopReason: .toolUse, inputTokens: 5, outputTokens: 4
            )),
            .response(ChatResponse(content: [.text("31 degrees.")], stopReason: .endTurn, inputTokens: 9, outputTokens: 3))
        ])
        let tools = AIRecordingToolHandler()
        let backend = VoiceChatBackend(
            config: VoiceAIConfigBox(VoiceAIConfig(agentToolsEnabled: true)), providers: [provider], toolHandler: tools
        )
        let events = await collect(backend.submit("weather?"))
        XCTAssertEqual(events, [
            .status("started"),
            .usage(inputTokens: 5, outputTokens: 4, costMicros: 0),
            .toolActivity(kind: "weather"),
            .usage(inputTokens: 9, outputTokens: 3, costMicros: 0),
            .finished(summary: "31 degrees.")
        ])
        XCTAssertEqual(tools.calls, [#"weather {"city":"Jakarta"}"#])
        let second = try XCTUnwrap(provider.requests.last)
        XCTAssertEqual(second.tools.map(\.name), ["weather"])
        XCTAssertEqual(second.messages.count, 3)
        XCTAssertEqual(second.messages[1].role, .assistant)
        XCTAssertEqual(second.messages[2], ChatMessage(role: .user, content: [
            .toolResult(toolUseID: "t1", content: AgentToolOutput.wrap(tool: "weather", "31C"), isError: false)
        ]))
    }

    func testToolLoopIsBounded() async {
        let call = ChatResult.response(ChatResponse(
            content: [.toolUse(id: "t", name: "weather", inputJSON: "{}")], stopReason: .toolUse, inputTokens: 0, outputTokens: 0
        ))
        let provider = AIScriptedChatProvider(Array(repeating: call, count: VoiceChatBackend.maxToolRounds + 3))
        let backend = VoiceChatBackend(
            config: VoiceAIConfigBox(VoiceAIConfig(agentToolsEnabled: true)), providers: [provider],
            toolHandler: AIRecordingToolHandler()
        )
        let events = await collect(backend.submit("loop"))
        XCTAssertEqual(events.last, .failed(.stepBudgetExceeded))
        XCTAssertEqual(provider.requests.count, VoiceChatBackend.maxToolRounds + 1)
    }
}

/// Scripted `ChatProvider` (always ready). Thread safety: guarded by `lock`.
final class AIScriptedChatProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ChatResult]
    private var recorded: [ChatRequest] = []

    init(_ script: [ChatResult]) {
        self.script = script
    }

    var kind: VoiceChatProviderKind { .openAICompatible }
    var requests: [ChatRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func readiness(_ config: VoiceAIConfig) -> ProviderFailure? { nil }

    func complete(_ request: ChatRequest, config: VoiceAIConfig) async -> ChatResult {
        next(request)
    }

    private func next(_ request: ChatRequest) -> ChatResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return script.isEmpty ? .failed(.httpError) : script.removeFirst()
    }
}

/// Records tool calls and answers "31C". Thread safety: guarded by `lock`.
final class AIRecordingToolHandler: ChatToolHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    var tools: [ChatToolDefinition] {
        [ChatToolDefinition(name: "weather", description: "Weather", inputSchemaJSON: #"{"type":"object"}"#)]
    }

    func propose(name: String, inputJSON: String, context: ChatToolCallContext) async -> ChatToolProposal {
        ChatToolProposal(tier: .t0, stepLabel: name, summary: "Weather", auditCode: "tool.\(name)")
    }

    func revealsData(name: String) -> Bool { false }

    func run(name: String, inputJSON: String, approvedTier: VoiceTier, context: ChatToolCallContext) async -> ChatToolOutcome {
        record("\(name) \(inputJSON)")
        return ChatToolOutcome(content: "31C", isError: false)
    }

    private func record(_ call: String) {
        lock.lock(); recorded.append(call); lock.unlock()
    }
}
