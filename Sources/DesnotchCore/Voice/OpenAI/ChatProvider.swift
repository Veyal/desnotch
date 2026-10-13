import Foundation

// Provider-neutral chat vocabulary for the answers lane. Two adapters speak it today
// (OpenAI-compatible chat completions and the Anthropic Messages API). Tool use is modelled
// end to end (tool calls out, tool results back) so a later package can add machine control
// behind `ChatToolHandling`; in this release no tool is ever offered to a model.

enum ChatRole: String, Sendable, Equatable {
    case user
    case assistant
}

enum ChatContentBlock: Equatable, Sendable {
    case text(String)
    /// A tool call from the model. `inputJSON` is the raw JSON object of the arguments.
    case toolUse(id: String, name: String, inputJSON: String)
    /// The result of a tool call, sent back in the next request.
    case toolResult(toolUseID: String, content: String, isError: Bool)
}

struct ChatMessage: Equatable, Sendable {
    var role: ChatRole
    var content: [ChatContentBlock]

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: [.text(text)])
    }
}

/// A tool a model may call. `inputSchemaJSON` is a JSON Schema object.
struct ChatToolDefinition: Equatable, Sendable {
    var name: String
    var description: String
    var inputSchemaJSON: String
}

struct ChatRequest: Equatable, Sendable {
    var system: String
    var messages: [ChatMessage]
    var tools: [ChatToolDefinition]
    var maxTokens: Int
}

enum ChatStopReason: Equatable, Sendable {
    case endTurn
    case toolUse
    case maxTokens
    case other
}

struct ChatResponse: Equatable, Sendable {
    var content: [ChatContentBlock]
    var stopReason: ChatStopReason
    var inputTokens: Int
    var outputTokens: Int

    /// The text blocks joined, in order.
    var text: String {
        content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: " ")
    }

    var toolUses: [(id: String, name: String, inputJSON: String)] {
        content.compactMap { block in
            if case .toolUse(let id, let name, let input) = block { return (id, name, input) }
            return nil
        }
    }
}

enum ChatResult: Equatable, Sendable {
    case response(ChatResponse)
    case failed(ProviderFailure)
    case cancelled
}

/// One round trip to a chat model. Implementations own their key store and session, so a
/// provider can only ever send its own key to its own configured endpoint.
protocol ChatProvider: Sendable {
    var kind: VoiceChatProviderKind { get }
    /// Endpoint and key check without reading the secret (used by the lane preflight).
    func readiness(_ config: VoiceAIConfig) -> ProviderFailure?
    func complete(_ request: ChatRequest, config: VoiceAIConfig) async -> ChatResult
}

struct ChatToolOutcome: Equatable, Sendable {
    var content: String
    var isError: Bool
}

/// Hook for a later machine-control package. The answers backend takes it as nil in this
/// release, so no tool definition is sent and no tool call can be run. A handler added later
/// must also teach `ToolTierTable` its tool names: every tool call is reported to the reducer
/// as `.toolActivity`, and an unknown tool trips the tripwire (R83).
protocol ChatToolHandling: Sendable {
    var tools: [ChatToolDefinition] { get }
    func run(name: String, inputJSON: String) async -> ChatToolOutcome
}

/// Small JSON helpers shared by both adapters.
enum ChatJSON {
    /// Parses a JSON object string; an invalid or non-object string becomes `{}`.
    static func object(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func string(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func data(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
