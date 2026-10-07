import Foundation

extension AgentActivityScanner {
    /// Pi agent sessions.
    struct PiSessionSource: AgentSessionSource {
        /// Pi logs JSONL under `~/.pi/agent/sessions/<encoded-cwd>--/<ISO>_<uuid>.jsonl`. Line 1
        /// is a `type:"session"` object carrying the real `cwd`; turn state comes from the last
        /// `type:"message"` line's inner `message.role` + `message.stopReason`.
        func scan(home: URL, now: Date, includeTaskTitles: Bool) -> [AgentSession] {
            let root = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
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

                guard let cwd = piCWD(for: url) else { continue }
                guard let turnInProgress = cachedTurnInProgress(for: url, stamp: stamp, signal: piTurnSignal) else { continue }
                guard let state = classify(elapsed: elapsed, turnInProgress: turnInProgress) else { continue }

                sessions.append(
                    AgentSession(
                        source: .pi,
                        projectLabel: URL(fileURLWithPath: cwd).lastPathComponent,
                        projectPath: cwd,
                        identityKey: identityKey(.pi, url.path),
                        state: state,
                        lastActivity: mtime
                    )
                )
            }
            return sessions
        }

        private func readPiCWD(_ url: URL) -> String? {
            guard let line = readFirstLine(url, maxBytes: 4096),
                let obj = parseJSONObject(line),
                obj["type"] as? String == "session"
            else { return nil }
            return obj["cwd"] as? String
        }

        /// The session header is immutable after Pi creates the file. Keep successful CWD reads
        /// behind the same bounded cache used for Claude/Codex facts; nil results deliberately
        /// retry because a just-created session may not have written its header yet.
        private func piCWD(for url: URL) -> String? {
            let key = url.path
            cacheLock.lock()
            let cached = piCWDCache[key]
            cacheLock.unlock()
            if let cached { return cached }

            guard let cwd = readPiCWD(url), !cwd.isEmpty else { return nil }
            cacheLock.lock()
            if piCWDCache.count >= cacheCap { piCWDCache.removeAll() }
            piCWDCache[key] = cwd
            cacheLock.unlock()
            return cwd
        }

        /// Pi: a turn is COMPLETE only when the last message is an `assistant` that stopped on a
        /// terminal reason (`stop`/`aborted`). `toolUse`/`error` mean the model is still working,
        /// and a trailing `user`/`toolResult` means the turn is in progress.
        private func piTurnSignal(_ obj: [String: Any]) -> Bool? {
            let terminalStopReasons: Set<String> = ["stop", "aborted"]
            guard obj["type"] as? String == "message" else { return nil }
            let message = obj["message"] as? [String: Any]
            let role = message?["role"] as? String
            let stopReason = message?["stopReason"] as? String
            switch role {
            case "assistant":
                return !terminalStopReasons.contains(stopReason ?? "")
            case "user", "toolResult":
                return true
            default:
                return nil
            }
        }
    }
}
