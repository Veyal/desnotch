import Foundation

/// Maps one ACP session's updates into `AgentEvent`s. Seen tool ids and permission ids last for the
/// session; accumulated text resets at each prompt. The caller supplies `at` so coalescing needs no clock.
struct HermesEventMapper {
    private var seenTools: Set<String> = []
    private var permissionIDs: Set<String> = []
    private var text = ""
    private var lastPartial: Date?
    private var pending: [String: PendingPermission] = [:]

    private struct PendingPermission {
        var id: Any
        var options: Set<String>
    }

    struct Ingest {
        var events: [AgentEvent] = []
        var reply: [String: Any]?
    }

    mutating func beginPrompt() {
        text = ""
        lastPartial = nil
    }

    mutating func ingest(update: [String: Any], at: Date) -> Ingest {
        var result = Ingest()
        if let input = HermesJSON.int(update["inputTokens"]), let output = HermesJSON.int(update["outputTokens"]) {
            result.events.append(.usage(inputTokens: input, outputTokens: output, costMicros: 0))
        }
        let kind = update["sessionUpdate"] as? String ?? ""
        if Self.ignored.contains(kind) { return result }
        switch kind {
        case "agent_message_chunk":
            let chunk = ((update["content"] as? [String: Any])?["text"] as? String) ?? ""
            text += chunk
            if lastPartial == nil || at.timeIntervalSince(lastPartial ?? at) >= 0.1 {
                lastPartial = at
                result.events.append(.partial(Self.tail(text)))
            }
        case "tool_call", "tool_call_update":
            if let activity = noteTool(update) {
                result.events.append(activity)
            }
        default:
            break
        }
        return result
    }

    mutating func ingestPermission(params: [String: Any], id: Any, nonce: String) -> Ingest {
        let tool = params["toolCall"] as? [String: Any] ?? [:]
        if let toolID = tool["toolCallId"] as? String, !toolID.isEmpty {
            permissionIDs.insert(toolID)
        }
        let title = tool["title"] as? String ?? ""
        let command = (tool["rawInput"] as? [String: Any])?["command"] as? String
        let literal = command ?? title
        let risk = CommandRiskScanner.scan(literal)
        var options: Set<String> = []
        if let listed = params["options"] as? [[String: Any]] {
            for item in listed {
                if let option = item["optionId"] as? String { options.insert(option) }
            }
        }
        pending[nonce] = PendingPermission(id: id, options: options)
        let card = ConfirmationRequest(
            nonce: nonce,
            tier: risk.tier,
            source: .hermes,
            summary: "Agent wants to run a command",
            literal: risk.sanitized,
            risk: risk.flags,
            isTruncated: risk.wasTruncated,
            requiresSecondFactor: risk.tier >= .t3
        )
        return Ingest(events: [.approvalNeeded(card)])
    }

    func stopEvent(reason: String) -> AgentEvent {
        if reason == "end_turn" {
            return .finished(summary: String(text.prefix(400)))
        }
        return .failed(.agentFailed("stop_\(Self.sanitizedReason(reason))"))
    }

    mutating func reply(nonce: String, allow: Bool) -> [String: Any]? {
        guard let request = pending.removeValue(forKey: nonce) else { return nil }
        let option: String?
        if allow && request.options.contains("allow_once") {
            option = "allow_once"
        } else if request.options.contains("deny") {
            option = "deny"
        } else {
            option = nil
        }
        let outcome: [String: Any]
        if let option {
            outcome = ["outcome": "selected", "optionId": option]
        } else {
            outcome = ["outcome": "cancelled"]
        }
        return ["jsonrpc": "2.0", "id": request.id, "result": ["outcome": outcome]]
    }

    mutating func pendingNonces() -> [String] {
        Array(pending.keys)
    }

    private mutating func noteTool(_ update: [String: Any]) -> AgentEvent? {
        guard let id = update["toolCallId"] as? String, !id.isEmpty else { return nil }
        if permissionIDs.contains(id) || seenTools.contains(id) { return nil }
        seenTools.insert(id)
        return .toolActivity(kind: Self.toolKind(update["title"] as? String))
    }

    private static let ignored: Set<String> = [
        "usage_update", "available_commands_update", "plan", "agent_thought_chunk", "session_info_update"
    ]

    static func toolKind(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "unknown_tool" }
        let head = title.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? title
        let kind = head.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kind.isEmpty, kind.count <= 40, kind.unicodeScalars.allSatisfy(isKindScalar) else {
            return "unknown_tool"
        }
        return kind
    }

    private static func isKindScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            || scalar == "_" || scalar == "." || scalar == "-"
    }

    static func sanitizedReason(_ reason: String) -> String {
        let filtered = reason.lowercased().filter { ($0 >= "a" && $0 <= "z") || $0 == "_" }
        if filtered.isEmpty { return "unknown" }
        return String(filtered.prefix(24))
    }

    private static func tail(_ text: String) -> String {
        if text.count <= 400 { return text }
        return String(text.suffix(400))
    }
}

enum HermesJSON {
    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() {
            return number.intValue
        }
        return nil
    }

    static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func line(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
