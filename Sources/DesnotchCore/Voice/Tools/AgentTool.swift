import Foundation

// Machine control for the OpenAI-compatible and Claude answers lane (opt-in
// `voiceAgentToolsEnabled`). Every tool runs inside desnotch, so it is classified and, at T2,
// approved on the agent card BEFORE it starts. Tool arguments and output are live content:
// they go only to the model, never to logs, the audit log, VoiceOver or the status menu.

/// One machine-control tool: a schema for the model, a pure classification of a call, and the
/// action itself. `propose` must not have side effects; `execute` runs only after the gate.
protocol AgentTool: Sendable {
    var definition: ChatToolDefinition { get }
    func propose(_ args: AgentToolArgs) async -> ChatToolProposal
    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome
}

/// A parsed argument value. Only JSON scalars are accepted; nested objects and arrays are
/// dropped, so no tool ever sees a shape it did not declare.
enum AgentArgValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

/// The arguments of one call, parsed from the model's JSON object.
struct AgentToolArgs: Equatable, Sendable {
    var values: [String: AgentArgValue]

    init(_ values: [String: AgentArgValue] = [:]) {
        self.values = values
    }

    /// Nil when the text is not a JSON object (an empty string counts as `{}`).
    static func parse(_ json: String) -> AgentToolArgs? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return AgentToolArgs() }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var values: [String: AgentArgValue] = [:]
        for (key, raw) in object {
            if let text = raw as? String {
                values[key] = .string(text)
            } else if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    values[key] = .bool(number.boolValue)
                } else {
                    values[key] = .number(number.doubleValue)
                }
            }
        }
        return AgentToolArgs(values)
    }

    func string(_ key: String) -> String? {
        if case .string(let text)? = values[key] { return text }
        return nil
    }

    /// A non-empty string after trimming, or nil.
    func text(_ key: String) -> String? {
        guard let raw = string(key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A whole number (a numeric string such as "30" is accepted too).
    func int(_ key: String) -> Int? {
        switch values[key] {
        case .number(let value)?:
            guard value.isFinite, value == value.rounded(), abs(value) < 1_000_000 else { return nil }
            return Int(value)
        case .string(let text)?:
            return Int(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }
}

/// Limits shared by every tool. One place, so tests and docs agree.
enum AgentToolLimits {
    /// Output returned to the model per call, in UTF-8 bytes, before the truncation marker.
    static let outputBytes = 16 * 1024
    /// Wall-clock budget of one shell, AppleScript or Shortcuts run.
    static let processTimeout: TimeInterval = 30
    /// Wall-clock budget of one web fetch.
    static let fetchTimeout: TimeInterval = 15
    /// Largest web response body read before text extraction.
    static let fetchBodyBytes = 1_000_000
    /// Largest file `read_file` opens.
    static let readFileBytes = 2_000_000
    static let readFileDefaultLines = 400
    /// Largest content `write_file` and `clipboard_write` accept.
    static let writeBytes = 64 * 1024
    static let listEntries = 200
    static let searchResults = 50
    static let searchVisited = 20_000
    static let searchDepth = 6
    /// A URL longer than this needs the card (a long URL can carry data out).
    static let quietURLLength = 200
    /// The desnotch-authored preview of a write on the card.
    static let writePreviewCharacters = 100
}

/// Builds the `tool_result` text the model sees. Everything a tool returns is untrusted data
/// (file contents, web pages, command output): it is capped and fenced, and a fence cannot be
/// closed from inside because the marker text is neutralized.
enum AgentToolOutput {
    static let truncationMarker = "[output truncated by desnotch]"

    static func wrap(tool code: String, _ content: String) -> String {
        let capped = cap(content)
        let neutral = capped
            .replacingOccurrences(of: "<tool_output", with: "<tool-output")
            .replacingOccurrences(of: "</tool_output", with: "</tool-output")
        return "<tool_output tool=\"\(code)\" trust=\"untrusted\">\n\(neutral)\n</tool_output>"
    }

    /// Cuts at `AgentToolLimits.outputBytes` UTF-8 bytes on a character boundary and appends
    /// the marker when anything was dropped.
    static func cap(_ text: String, limit: Int = AgentToolLimits.outputBytes) -> String {
        guard text.utf8.count > limit else { return text }
        var kept = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            kept.append(character)
            bytes += size
        }
        return kept + "\n" + truncationMarker
    }
}

/// Small helpers for building proposals.
enum AgentProposals {
    static func invalid(_ code: String, label: String, _ reason: String) -> ChatToolProposal {
        ChatToolProposal(
            tier: .t3, stepLabel: label, summary: "Invalid request", auditCode: code, invalidReason: reason
        )
    }

    static func unknownTool() -> ChatToolProposal {
        ChatToolProposal(tier: .t3, stepLabel: "Unknown tool", summary: "Unknown tool", auditCode: "tool.unknown")
    }

    /// The display form of a model-authored literal: control, bidi and zero-width characters
    /// removed by the command scanner, with its flags.
    static func scanned(_ literal: String) -> CommandRisk {
        CommandRiskScanner.scan(literal)
    }
}
