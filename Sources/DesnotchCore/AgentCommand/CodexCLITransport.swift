import Foundation

/// Read-only Codex CLI planner. The spoken prompt is sent over stdin (not argv, where
/// it would be visible in `ps`), and JSONL is parsed as it arrives.
public struct CodexCLITransport: AgentCommandBackend {
    public let executableURL: URL
    public let runner: AgentProcessRunner

    public init(executableURL: URL? = nil, runner: AgentProcessRunner = AgentProcessRunner()) {
        self.executableURL = executableURL
            ?? Self.discoverExecutable()
            ?? URL(fileURLWithPath: "/usr/local/bin/codex")
        self.runner = runner
    }

    public static func discoverExecutable() -> URL? {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func stream(
        prompt: String,
        cwd: URL,
        timeout: TimeInterval,
        onEvent: @escaping @Sendable (AgentCommandEvent) -> Void
    ) async throws -> AgentCommandOutput {
        let decoder = AgentJSONLDecoder(onEvent: onEvent)
        let plannerPrompt = """
        You are desnotch's local command-planning assistant. Do not invoke shell commands,
        tools, network access, credential stores, or sensitive paths; reason from the spoken
        request only. Explain the result briefly. If the request needs a local command, do
        not run that command yourself. End with exactly one line in this form, containing a
        JSON object with a direct executable and argv (never a shell string):
        DESNOTCH_COMMAND_JSON: {"command":"git","arguments":["status","--short"]}
        Omit that line when no command is needed. Never put secrets in a proposal.

        User request:
        \(prompt)
        """
        let arguments = [
            "exec", "--json", "--ephemeral", "--sandbox", "read-only",
            "--ignore-user-config", "--ignore-rules", "--color", "never",
            "--cd", cwd.path, "--skip-git-repo-check", "-"
        ]
        let result = try await runner.run(
            executable: executableURL,
            arguments: arguments,
            cwd: cwd,
            timeout: timeout,
            standardInput: Data(plannerPrompt.utf8),
            onStdout: { data in decoder.ingest(data) }
        )
        decoder.finish()
        guard result.exitCode == 0 else { throw AgentProcessError.launchFailed }
        return AgentCommandOutput(stdout: "", stderr: "", truncated: result.truncated)
    }

    public func shutdown(timeout: TimeInterval) {
        runner.shutdown(timeout: timeout)
    }

    /// Parses only documented Codex JSONL shapes plus the desnotch proposal marker.
    /// Internal Codex `command_execution` events are status, never executable proposals.
    public static func parseJSONL(_ line: String) -> AgentCommandEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = object["type"] as? String ?? ""
        switch type {
        case "thread.started":
            return AgentCommandEvent(kind: .status, text: "Agent started")
        case "turn.started":
            return AgentCommandEvent(kind: .status, text: "Agent is working")
        case "turn.completed":
            return AgentCommandEvent(kind: .complete)
        case "turn.failed", "error":
            return AgentCommandEvent(kind: .error, text: "Agent request failed")
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { return nil }
            if itemType == "agent_message", let text = item["text"] as? String {
                if let proposal = proposal(in: text) {
                    return AgentCommandEvent(kind: .proposal, text: visibleText(from: text), proposal: proposal)
                }
                return AgentCommandEvent(kind: .output, text: text)
            }
            if itemType == "command_execution" {
                return AgentCommandEvent(kind: .status, text: "Agent is inspecting local context")
            }
            return nil
        default:
            return nil
        }
    }

    public static func proposal(in text: String) -> AgentCommandProposal? {
        guard let markerRange = text.range(of: "DESNOTCH_COMMAND_JSON:", options: .backwards) else { return nil }
        let payload = text[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = payload.split(whereSeparator: \.isNewline).first,
              let data = String(firstLine).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String,
              let arguments = object["arguments"] as? [String]
        else { return nil }
        return AgentCommandProposal(command: command, arguments: arguments)
    }

    public static func parseMarker(_ marker: String) -> AgentCommandProposal? {
        proposal(in: "DESNOTCH_COMMAND_JSON: \(marker)")
    }

    private static func visibleText(from text: String) -> String? {
        guard let markerRange = text.range(of: "DESNOTCH_COMMAND_JSON:", options: .backwards) else { return text }
        let visible = text[..<markerRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : visible
    }
}

private final class AgentJSONLDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onEvent: @Sendable (AgentCommandEvent) -> Void

    init(onEvent: @escaping @Sendable (AgentCommandEvent) -> Void) {
        self.onEvent = onEvent
    }

    func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
        }
        // Refuse unbounded malformed lines while continuing to drain the pipe.
        if buffer.count > 64 * 1024 { buffer.removeAll(keepingCapacity: true) }
        lock.unlock()
        for line in lines {
            if let event = CodexCLITransport.parseJSONL(String(decoding: line, as: UTF8.self)) {
                onEvent(event)
            }
        }
    }

    func finish() {
        lock.lock()
        let final = buffer
        buffer.removeAll()
        lock.unlock()
        guard !final.isEmpty,
              let event = CodexCLITransport.parseJSONL(String(decoding: final, as: UTF8.self))
        else { return }
        onEvent(event)
    }
}
