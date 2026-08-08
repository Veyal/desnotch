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
public enum AgentActivityScanner {
    /// Sessions whose transcript hasn't changed in longer than this are treated as gone, not
    /// merely idle - old/finished chats from days ago shouldn't resurface as activity.
    static let lookbackWindow: TimeInterval = 2 * 60 * 60
    /// A turn that's still "in progress" past this long without a file change is presumed hung.
    static let stalledWindow: TimeInterval = 10 * 60
    /// A stalled (presumed-hung) session is only surfaced this long; beyond it, it's almost
    /// certainly dead and would otherwise inflate the count ("N agents: ... stalled") for up
    /// to `lookbackWindow`.
    static let stalledSessionMax: TimeInterval = 45 * 60
    /// A completed turn this recent is "needs you"; older than this it fades to plain "idle".
    static let needsYourTurnWindow: TimeInterval = 5 * 60

    /// Tail seek window is escalated through these sizes when no turn signal is found, so a
    /// single giant JSONL entry (seen: >1 MB) doesn't silently drop a whole session.
    static let tailWindows: [Int] = [65_536, 1_048_576, 4_194_304]

    /// Scan the current user's known session directories.
    public static func scan(now: Date) -> [AgentSession] {
        scan(home: URL(fileURLWithPath: NSHomeDirectory()), now: now)
    }

    /// Scan rooted at an arbitrary home directory (testable with fixture trees).
    public static func scan(home: URL, now: Date) -> [AgentSession] {
        scanClaudeCode(home: home, now: now)
            + scanCodex(home: home, now: now)
            + scanPi(home: home, now: now)
            + scanOpenCode(home: home, now: now)
    }

    // MARK: - Claude Code

    private static func scanClaudeCode(home: URL, now: Date) -> [AgentSession] {
        let root = home
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

            let projectDirName = url.deletingLastPathComponent().lastPathComponent
            let fileName = url.lastPathComponent
            if fileName.hasPrefix("agent-") { continue }
            if url.pathComponents.contains("subagents") { continue }

            guard let mtime = modificationDate(url) else { continue }
            let elapsed = now.timeIntervalSince(mtime)
            guard elapsed <= lookbackWindow else { continue }

            guard let turnInProgress = tailClaudeTurnInProgress(url) else { continue }
            guard let state = classify(elapsed: elapsed, turnInProgress: turnInProgress) else { continue }

            let facts = claudeFacts(for: url)
            sessions.append(
                AgentSession(
                    source: .claudeCode,
                    projectLabel: facts.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                        ?? projectLabel(fromEncodedDirectoryName: projectDirName),
                    taskTitle: facts.title,
                    projectPath: facts.cwd,
                    state: state,
                    lastActivity: mtime
                )
            )
        }

