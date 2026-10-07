import Foundation

extension AgentActivityScanner {
    /// Claude Code transcripts: `~/.claude/projects/<encoded-cwd>/<session>.jsonl`.
    struct ClaudeCodeSessionSource: AgentSessionSource {
        func scan(home: URL, now: Date, includeTaskTitles: Bool) -> [AgentSession] {
            let root = home
                .appendingPathComponent(".claude/projects", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            let rootDepth = root.pathComponents.count
            var sessions: [AgentSession] = []

            for case let url as URL in enumerator {
                // Sub-agent transcript trees can be thousands of files deep; never descend.
                if url.lastPathComponent == "subagents" {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "jsonl" else { continue }
                guard url.pathComponents.count > rootDepth else { continue }

                let fileName = url.lastPathComponent
                if fileName.hasPrefix("agent-") { continue }
                guard let stamp = fileSignature(url) else { continue }
                let mtime = stamp.modificationDate
                let elapsed = now.timeIntervalSince(mtime)
                guard elapsed <= lookbackWindow else { continue }

                // Headless runs (`claude -p`, workflow runners: `entrypoint` "sdk-cli") are the same
                // fan-out as Codex `exec`; an immutable per-file fact, so cached with the cwd.
                let facts = claudeFacts(for: url)
                if facts?.headless == true { continue }

                guard let turnInProgress = cachedTurnInProgress(for: url, stamp: stamp, signal: claudeTurnSignal) else { continue }
                guard let state = classify(elapsed: elapsed, turnInProgress: turnInProgress) else { continue }

                let cwd = facts?.cwd
                let title = includeTaskTitles
                    ? taskTitle(for: url, size: stamp.size, read: readClaudeTaskTitle)
                    : nil
                sessions.append(
                    AgentSession(
                        source: .claudeCode,
                        // Never fall back to the encoded project directory name: it is a mangled
                        // path, not a label. Unknown cwd -> a generic word.
                        projectLabel: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "project",
                        taskTitle: title,
                        projectPath: cwd,
                        identityKey: identityKey(.claudeCode, url.path),
                        state: state,
                        lastActivity: mtime
                    )
                )
            }

            return sessions
        }

        /// Reads the real working directory and entrypoint from a Claude Code transcript's header
        /// lines (a `user`/`assistant`/`attachment` entry carries `cwd` and `entrypoint`). Only the
        /// first chunk is scanned, and only whole lines of it are decoded.
        private func readClaudeFacts(_ url: URL) -> ClaudeFacts? {
            guard let head = readHead(url, maxBytes: claudeCWDHeadBytes) else { return nil }
            for line in completeLines(in: head, maxBytes: claudeCWDHeadBytes) {
                guard let obj = parseJSONObject(line) else { continue }
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    return ClaudeFacts(cwd: cwd, headless: obj["entrypoint"] as? String == "sdk-cli")
                }
            }
            return nil
        }

        private func claudeFacts(for url: URL) -> ClaudeFacts? {
            let key = url.path
            cacheLock.lock()
            let cached = claudeCWDCache[key]
            cacheLock.unlock()
            if let cached { return cached }

            guard let facts = readClaudeFacts(url) else { return nil }
            cacheLock.lock()
            if claudeCWDCache.count >= cacheCap { claudeCWDCache.removeAll() }
            claudeCWDCache[key] = facts
            cacheLock.unlock()
            return facts
        }

        /// First real user prompt in a Claude Code transcript (`type:"user"`, string content or
        /// the first text block; sidechains skipped). Scans only the leading `titleHeadBytes` - a
        /// session whose first prompt sits past it just falls back to the project label.
        private func readClaudeTaskTitle(_ url: URL) -> String? {
            guard let head = readHead(url, maxBytes: titleHeadBytes) else { return nil }
            for line in completeLines(in: head, maxBytes: titleHeadBytes) {
                guard let obj = parseJSONObject(line),
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

        private func isInterruptEntry(_ obj: [String: Any]) -> Bool {
            guard let message = obj["message"] as? [String: Any] else { return false }
            let text: String?
            if let s = message["content"] as? String {
                text = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
            } else {
                text = nil
            }
            return text?.hasPrefix("[Request interrupted by user") == true
        }

        /// Whether this transcript line settles the turn state: `true` while the agent is working,
        /// `false` once the turn completed, `nil` for lines that carry no turn signal.
        private func claudeTurnSignal(_ obj: [String: Any]) -> Bool? {
            guard let type = obj["type"] as? String else { return nil }
            switch type {
            case "assistant":
                let stopReason = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                return stopReason == "tool_use"
            case "user":
                // An interrupted turn appends a synthetic user entry; the agent is waiting on the
                // user, not working. Only the prefix is inspected and nothing leaves the scanner.
                return !isInterruptEntry(obj)
            default:
                return nil
            }
        }
    }
}
