import Foundation

/// Discovers local Claude Code / Codex CLI session transcripts and turns them into coarse,
/// privacy-safe `AgentSession` summaries.
///
/// Pattern adapted from agent-island (https://github.com/tristan666666/agent-island, MIT,
/// Eric Park)'s `SessionScanner.swift`: enumerate the known session-log directories, skip
/// sub-agent/automation fan-out, and derive state from file recency plus a turn-completion
/// marker - never from transcript content. See `AGENTS.md` for the attribution note and the
/// per-format detail this implementation fills in independently.
///
/// Every path here is built from `NSHomeDirectory()` via the standard `~/.claude` / `~/.codex`
/// locations - never a machine-specific literal - and nothing that leaves this type (session
/// id, absolute path, transcript text) reaches the UI. Only `AgentSession.projectLabel` (a
/// basename) and `AgentSession.state`/`lastActivity` do.
enum AgentActivityScanner {
    /// Sessions whose transcript hasn't changed in longer than this are treated as gone, not
    /// merely idle - old/finished chats from days ago shouldn't resurface as activity.
    private static let lookbackWindow: TimeInterval = 2 * 60 * 60
    /// A turn that's still "in progress" (mid tool-call, or a fresh user message not yet
    /// answered) past this long without a file change is presumed hung rather than working.
    private static let stalledWindow: TimeInterval = 10 * 60
    /// A completed turn this recent is "needs you"; older than this it fades to plain "idle".
    private static let needsYourTurnWindow: TimeInterval = 5 * 60
    /// Only the tail of each transcript is read - large session files should stay cheap to scan.
    private static let tailByteCount = 65536

    static func scan(now: Date) -> [AgentSession] {
        scanClaudeCode(now: now) + scanCodex(now: now)
    }

    // MARK: - Claude Code

    private static func scanClaudeCode(now: Date) -> [AgentSession] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootDepth = root.pathComponents.count
        var sessions: [AgentSession] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard url.pathComponents.count > rootDepth else { continue }

            let projectDirName = url.pathComponents[rootDepth]
            let fileName = url.lastPathComponent
            if fileName.hasPrefix("agent-") { continue }
            if url.pathComponents.contains("subagents") { continue }

            guard let mtime = modificationDate(url) else { continue }
            let elapsed = now.timeIntervalSince(mtime)
            guard elapsed <= lookbackWindow else { continue }

            guard let turnInProgress = tailClaudeTurnInProgress(url) else { continue }

            sessions.append(
                AgentSession(
                    source: .claudeCode,
                    projectLabel: projectLabel(fromEncodedDirectoryName: projectDirName),
                    state: classify(elapsed: elapsed, turnInProgress: turnInProgress),
                    lastActivity: mtime
                )
            )
        }

        return sessions
    }

    /// Claude Code project directories encode the original absolute path with `/` replaced by
    /// `-` (e.g. a home-relative project folder becomes `-Users-name-project`). That encoding is
    /// lossy and never decoded back to a real path here - only its last dash-separated segment
    /// (the project folder's basename) is used, which is exactly the generic label the UI needs.
    private static func projectLabel(fromEncodedDirectoryName name: String) -> String {
        name.split(separator: "-").last.map(String.init) ?? "project"
    }

    /// Returns whether the most recent turn-relevant transcript entry indicates the agent is
    /// still working (`nil` if no relevant entry was found in the tail at all).
    ///
    /// Claude Code JSONL entries relevant to turn state: `type: "assistant"` messages carry a
    /// `message.stop_reason` of `"tool_use"` while mid-turn (a tool call is in flight) versus
    /// `"end_turn"`/`"stop_sequence"`/absent once the turn is complete and control is back with
    /// the user. A trailing `type: "user"` entry (a fresh prompt, or a tool result) means the
    /// assistant hasn't produced its next message yet, i.e. still in progress.
    private static func tailClaudeTurnInProgress(_ url: URL) -> Bool? {
        for line in tailLines(url).reversed() {
            guard let obj = parseJSONObject(line), let type = obj["type"] as? String else { continue }
            switch type {
            case "assistant":
                let stopReason = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                return stopReason == "tool_use"
            case "user":
                return true
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Codex

    private static func scanCodex(now: Date) -> [AgentSession] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [AgentSession] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }

            guard let mtime = modificationDate(url) else { continue }
            let elapsed = now.timeIntervalSince(mtime)
            guard elapsed <= lookbackWindow else { continue }

            guard let firstLine = firstLine(url), let meta = parseJSONObject(firstLine) else { continue }
            guard let payload = meta["payload"] as? [String: Any] else { continue }
            guard !isAutomationCodexSession(payload) else { continue }

            let label = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "session"
            let turnInProgress = tailCodexTurnInProgress(url) ?? true

            sessions.append(
                AgentSession(
                    source: .codex,
                    projectLabel: label,
                    state: classify(elapsed: elapsed, turnInProgress: turnInProgress),
                    lastActivity: mtime
                )
            )
        }

        return sessions
    }

    /// Codex `session_meta.payload.originator`/`.source` mark where a session came from -
    /// e.g. `codex_exec`/`exec` for headless automation runs versus an interactive client. Those
    /// automation/exec runs are fan-out noise, not a person's session worth surfacing, same
    /// reasoning as skipping Claude Code's `subagents/`.
    private static func isAutomationCodexSession(_ payload: [String: Any]) -> Bool {
        let markers = ["exec", "automation", "subagent"]
        let originator = (payload["originator"] as? String)?.lowercased() ?? ""
        let source = (payload["source"] as? String)?.lowercased() ?? ""
        return markers.contains { originator.contains($0) || source.contains($0) }
    }

    /// Codex event stream turn markers: `event_msg.payload.type` of `"task_started"` versus
    /// `"task_complete"` bracket a turn directly, no stop-reason inference needed.
    private static func tailCodexTurnInProgress(_ url: URL) -> Bool? {
        for line in tailLines(url).reversed() {
            guard let obj = parseJSONObject(line), obj["type"] as? String == "event_msg" else { continue }
            guard let payloadType = (obj["payload"] as? [String: Any])?["type"] as? String else { continue }
            switch payloadType {
            case "task_started":
                return true
            case "task_complete":
                return false
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Shared

    private static func classify(elapsed: TimeInterval, turnInProgress: Bool) -> AgentActivityState {
        if turnInProgress {
            return elapsed < stalledWindow ? .working : .stalled
        } else {
            return elapsed < needsYourTurnWindow ? .needsYourTurn : .idle
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func firstLine(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // A session_meta header line is small; a generous fixed read avoids opening the whole
        // (potentially large) transcript just to read the first line.
        guard let chunk = try? handle.read(upToCount: 4096), let text = String(data: chunk, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    private static func tailLines(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > UInt64(tailByteCount) ? fileSize - UInt64(tailByteCount) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd(),
            let text = String(data: data, encoding: .utf8)
        else { return [] }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // Drop a possibly-truncated first line when we didn't start at the top of the file.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func parseJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