        return sessions
    }

    /// Reads the real working directory from a Claude Code transcript's header lines (a
    /// `user`/`assistant` entry carries `cwd`). Only the first chunk is scanned.
    private static func readClaudeCWD(_ url: URL) -> String? {
        guard let text = readUpToNewline(url, maxBytes: 32_768) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = parseJSONObject(String(line)) else { continue }
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    private static func projectLabel(fromEncodedDirectoryName name: String) -> String {
        guard !name.isEmpty else { return "project" }
        return URL(fileURLWithPath: name).lastPathComponent
    }

    // MARK: - Immutable-fact cache

    /// A session file's cwd, task title, and (Codex) header metadata never change once
    /// written, but used to be re-read and re-JSON-parsed on every 5s scan (~290KB per
    /// Claude session, up to 1MB per Codex header). Cache them by path. Only
    /// successfully-derived values are cached - a nil title may simply not exist *yet*
    /// in a brand-new session, so nil results retry on the next scan. Lock-guarded:
    /// scans run one at a time but off the main actor.
    private static let cacheLock = NSLock()
    private static var claudeFactsCache: [String: (cwd: String?, title: String?)] = [:]
    private static var codexHeaderCache: [String: (cwd: String?, automation: Bool)] = [:]
    private static var codexTitleCache: [String: String] = [:]
    private static let cacheCap = 512

    /// Test/pressure hatch; also keeps unbounded growth impossible.
    static func dropCaches() {
        cacheLock.lock()
        claudeFactsCache.removeAll()
        codexHeaderCache.removeAll()
        codexTitleCache.removeAll()
        cacheLock.unlock()
    }

    private static func claudeFacts(for url: URL) -> (cwd: String?, title: String?) {
        let key = url.path
        cacheLock.lock()
        let cached = claudeFactsCache[key]
        cacheLock.unlock()
        if let cached, cached.cwd != nil, cached.title != nil { return cached }

        let cwd = cached?.cwd ?? readClaudeCWD(url)
        let title = cached?.title ?? readClaudeTaskTitle(url)
        if cwd != nil || title != nil {
            cacheLock.lock()
            if claudeFactsCache.count >= cacheCap { claudeFactsCache.removeAll() }
            claudeFactsCache[key] = (cwd, title)
            cacheLock.unlock()
        }
        return (cwd, title)
    }

    private static func codexHeader(for url: URL) -> (cwd: String?, automation: Bool)? {
        let key = url.path
        cacheLock.lock()
        let cached = codexHeaderCache[key]
        cacheLock.unlock()
        if let cached { return cached }

        guard let firstLine = readUpToNewline(url, maxBytes: 1_048_576),
            let meta = parseJSONObject(firstLine),
            let payload = meta["payload"] as? [String: Any]
        else { return nil }
        let facts = (payload["cwd"] as? String, isAutomationCodexSession(payload))
        cacheLock.lock()
        if codexHeaderCache.count >= cacheCap { codexHeaderCache.removeAll() }
        codexHeaderCache[key] = facts
        cacheLock.unlock()
        return facts
    }

    private static func codexTitle(for url: URL) -> String? {
        let key = url.path
        cacheLock.lock()
        let cached = codexTitleCache[key]
        cacheLock.unlock()
        if let cached { return cached }

        guard let title = readCodexTaskTitle(url) else { return nil }
        cacheLock.lock()
        if codexTitleCache.count >= cacheCap { codexTitleCache.removeAll() }
        codexTitleCache[key] = title
        cacheLock.unlock()
        return title
    }

    // MARK: - Task titles

    /// Hard cap for the first-prompt-derived task title shown in the pill. Keep this tight:
    /// the pill is always on screen (and often screenshotted/screen-shared), so it must only
    /// ever show a hint of what the agent is doing, never a full prompt.
    private static let taskTitleMax = 48

    /// First non-empty prompt line, whitespace-collapsed and truncated to `taskTitleMax`.
    /// Rejects harness noise: XML-ish wrappers (`<system-reminder>`, `<command-name>`, …)
    /// and Claude Code "Caveat:" preambles.
    /// Internal (not private) so the rejection/truncation rules are unit-testable.
    static func sanitizeTitle(_ raw: String) -> String? {
        guard let firstLine = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        guard !firstLine.hasPrefix("<"), !firstLine.hasPrefix("Caveat:") else { return nil }
        let collapsed = firstLine
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > taskTitleMax else { return collapsed }
        return String(collapsed.prefix(taskTitleMax)) + "…"
    }

    /// First real user prompt in a Claude Code transcript (`type:"user"`, string content or
    /// the first text block; sidechains skipped). Scans only the leading chunk - a session
    /// whose first prompt sits past it just falls back to the project label.
    private static func readClaudeTaskTitle(_ url: URL) -> String? {
        guard let text = readUpToNewline(url, maxBytes: 262_144) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = parseJSONObject(String(line)),
                obj["type"] as? String == "user",
                obj["isSidechain"] as? Bool != true,
                let message = obj["message"] as? [String: Any]
            else { continue }
            let candidate: String?
            if let s = message["content"] as? String {
                candidate = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                candidate = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
            } else {
                candidate = nil
            }
            if let candidate, let title = sanitizeTitle(candidate) { return title }
        }
        return nil
    }

    /// First user prompt in a Codex rollout (`event_msg` with a `user_message` payload).
    private static func readCodexTaskTitle(_ url: URL) -> String? {
        guard let text = readUpToNewline(url, maxBytes: 262_144) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = parseJSONObject(String(line)),
                obj["type"] as? String == "event_msg",
                let payload = obj["payload"] as? [String: Any],
                payload["type"] as? String == "user_message",
                let message = payload["message"] as? String
            else { continue }
            if let title = sanitizeTitle(message) { return title }
        }
        return nil
    }

    /// Returns whether the most recent turn-relevant transcript entry indicates the agent is
    /// still working (`nil` if no relevant entry was found in the tail at all).
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

    private static func scanCodex(home: URL, now: Date) -> [AgentSession] {
        let root = home
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

            // Codex session_meta headers are large (~22 KB seen); a fixed 4 KB read used to
            // truncate mid-JSON and silently drop every Codex session. Read to the newline
            // (cached: the header never changes once written).
            guard let header = codexHeader(for: url) else { continue }
            guard !header.automation else { continue }

            let label = header.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "session"
            guard let turnInProgress = tailCodexTurnInProgress(url) else { continue }
            guard let state = classify(elapsed: elapsed, turnInProgress: turnInProgress) else { continue }

            sessions.append(
                AgentSession(
                    source: .codex,
                    projectLabel: label,
                    taskTitle: codexTitle(for: url),
                    projectPath: header.cwd,
                    state: state,
                    lastActivity: mtime
                )
            )
        }

        return sessions
    }

    private static func isAutomationCodexSession(_ payload: [String: Any]) -> Bool {
        let markers = ["exec", "automation", "subagent"]
        let originator = (payload["originator"] as? String)?.lowercased() ?? ""
        let source = (payload["source"] as? String)?.lowercased() ?? ""
        return markers.contains { originator.contains($0) || source.contains($0) }
    }

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

    // MARK: - Pi (pi agent)

    /// Pi logs JSONL under `~/.pi/agent/sessions/<encoded-cwd>--/<ISO>_<uuid>.jsonl`. Line 1
    /// is a `type:"session"` object carrying the real `cwd`; turn state comes from the last
    /// `type:"message"` line's inner `message.role` + `message.stopReason`.
    private static func scanPi(home: URL, now: Date) -> [AgentSession] {
        let root = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
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

            guard let cwd = readPiCWD(url) else { continue }
            guard let turnInProgress = tailPiTurnInProgress(url) else { continue }
            guard let state = classify(elapsed: elapsed, turnInProgress: turnInProgress) else { continue }

            sessions.append(
                AgentSession(
                    source: .pi,
                    projectLabel: URL(fileURLWithPath: cwd).lastPathComponent,
                    projectPath: cwd,
                    state: state,
                    lastActivity: mtime
                )
            )
        }
        return sessions
    }

    private static func readPiCWD(_ url: URL) -> String? {
        guard let line = readUpToNewline(url, maxBytes: 4096),
            let obj = parseJSONObject(line),
            obj["type"] as? String == "session"
        else { return nil }
        return obj["cwd"] as? String
    }

    /// Pi: a turn is COMPLETE only when the last message is an `assistant` that stopped on a
    /// terminal reason (`stop`/`aborted`). `toolUse`/`error` mean the model is still working,
    /// and a trailing `user`/`toolResult` means the turn is in progress.
    private static func tailPiTurnInProgress(_ url: URL) -> Bool? {
        let terminalStopReasons: Set<String> = ["stop", "aborted"]
        for line in tailLines(url).reversed() {
            guard let obj = parseJSONObject(line), obj["type"] as? String == "message" else { continue }
            let message = obj["message"] as? [String: Any]
            let role = message?["role"] as? String
            let stopReason = message?["stopReason"] as? String
            switch role {
            case "assistant":
                return !terminalStopReasons.contains(stopReason ?? "")
            case "user", "toolResult":
                return true
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - OpenCode

    /// OpenCode keeps sessions in a SQLite DB (`~/.local/share/opencode/opencode.db`, WAL).
    /// Live messages live in `message` (per-session `part` rows hold the rich content). Turn
    /// state: the newest `message` role plus the newest `step-finish` part's `reason` - a turn
    /// is complete only when role=`assistant` and reason=`stop`. Spawned subagents (whose
    /// `parent_id` resolves to another session row) are skipped, like Claude Code's
    /// `subagents/`. Read-only access is safe concurrent with a running opencode.
    private static func scanOpenCode(home: URL, now: Date) -> [AgentSession] {
        let db = home.appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }

        let cutoffMs = Int64((now.timeIntervalSince1970 - lookbackWindow) * 1000)
        let query = """
        WITH lm AS (
          SELECT session_id, data,
                 ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY time_created DESC, id DESC) rn
          FROM message
        ), lsf AS (
          SELECT session_id, json_extract(data,'$.reason') reason,
                 ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY time_created DESC, id DESC) rn
          FROM part WHERE json_extract(data,'$.type')='step-finish'
        )
        SELECT json_object('directory', s.directory, 'ms', s.time_updated,
                           'role', json_extract(lm.data,'$.role'), 'reason', lsf.reason)
        FROM session s
        LEFT JOIN lm  ON lm.session_id  = s.id AND lm.rn  = 1
        LEFT JOIN lsf ON lsf.session_id = s.id AND lsf.rn = 1
        WHERE s.time_updated >= \(cutoffMs)
          AND (s.parent_id IS NULL OR s.parent_id NOT IN (SELECT id FROM session))
        ORDER BY s.time_updated DESC;
        """

        guard let data = runSQLite(db: db, query: query), !data.isEmpty else { return [] }
        var sessions: [AgentSession] = []
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any] else { continue }
            guard let ms = (obj["ms"] as? NSNumber)?.int64Value else { continue }
            let lastActivity = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            let elapsed = now.timeIntervalSince(lastActivity)
            guard elapsed <= lookbackWindow else { continue }

            let directory = obj["directory"] as? String ?? "session"
            let role = obj["role"] as? String
            let reason = obj["reason"] as? String
            // Complete only on assistant + stop; anything else (user, tool-calls, no marker) is in progress.
            let turnInProgress = !(role == "assistant" && reason == "stop")
            guard let state = classify(elapsed: elapsed, turnInProgress: turnInProgress) else { continue }

            sessions.append(
                AgentSession(
                    source: .openCode,
                    projectLabel: URL(fileURLWithPath: directory).lastPathComponent,
                    projectPath: directory == "session" ? nil : directory,
                    state: state,
                    lastActivity: lastActivity
                )
            )
        }
        return sessions
    }

    /// Runs a read-only `sqlite3` query against `db` and returns its stdout. Returns nil if
    /// sqlite3 isn't available or the query fails (the DB is opened read-only so it can never
    /// be corrupted by a concurrent writer).
    private static func runSQLite(db: URL, query: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["file:\(db.path)?mode=ro", query]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    // MARK: - Shared

    /// Maps recency + turn state to a coarse activity state, or `nil` if the session should
    /// not be surfaced at all (e.g. a presumed-hung session now presumed dead).
    public static func classify(elapsed: TimeInterval, turnInProgress: Bool) -> AgentActivityState? {
        if turnInProgress {
            // Beyond `stalledSessionMax` with no file change, treat as dead, not stalled.
            guard elapsed <= stalledSessionMax else { return nil }
            return elapsed < stalledWindow ? .working : .stalled
        } else {
            return elapsed < needsYourTurnWindow ? .needsYourTurn : .idle
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Reads bytes from the start of `url` until (and including) the first newline, or until
    /// `maxBytes` is reached. Used for JSONL header lines that can be far larger than a
    /// single fixed read (Codex session_meta headers exceed 20 KB).
    private static func readUpToNewline(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        let chunk = 8192
        while buffer.count < maxBytes {
            let toRead = min(chunk, maxBytes - buffer.count)
            guard let part = try? handle.read(upToCount: toRead), !part.isEmpty else { break }
            buffer.append(part)
            if buffer.contains(0x0A) { break }
        }
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    /// Reads the tail of a transcript as whole lines, escalating the seek window until a turn
    /// signal is found (or the largest window is exhausted). The seek is trimmed to a newline
    /// boundary at the byte level before UTF-8 decoding, so a multibyte char split by the seek
    /// offset can't fail the decode and silently drop the session.
    private static func tailLines(_ url: URL) -> [String] {
        let fileSize = fileSize(of: url)
        guard fileSize > 0 else { return [] }

        for window in tailWindows where fileSize > UInt64(window) {
            if let lines = readTail(url: url, fileSize: fileSize, window: window), !lines.isEmpty {
                // Found content; return it (even an empty signal-bearing scan returns [] only
                // when there were no lines at all, in which case we escalate).
                return lines
            }
        }
        // File smaller than the smallest window (or all windows exhausted): read from start.
        return readTail(url: url, fileSize: fileSize, window: Int(fileSize)) ?? []
    }

    private static func readTail(url: URL, fileSize: UInt64, window: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let offset = fileSize > UInt64(window) ? fileSize - UInt64(window) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd()
        else { return nil }

        // Trim to the first newline at the BYTE level so we never decode a split multibyte char.
        let working: Data
        if offset > 0 {
            guard let nl = data.firstIndex(of: 0x0A) else {
                return nil // whole window is one truncated line; caller escalates.
            }
            working = data.suffix(from: data.index(after: nl))
        } else {
            working = data
        }

        guard let text = String(data: working, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func fileSize(of url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) ?? 0
    }

    private static func parseJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
