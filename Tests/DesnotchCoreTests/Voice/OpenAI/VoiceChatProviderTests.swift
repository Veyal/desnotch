import XCTest
@testable import DesnotchCore

final class VoiceChatProviderTests: XCTestCase {
    private let openAIBase = URL(string: "https://api.example.test/v1")!
    private let anthropicBase = URL(string: "https://api.anthropic.com")!

    private func plainRequest(tools: [ChatToolDefinition] = []) -> ChatRequest {
        ChatRequest(system: "Be brief.", messages: [.user("cuaca hari ini?")], tools: tools, maxTokens: 200)
    }

    private let weatherTool = ChatToolDefinition(
        name: "weather", description: "Weather now", inputSchemaJSON: #"{"type":"object","properties":{"city":{"type":"string"}}}"#
    )

    // MARK: OpenAI-compatible wire format

    func testOpenAIRequestShapeWithoutTools() throws {
        let request = OpenAIChatProvider.urlRequest(plainRequest(), base: openAIBase, key: "sk-test", model: "gpt-4o-mini")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = AITestJSON.object(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(body["max_tokens"] as? Int, 200)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["tools"], "no tool is offered when the hook is nil")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Be brief.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "cuaca hari ini?")
    }

    func testOpenAIToolRoundTripWireFormat() throws {
        var request = plainRequest(tools: [weatherTool])
        request.messages.append(ChatMessage(role: .assistant, content: [
            .text("Checking."), .toolUse(id: "call_1", name: "weather", inputJSON: #"{"city":"Jakarta"}"#)
        ]))
        request.messages.append(ChatMessage(role: .user, content: [
            .toolResult(toolUseID: "call_1", content: "31C sunny", isError: false)
        ]))
        let body = OpenAIChatProvider.body(request, model: "m", useCompletionTokens: true)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 200)
        XCTAssertNil(body["max_tokens"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "weather")
        XCTAssertEqual((function["parameters"] as? [String: Any])?["type"] as? String, "object")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual(messages[2]["content"] as? String, "Checking.")
        let calls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_1")
        let callFunction = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(callFunction["name"] as? String, "weather")
        XCTAssertEqual(callFunction["arguments"] as? String, #"{"city":"Jakarta"}"#)
        XCTAssertEqual(messages[3]["role"] as? String, "tool")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages[3]["content"] as? String, "31C sunny")
    }

    func testOpenAIDecodesTextToolCallsAndUsage() throws {
        let json = """
        {"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
        "tool_calls":[{"id":"call_9","type":"function","function":{"name":"weather","arguments":"{\\"city\\":\\"Bandung\\"}"}}]}}],
        "usage":{"prompt_tokens":12,"completion_tokens":7}}
        """
        let response = try XCTUnwrap(OpenAIChatProvider.decode(Data(json.utf8)))
        XCTAssertEqual(response.stopReason, .toolUse)
        XCTAssertEqual(response.content, [.toolUse(id: "call_9", name: "weather", inputJSON: #"{"city":"Bandung"}"#)])
        XCTAssertEqual(response.inputTokens, 12)
        XCTAssertEqual(response.outputTokens, 7)
        let text = try XCTUnwrap(OpenAIChatProvider.decode(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Cerah."}}]}"#.utf8)))
        XCTAssertEqual(text.text, "Cerah.")
        XCTAssertEqual(text.stopReason, .endTurn)
        XCTAssertNil(OpenAIChatProvider.decode(Data(#"{"error":{"message":"x"}}"#.utf8)))
    }

    func testOpenAIRetriesOnceWithMaxCompletionTokens() async throws {
        AIStubURLProtocol.reset([
            AIStubURLProtocol.json(400, ["error": ["param": "max_tokens", "message": "Use 'max_completion_tokens' instead."]]),
            AIStubURLProtocol.json(200, ["choices": [["finish_reason": "stop", "message": ["content": "Halo."]]]])
        ])
        let session = AIStubURLProtocol.session()
        let provider = OpenAIChatProvider(keys: AIMemoryKeyStore("sk-test"), session: session)
        let result = await provider.complete(plainRequest(), config: VoiceAIConfig(baseURL: openAIBase.absoluteString))
        guard case .response(let response) = result else { return XCTFail("expected a response, got \(result)") }
        XCTAssertEqual(response.text, "Halo.")
        let bodies = AIStubURLProtocol.requestBodies.map(AITestJSON.object)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotNil(bodies[0]["max_tokens"])
        XCTAssertNotNil(bodies[1]["max_completion_tokens"])
        XCTAssertNil(bodies[1]["max_tokens"])
        session.invalidateAndCancel()
    }

    func testOpenAIErrorMapping() async {
        let session = AIStubURLProtocol.session()
        let provider = OpenAIChatProvider(keys: AIMemoryKeyStore("sk-test"), session: session)
        let config = VoiceAIConfig(baseURL: openAIBase.absoluteString)
        let cases: [(AIStubURLProtocol.Reply, ChatResult)] = [
            (AIStubURLProtocol.json(401, ["error": ["message": "bad key"]]), .failed(.unauthorized)),
            (AIStubURLProtocol.json(404, [:]), .failed(.notFound)),
            (AIStubURLProtocol.json(429, [:]), .failed(.rateLimited)),
            (AIStubURLProtocol.json(500, [:]), .failed(.httpError)),
            (.fail(.timedOut), .failed(.timeout)),
            (.fail(.cannotConnectToHost), .failed(.network)),
            (.respond(status: 200, body: Data("<html>".utf8), headers: [:]), .failed(.badResponse))
        ]
        for (reply, expected) in cases {
            AIStubURLProtocol.reset([reply])
            let result = await provider.complete(plainRequest(), config: config)
            XCTAssertEqual(result, expected)
        }
        session.invalidateAndCancel()
    }

    func testOpenAIRefusesWithoutKeyOrOverPlainHTTP() async {
        AIStubURLProtocol.reset([])
        let session = AIStubURLProtocol.session()
        let noKey = OpenAIChatProvider(keys: AIMemoryKeyStore(), session: session)
        let missing = await noKey.complete(plainRequest(), config: VoiceAIConfig())
        XCTAssertEqual(missing, .failed(.keyMissing))
        let keyed = OpenAIChatProvider(keys: AIMemoryKeyStore("sk-test"), session: session)
        let insecure = await keyed.complete(plainRequest(), config: VoiceAIConfig(baseURL: "http://api.openai.com/v1"))
        XCTAssertEqual(insecure, .failed(.endpointInvalid))
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty, "nothing is sent when the provider is not set up")
        session.invalidateAndCancel()
    }

    // MARK: Anthropic wire format

    func testAnthropicRequestShape() throws {
        let request = AnthropicChatProvider.urlRequest(plainRequest(), base: anthropicBase, key: "ant-key", model: "claude-haiku-4-5")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "ant-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = AITestJSON.object(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 200)
        XCTAssertEqual(body["system"] as? String, "Be brief.")
        XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "the system prompt is a top-level field, not a message")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "cuaca hari ini?")
    }

    func testAnthropicToolRoundTripWireFormat() throws {
        var request = plainRequest(tools: [weatherTool])
        request.messages.append(ChatMessage(role: .assistant, content: [
            .toolUse(id: "toolu_1", name: "weather", inputJSON: #"{"city":"Jakarta"}"#)
        ]))
        request.messages.append(ChatMessage(role: .user, content: [
            .toolResult(toolUseID: "toolu_1", content: "failed", isError: true)
        ]))
        let body = AnthropicChatProvider.body(request, model: "m")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "weather")
        XCTAssertEqual((tools.first?["input_schema"] as? [String: Any])?["type"] as? String, "object")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let use = try XCTUnwrap((messages[1]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(use["type"] as? String, "tool_use")
        XCTAssertEqual(use["id"] as? String, "toolu_1")
        XCTAssertEqual((use["input"] as? [String: Any])?["city"] as? String, "Jakarta")
        let result = try XCTUnwrap((messages[2]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(messages[2]["role"] as? String, "user")
        XCTAssertEqual(result["type"] as? String, "tool_result")
        XCTAssertEqual(result["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(result["content"] as? String, "failed")
        XCTAssertEqual(result["is_error"] as? Bool, true)
    }

    func testAnthropicDecodesContentBlocksAndUsage() throws {
        let json = """
        {"content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"toolu_2","name":"weather","input":{"city":"Bogor"}}],
        "stop_reason":"tool_use","usage":{"input_tokens":20,"output_tokens":9}}
        """
        let response = try XCTUnwrap(AnthropicChatProvider.decode(Data(json.utf8)))
        XCTAssertEqual(response.stopReason, .toolUse)
        XCTAssertEqual(response.text, "Let me check.")
        XCTAssertEqual(response.toolUses.first?.id, "toolu_2")
        XCTAssertEqual(response.toolUses.first?.name, "weather")
        XCTAssertEqual(response.toolUses.first?.inputJSON, #"{"city":"Bogor"}"#)
        XCTAssertEqual(response.inputTokens, 20)
        XCTAssertEqual(response.outputTokens, 9)
    }

    func testAnthropicErrorMapping() async {
        let session = AIStubURLProtocol.session()
        let provider = AnthropicChatProvider(keys: AIMemoryKeyStore.anthropic("ant-key"), session: session)
        let cases: [(AIStubURLProtocol.Reply, ChatResult)] = [
            (AIStubURLProtocol.json(401, ["type": "error"]), .failed(.unauthorized)),
            (AIStubURLProtocol.json(529, ["type": "error"]), .failed(.rateLimited)),
            (AIStubURLProtocol.json(429, ["type": "error"]), .failed(.rateLimited)),
            (.fail(.timedOut), .failed(.timeout))
        ]
        for (reply, expected) in cases {
            AIStubURLProtocol.reset([reply])
            let result = await provider.complete(plainRequest(), config: VoiceAIConfig())
            XCTAssertEqual(result, expected)
        }
        session.invalidateAndCancel()
    }

    func testKeysNeverCrossProviders() async throws {
        let openAIKeys = AIMemoryKeyStore("sk-openai-secret")
        let anthropicKeys = AIMemoryKeyStore.anthropic("ant-secret")
        let session = AIStubURLProtocol.session()
        let ok = AIStubURLProtocol.json(200, ["content": [["type": "text", "text": "Hi."]], "stop_reason": "end_turn"])
        AIStubURLProtocol.reset([ok])
        _ = await AnthropicChatProvider(keys: anthropicKeys, session: session).complete(plainRequest(), config: VoiceAIConfig())
        let anthropicRequest = try XCTUnwrap(AIStubURLProtocol.requests.first)
        let anthropicHeaders = anthropicRequest.allHTTPHeaderFields ?? [:]
        XCTAssertFalse(anthropicHeaders.values.contains { $0.contains("sk-openai-secret") })
        XCTAssertNil(anthropicRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(openAIKeys.readCount, 0)
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, ["choices": [["message": ["content": "Hi."]]]])])
        _ = await OpenAIChatProvider(keys: openAIKeys, session: session)
            .complete(plainRequest(), config: VoiceAIConfig(baseURL: openAIBase.absoluteString))
        let openAIRequest = try XCTUnwrap(AIStubURLProtocol.requests.first)
        XCTAssertNil(openAIRequest.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertFalse((openAIRequest.allHTTPHeaderFields ?? [:]).values.contains { $0.contains("ant-secret") })
        for body in AIStubURLProtocol.requestBodies {
            XCTAssertNil(String(decoding: body, as: UTF8.self).range(of: "secret"), "a key never goes in a body")
        }
        session.invalidateAndCancel()
    }

    // MARK: Key bound to the endpoint (security review, finding 1)

    func testKeyBindingIsNormalizedHostAndPort() {
        XCTAssertEqual(VoiceAIEndpoint.keyBinding(base: "https://API.OpenAI.com/v1"), "api.openai.com:443")
        XCTAssertEqual(VoiceAIEndpoint.keyBinding(base: "https://api.openai.com/other/path"), "api.openai.com:443")
        XCTAssertEqual(VoiceAIEndpoint.keyBinding(base: "https://api.openai.com:8443/v1"), "api.openai.com:8443")
        XCTAssertEqual(VoiceAIEndpoint.keyBinding(base: "http://localhost:1234/v1"), "localhost:1234")
        XCTAssertEqual(VoiceAIEndpoint.keyBinding(base: "http://[::1]:8080/v1"), "::1:8080")
        XCTAssertNil(VoiceAIEndpoint.keyBinding(base: "http://api.openai.com/v1"))
    }

    func testOpenAIKeyIsNotSentAfterTheBaseURLChanges() async throws {
        let session = AIStubURLProtocol.session()
        let keys = AIMemoryKeyStore("sk-bound-secret")
        let provider = OpenAIChatProvider(keys: keys, session: session)
        AIStubURLProtocol.reset([])
        let elsewhere = await provider.complete(plainRequest(), config: VoiceAIConfig(baseURL: "https://api.exarnple.test/v1"))
        XCTAssertEqual(elsewhere, .failed(.keyMissing))
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty, "a typo in the host sends nothing")
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, ["choices": [["message": ["content": "Hi."]]]])])
        _ = await provider.complete(plainRequest(), config: VoiceAIConfig(baseURL: "http://localhost:1234/v1"))
        let local = try XCTUnwrap(AIStubURLProtocol.requests.first)
        XCTAssertEqual(local.url?.host, "localhost")
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"), "the key stays bound to the host it was saved for")
        XCTAssertNil(VoiceAIReadiness.check(base: AIMemoryKeyStore.exampleBase, keys: keys))
        XCTAssertEqual(VoiceAIReadiness.check(base: "https://api.groq.com/openai/v1", keys: keys), .keyMissing)
        session.invalidateAndCancel()
    }

    func testAnthropicKeyIsNotSentAfterTheBaseURLChanges() async throws {
        let session = AIStubURLProtocol.session()
        let provider = AnthropicChatProvider(keys: AIMemoryKeyStore.anthropic("ant-bound-secret"), session: session)
        AIStubURLProtocol.reset([])
        let proxy = await provider.complete(
            plainRequest(), config: VoiceAIConfig(anthropicBaseURL: "https://anthropic-proxy.example.test")
        )
        XCTAssertEqual(proxy, .failed(.keyMissing))
        XCTAssertTrue(AIStubURLProtocol.requests.isEmpty)
        AIStubURLProtocol.reset([AIStubURLProtocol.json(200, ["content": [["type": "text", "text": "Hi."]]])])
        _ = await provider.complete(plainRequest(), config: VoiceAIConfig(anthropicBaseURL: "http://127.0.0.1:8080"))
        let local = try XCTUnwrap(AIStubURLProtocol.requests.first)
        XCTAssertNil(local.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"))
        session.invalidateAndCancel()
    }
}
