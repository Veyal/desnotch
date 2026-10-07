import Foundation

extension AgentActivityScanner {
    struct OpenCodeSessionSource: AgentSessionSource {
        /// OpenCode keeps sessions in a SQLite DB (`~/.local/share/opencode/opencode.db`, WAL).
        /// Live messages live in `message` (per-session `part` rows hold the rich content). Turn
        /// state: the newest `message` role plus the newest `step-finish` part's `reason` - a turn
        /// is complete only when role=`assistant` and reason=`stop`. Spawned subagents (whose
        /// `parent_id` resolves to another session row) are skipped, like Claude Code's
        /// `subagents/`. Read-only access is safe concurrent with a running opencode.
        ///
        /// The window functions are scoped to sessions updated inside the lookback window, so the
        /// query cost tracks recent activity rather than the whole (multi-GB) history.
        func scan(home: URL, now: Date, includeTaskTitles: Bool) -> [AgentSession] {
            let db = home.appendingPathComponent(".local/share/opencode/opencode.db")
            guard FileManager.default.fileExists(atPath: db.path) else { return [] }

            let cutoffMs = Int64((now.timeIntervalSince1970 - lookbackWindow) * 1000)
            let query = """
            WITH recent AS (
              SELECT id FROM session WHERE time_updated >= \(cutoffMs)
            ), lm AS (
              SELECT session_id, data,
                     ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY time_created DESC, id DESC) rn
              FROM message WHERE session_id IN (SELECT id FROM recent)
            ), lsf AS (
              SELECT session_id, json_extract(data,'$.reason') reason,
                     ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY time_created DESC, id DESC) rn
              FROM part
              WHERE session_id IN (SELECT id FROM recent) AND json_extract(data,'$.type')='step-finish'
            )
            SELECT json_object('id', s.id, 'directory', s.directory, 'ms', s.time_updated,
                               'role', json_extract(lm.data,'$.role'), 'reason', lsf.reason)
            FROM session s
            LEFT JOIN lm  ON lm.session_id  = s.id AND lm.rn  = 1
            LEFT JOIN lsf ON lsf.session_id = s.id AND lsf.rn = 1
            WHERE s.time_updated >= \(cutoffMs)
              AND (s.parent_id IS NULL OR s.parent_id NOT IN (SELECT id FROM session))
            ORDER BY s.time_updated DESC;
            """

            let signature = openCodeDatabaseSignature(db: db)
            let data: Data
            if let signature {
                cacheLock.lock()
                let cached = openCodeQueryCache.flatMap {
                    canReuseOpenCodeCache($0, signature: signature, now: now) ? $0.output : nil
                }
                cacheLock.unlock()
                if let cached {
                    // The database did not change (or only its WAL did, inside the throttle
                    // window); only recency classification depends on `now`.
                    data = cached
                } else {
                    guard let fresh = runSQLite(db: db, query: query) else { return [] }
                    // Opening a WAL database read-only can update its SHM mtime. Cache the
                    // post-query signature so that reader-only bookkeeping does not force a
                    // sqlite subprocess on every 5-second scan. If the database or WAL changed
                    // while the query was running, do not cache potentially stale output.
                    if let settled = openCodeDatabaseSignature(db: db),
                       settled.database == signature.database,
                       settled.wal == signature.wal
                    {
                        cacheLock.lock()
                        openCodeQueryCache = OpenCodeQueryCacheEntry(signature: settled, output: fresh, queriedAt: now)
                        cacheLock.unlock()
                    }
                    data = fresh
                }
            } else {
                guard let fresh = runSQLite(db: db, query: query) else { return [] }
                data = fresh
            }

            guard !data.isEmpty else { return [] }
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
                        identityKey: identityKey(.openCode, obj["id"] as? String ?? directory),
                        state: state,
                        lastActivity: lastActivity
                    )
                )
            }
            return sessions
        }

        /// SQLite may keep writes in its WAL/SHM sidecars while the main database mtime stays
        /// unchanged. Include all three files so a 5-second scan remains fresh without spawning
        /// sqlite3 when there was no write at all.
        private func openCodeDatabaseSignature(db: URL) -> OpenCodeDatabaseSignature? {
            guard let database = fileSignature(db) else { return nil }
            return OpenCodeDatabaseSignature(
                path: db.path,
                database: database,
                wal: fileSignature(URL(fileURLWithPath: db.path + "-wal")),
                shm: fileSignature(URL(fileURLWithPath: db.path + "-shm"))
            )
        }

        /// Carries the subprocess result out of the async runner to the synchronous scan.
        private final class SQLiteResultBox: @unchecked Sendable {
            var output: Data?
        }

        /// Runs a read-only `sqlite3` query against `db` through `SubprocessRunner` (own process
        /// group, hard timeout, capped output, drained pipes) and returns its stdout. Returns nil
        /// if sqlite3 isn't available, the query fails, or it times out (the DB is opened
        /// read-only so it can never be corrupted by a concurrent writer). Blocks the calling
        /// thread, which is off the main actor; the controller invokes the scan from a plain
        /// dispatch queue so no Swift-concurrency pool thread is parked here.
        private func runSQLite(db: URL, query: String) -> Data? {
    #if DEBUG
            cacheLock.lock()
            openCodeQueryExecutionCount += 1
            cacheLock.unlock()
    #endif
            let runner = SubprocessRunner(outputByteCap: openCodeOutputByteCap)
            let box = SQLiteResultBox()
            let finished = DispatchSemaphore(value: 0)
            let arguments = ["file:\(db.path)?mode=ro", query]
            let workingDirectory = db.deletingLastPathComponent()
            let timeout = openCodeQueryTimeout
            Task.detached(priority: .utility) {
                defer { finished.signal() }
                guard let result = try? await runner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                    arguments: arguments,
                    cwd: workingDirectory,
                    timeout: timeout
                ), result.exitCode == 0 else { return }
                box.output = Data(result.stdout.utf8)
            }
            // The runner enforces `timeout`; the extra slack only covers process teardown.
            guard finished.wait(timeout: .now() + timeout + 10) == .success else { return nil }
            return box.output
        }
    }

    /// Cached output is reusable when nothing changed, or when only the WAL/SHM sidecars
    /// changed and the last query is younger than `openCodeWALThrottle` (committed writes land
    /// in the WAL long before a checkpoint touches the main file). A changed main database
    /// file always forces a fresh query. Pure so the policy is unit-testable.
    static func canReuseOpenCodeCache(
        _ entry: OpenCodeQueryCacheEntry, signature: OpenCodeDatabaseSignature, now: Date
    ) -> Bool {
        if entry.signature == signature { return true }
        guard entry.signature.path == signature.path,
            entry.signature.database == signature.database
        else { return false }
        let age = now.timeIntervalSince(entry.queriedAt)
        return age >= 0 && age < openCodeWALThrottle
    }
}
