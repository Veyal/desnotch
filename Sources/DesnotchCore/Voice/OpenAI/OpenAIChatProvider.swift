import Foundation

/// OpenAI-compatible `POST {base}/chat/completions` (OpenAI, Groq, OpenRouter, LM Studio,
/// Ollama...). Non-streaming. Tools map to `tools` / `tool_calls` / `role: tool` messages.
struct OpenAIChatProvider: ChatProvider {
    let keys: VoiceAIKeyStoring
    let session: URLSession

    var kind: VoiceChatProviderKind { .openAICompatible }

    func readiness(_ config: VoiceAIConfig) -> ProviderFailure? {
        VoiceAIReadiness.check(base: config.baseURL, keys: keys)
    }

    func complete(_ request: ChatRequest, config: VoiceAIConfig) async -> ChatResult {
        let ready: VoiceAIReadiness.Ready
        switch VoiceAIReadiness.resolve(base: config.baseURL, keys: keys) {
        case .failure(let failure): return .failed(failure)
        case .success(let value): ready = value
        }
        var useCompletionTokens = false
        // At most one retry: newer OpenAI models reject `max_tokens`, while many compatible
        // servers only know `max_tokens`. Start with the widely supported one.
        for _ in 0..<2 {
            let urlRequest = Self.urlRequest(
                request, base: ready.base, key: ready.key, model: config.chatModel,
                useCompletionTokens: useCompletionTokens
            )
            let response = await VoiceAIHTTP.send(urlRequest, session: session, maxBytes: VoiceAILimits.maxJSONBytes)
            switch response {
            case .ok(let data):
                guard let decoded = Self.decode(data) else { return .failed(.badResponse) }
                return .response(decoded)
            case .status(let status, let body):
                if status == 400, !useCompletionTokens, Self.rejectsMaxTokens(body) {
                    useCompletionTokens = true
                    continue
                }
                return .failed(VoiceAIHTTP.classify(status: status))
            case .failed(let failure):
                return .failed(failure)
            case .cancelled:
                return .cancelled
            }
        }
        return .failed(.httpError)
    }

    // MARK: Wire format (pure, tested)

    static func urlRequest(
        _ request: ChatRequest, base: URL, key: String?, model: String, useCompletionTokens: Bool = false
    ) -> URLRequest {
        var urlRequest = URLRequest(url: VoiceAIEndpoint.url(base, "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = VoiceAILimits.chatTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        VoiceAIHTTP.authorize(&urlRequest, key: key)
        urlRequest.httpBody = ChatJSON.data(body(request, model: model, useCompletionTokens: useCompletionTokens))
        return urlRequest
    }

    static func body(_ request: ChatRequest, model: String, useCompletionTokens: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty {
            messages.append(["role": "system", "content": request.system])
        }
        for message in request.messages {
            messages.append(contentsOf: wireMessages(message))
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]
        body[useCompletionTokens ? "max_completion_tokens" : "max_tokens"] = request.maxTokens
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": ChatJSON.object(tool.inputSchemaJSON)
                    ] as [String: Any]
                ]
            }
        }
        return body
    }

    /// Tool results become one `role: tool` message each; an assistant turn with tool calls
    /// carries them in `tool_calls` next to its text.
    static func wireMessages(_ message: ChatMessage) -> [[String: Any]] {
        var texts: [String] = []
        var calls: [[String: Any]] = []
        var results: [[String: Any]] = []
        for block in message.content {
            switch block {
            case .text(let text):
                texts.append(text)
            case .toolUse(let id, let name, let input):
                calls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": input] as [String: Any]
                ])
            case .toolResult(let id, let content, _):
                results.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }
        var out: [[String: Any]] = []
        if !texts.isEmpty || !calls.isEmpty {
            var wire: [String: Any] = ["role": message.role.rawValue]
            wire["content"] = texts.isEmpty ? NSNull() : texts.joined(separator: "\n")
            if !calls.isEmpty { wire["tool_calls"] = calls }
            out.append(wire)
        }
        out.append(contentsOf: results)
        return out
    }

    static func decode(_ data: Data) -> ChatResponse? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else { return nil }
        var content: [ChatContentBlock] = []
        if let text = message["content"] as? String, !text.isEmpty {
            content.append(.text(text))
        } else if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty { content.append(.text(text)) }
            }
        }
        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String
            else { continue }
            content.append(.toolUse(id: id, name: name, inputJSON: function["arguments"] as? String ?? "{}"))
        }
        let stop: ChatStopReason
        switch first["finish_reason"] as? String {
        case "stop": stop = .endTurn
        case "tool_calls": stop = .toolUse
        case "length": stop = .maxTokens
        default: stop = .other
        }
        let usage = object["usage"] as? [String: Any]
        return ChatResponse(
            content: content,
            stopReason: stop,
            inputTokens: ChatJSON.int(usage?["prompt_tokens"]),
            outputTokens: ChatJSON.int(usage?["completion_tokens"])
        )
    }

    /// A 400 whose error names `max_tokens` (OpenAI's "use max_completion_tokens instead").
    static func rejectsMaxTokens(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return false }
        if (error["param"] as? String) == "max_tokens" { return true }
        return (error["message"] as? String)?.contains("max_completion_tokens") == true
    }
}
