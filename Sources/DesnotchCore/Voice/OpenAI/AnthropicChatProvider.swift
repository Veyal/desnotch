import Foundation

/// Anthropic Messages API, `POST {base}/v1/messages` with `x-api-key` and `anthropic-version`.
/// The system prompt is the top-level `system` field; tools map to `tools` / `tool_use` /
/// `tool_result` content blocks. Answers only: Anthropic has no speech endpoints.
struct AnthropicChatProvider: ChatProvider {
    static let apiVersion = "2023-06-01"

    let keys: VoiceAIKeyStoring
    let session: URLSession

    var kind: VoiceChatProviderKind { .anthropic }

    func readiness(_ config: VoiceAIConfig) -> ProviderFailure? {
        VoiceAIReadiness.check(base: config.anthropicBaseURL, keys: keys)
    }

    func complete(_ request: ChatRequest, config: VoiceAIConfig) async -> ChatResult {
        let ready: VoiceAIReadiness.Ready
        switch VoiceAIReadiness.resolve(base: config.anthropicBaseURL, keys: keys) {
        case .failure(let failure): return .failed(failure)
        case .success(let value): ready = value
        }
        let urlRequest = Self.urlRequest(request, base: ready.base, key: ready.key, model: config.anthropicModel)
        switch await VoiceAIHTTP.send(urlRequest, session: session, maxBytes: VoiceAILimits.maxJSONBytes) {
        case .ok(let data):
            guard let decoded = Self.decode(data) else { return .failed(.badResponse) }
            return .response(decoded)
        case .status(let status, _):
            // 529 is Anthropic's "overloaded".
            return .failed(status == 529 ? .rateLimited : VoiceAIHTTP.classify(status: status))
        case .failed(let failure):
            return .failed(failure)
        case .cancelled:
            return .cancelled
        }
    }

    // MARK: Wire format (pure, tested)

    static func headers(key: String?) -> [String: String] {
        var headers = [
            "content-type": "application/json",
            "anthropic-version": apiVersion
        ]
        if let key, !key.isEmpty { headers["x-api-key"] = key }
        return headers
    }

    static func urlRequest(_ request: ChatRequest, base: URL, key: String?, model: String) -> URLRequest {
        var urlRequest = URLRequest(url: VoiceAIEndpoint.url(base, "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = VoiceAILimits.chatTimeout
        for (name, value) in headers(key: key) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = ChatJSON.data(body(request, model: model))
        return urlRequest
    }

    static func body(_ request: ChatRequest, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "messages": request.messages.map(wireMessage)
        ]
        if !request.system.isEmpty {
            body["system"] = request.system
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": ChatJSON.object(tool.inputSchemaJSON)
                ]
            }
        }
        return body
    }

    static func wireMessage(_ message: ChatMessage) -> [String: Any] {
        let blocks = message.content.map { block -> [String: Any] in
            switch block {
            case .text(let text):
                return ["type": "text", "text": text]
            case .toolUse(let id, let name, let input):
                return ["type": "tool_use", "id": id, "name": name, "input": ChatJSON.object(input)]
            case .toolResult(let id, let content, let isError):
                return ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError]
            }
        }
        return ["role": message.role.rawValue, "content": blocks]
    }

    static func decode(_ data: Data) -> ChatResponse? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = object["content"] as? [[String: Any]]
        else { return nil }
        var content: [ChatContentBlock] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { content.append(.text(text)) }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                content.append(.toolUse(id: id, name: name, inputJSON: ChatJSON.string(block["input"] ?? [:])))
            default:
                continue
            }
        }
        let stop: ChatStopReason
        switch object["stop_reason"] as? String {
        case "end_turn", "stop_sequence": stop = .endTurn
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        default: stop = .other
        }
        let usage = object["usage"] as? [String: Any]
        return ChatResponse(
            content: content,
            stopReason: stop,
            inputTokens: ChatJSON.int(usage?["input_tokens"]),
            outputTokens: ChatJSON.int(usage?["output_tokens"])
        )
    }
}
