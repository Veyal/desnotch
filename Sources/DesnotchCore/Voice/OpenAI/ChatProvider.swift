import Foundation

// Provider-neutral chat vocabulary for the answers lane. Two adapters speak it today
// (OpenAI-compatible chat completions and the Anthropic Messages API). Tool use is modelled
// end to end (tool calls out, tool results back). Tools are offered to a model only when the
// user turned on "Let the agent control this Mac" (`voiceAgentToolsEnabled`); the tools
// themselves live in `Voice/Tools/` behind `ChatToolHandling`.

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

/// What desnotch decided about one tool call BEFORE anything runs. `tier` picks the gate
/// (T0/T1 run, T2 needs the agent approval card, T3/T4 never run); `stepLabel` is the
/// `AgentToolStep` label the start is reported with. `summary` is desnotch-authored; `literal`
/// is the exact command, path or URL the card shows. `auditCode` is a fixed catalog code
/// (`tool.<name>`, or `tool.unknown`), never model text.
struct ChatToolProposal: Equatable, Sendable {
    var tier: VoiceTier
    var stepLabel: String
    var summary: String
    var literal: String
    var risk: RiskFlags
    var isTruncated: Bool
    var auditCode: String
    /// Set when the arguments do not parse or are out of range: nothing runs and this short,
    /// desnotch-authored reason goes back to the model.
    var invalidReason: String?

    init(
        tier: VoiceTier,
        stepLabel: String,
        summary: String,
        literal: String = "",
        risk: RiskFlags = [],
        isTruncated: Bool = false,
        auditCode: String,
        invalidReason: String? = nil
    ) {
        self.tier = tier
        self.stepLabel = stepLabel
        self.summary = summary
        self.literal = literal
        self.risk = risk
        self.isTruncated = isTruncated
        self.auditCode = auditCode
        self.invalidReason = invalidReason
    }
}

/// Facts about the turn so far that change how a call classifies. `afterDataRead` is true once a
/// tool that returns user data (a file, a folder listing, a page, command output, the clipboard,
/// system info) has run in this turn: from then on every call that sends data off the Mac
/// (`open_url`, `web_fetch`) needs the card, decided before any DNS lookup.
struct ChatToolCallContext: Equatable, Sendable {
    var afterDataRead: Bool

    init(afterDataRead: Bool = false) {
        self.afterDataRead = afterDataRead
    }
}

/// The machine-control seam (`AgentToolbox` in `Voice/Tools/`). The answers backend asks
/// `propose` first and gates the call on its tier (`AgentToolGate`); `run` happens only after
/// that gate, and re-checks the call so nothing changed between the card and the start.
protocol ChatToolHandling: Sendable {
    var tools: [ChatToolDefinition] { get }
    func propose(name: String, inputJSON: String, context: ChatToolCallContext) async -> ChatToolProposal
    /// `approvedTier` is the tier the gate let through; a call that now classifies higher is refused.
    func run(name: String, inputJSON: String, approvedTier: VoiceTier, context: ChatToolCallContext) async -> ChatToolOutcome
    /// True for tools whose result carries user data (marks the turn `afterDataRead`).
    func revealsData(name: String) -> Bool
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
