import Foundation

extension AgentActivityScanner {
    /// Codex CLI rollouts: `~/.codex/sessions/**/*.jsonl`.
    struct CodexSessionSource: AgentSessionSource {
        func scan(home: URL, now: Date, includeTaskTitles: Bool) -> [AgentSession] {
            let root = home
                .appendingPathComponent(".codex/sessions", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var sessions: [AgentSession] = []

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }

                guard let stamp = fileSignature(url) else { continue }
                let mtime = stamp.modificationDate
                let elapsed = now.timeIntervalSince(mtime)
                guard elapsed <= lookbackWindow else { continue }

                // Codex session_meta headers are large (~22 KB seen); a fixed 4 KB read used to
                // truncate mid-JSON and silently drop every Codex session. Read to the newline
                // (cached: the header never changes once written).
                guard let header = codexHeader(for: url) else { continue }
                guard !header.automation else { continue }

                let label = header.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "session"
                guard let turnInProgress = cachedTurnInProgress(for: url, stamp: stamp, signal: codexTurnSignal) else { continue }
                guard let state = classify(elapsed: elapsed, turnInProgress: turnInProgress) else { continue }

                sessions.append(
                    AgentSession(
                        source: .codex,
                        projectLabel: label,
                        taskTitle: includeTaskTitles
                            ? taskTitle(for: url, size: stamp.size, read: readCodexTaskTitle)
                            : nil,
                        projectPath: header.cwd,
                        identityKey: identityKey(.codex, url.path),
                        state: state,
                        lastActivity: mtime
                    )
                )
            }

            return sessions
        }

        private func isAutomationCodexSession(_ payload: [String: Any]) -> Bool {
            let markers = ["exec", "automation", "subagent"]
            let originator = (payload["originator"] as? String)?.lowercased() ?? ""
            // Sub-agents carry an object source ({"subagent": {...}}), not a string.
            if let sourceObject = payload["source"] as? [String: Any],
                sourceObject.keys.contains(where: { $0.lowercased().contains("subagent") }) {
                return true
            }
            let source = (payload["source"] as? String)?.lowercased() ?? ""
            return markers.contains { originator.contains($0) || source.contains($0) }
        }

        private func codexTurnSignal(_ obj: [String: Any]) -> Bool? {
            guard obj["type"] as? String == "event_msg",
                let payloadType = (obj["payload"] as? [String: Any])?["type"] as? String
            else { return nil }
            switch payloadType {
            case "task_started":
                return true
            case "task_complete", "turn_aborted":
                // An interrupted turn is waiting on the user, same as a completed one.
                return false
            default:
                return nil
            }
        }

        private func codexHeader(for url: URL) -> (cwd: String?, automation: Bool)? {
            let key = url.path
            cacheLock.lock()
            let cached = codexHeaderCache[key]
            cacheLock.unlock()
            if let cached { return cached }

            guard let firstLine = readFirstLine(url, maxBytes: 1_048_576),
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

        /// First user prompt in a Codex rollout (`event_msg` with a `user_message` payload). The
        /// first line is `session_meta`, so this reads the head of the file, not just line one.
        private func readCodexTaskTitle(_ url: URL) -> String? {
            guard let head = readHead(url, maxBytes: titleHeadBytes) else { return nil }
            for line in completeLines(in: head, maxBytes: titleHeadBytes) {
                guard let obj = parseJSONObject(line),
                    obj["type"] as? String == "event_msg",
                    let payload = obj["payload"] as? [String: Any],
                    payload["type"] as? String == "user_message",
                    let message = payload["message"] as? String
                else { continue }
                if let title = sanitizeTitle(message) { return title }
            }
            return nil
        }
    }
}
