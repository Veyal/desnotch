import XCTest
@testable import DesnotchCore

final class ScannerFixtureTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        AgentActivityScanner.dropCaches()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("desnotch-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        AgentActivityScanner.dropCaches()
        super.tearDown()
    }

    // MARK: Codex

    func testCodexLargeHeaderIsNotDropped() throws {
        // Real Codex session_meta headers exceed 20 KB; a fixed 4 KB read used to truncate
        // mid-JSON and drop every session. Verify a >4 KB header still parses.
        let big = String(repeating: "x", count: 30_000)
        let header = #"{"type":"session_meta","payload":{"cwd":"/Users/demo/acme-app","originator":"cli","source":"interop","base_instructions":"\#(big)"}}"#
        let event = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        try writeCodexFile(name: "rollout-a.jsonl", lines: [header, event])

        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        let codex = sessions.filter { $0.source == .codex }
        XCTAssertEqual(codex.count, 1)
        // cwd basename, not a mangled dash-split.
        XCTAssertEqual(codex.first?.projectLabel, "acme-app")
        XCTAssertEqual(codex.first?.state, .working)
    }

    func testCodexAutomationSessionsSkipped() throws {
        let header = #"{"type":"session_meta","payload":{"cwd":"/p","originator":"codex_exec","source":"exec"}}"#
        let event = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        try writeCodexFile(name: "rollout-auto.jsonl", lines: [header, event])
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertTrue(sessions.filter { $0.source == .codex }.isEmpty)
    }

    func testCodexTaskCompleteYieldsNeedsYourTurn() throws {
        let header = #"{"type":"session_meta","payload":{"cwd":"/p","originator":"cli","source":"interop"}}"#
        let event = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        try writeCodexFile(name: "rollout-done.jsonl", lines: [header, event])
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.first?.state, .needsYourTurn)
    }

    func testCodexSubagentObjectSourceSkipped() throws {
        // Sub-agent rollouts carry an object `source` ({"subagent":{...}}) under a `codex-tui`
        // originator; a string-only check counted them as real sessions.
        let header = #"{"type":"session_meta","payload":{"cwd":"/p","originator":"codex-tui","source":{"subagent":{"thread_spawn":{"parent_thread_id":"abc","depth":1}}}}}"#
        let event = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        try writeCodexFile(name: "rollout-sub.jsonl", lines: [header, event])
        XCTAssertTrue(AgentActivityScanner.scan(home: home, now: Date()).filter { $0.source == .codex }.isEmpty)
    }

    func testCodexTurnAbortedYieldsNeedsYourTurn() throws {
        let header = #"{"type":"session_meta","payload":{"cwd":"/p","originator":"cli","source":"interop"}}"#
        try writeCodexFile(name: "rollout-abort.jsonl", lines: [
            header,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#,
        ])
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.first?.state, .needsYourTurn)
    }

    // MARK: Claude Code

    func testClaudeCwdLabelNotMangledByDashes() throws {
        // Encoded dir would mangle "acme-app" to "tracker"; the transcript's cwd
        // must recover the real basename.
        let dir = "-Users-demo-acme-app"
        let lines = [
            #"{"type":"summary","leafUuid":"x","sessionId":"s"}"#,
            #"{"type":"user","cwd":"/Users/demo/acme-app"}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
        ]
        try writeClaudeFile(projectDir: dir, name: "sess.jsonl", lines: lines)

        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        let claude = sessions.filter { $0.source == .claudeCode }
        XCTAssertEqual(claude.count, 1)
        XCTAssertEqual(claude.first?.projectLabel, "acme-app")
        XCTAssertEqual(claude.first?.state, .working)
    }

    func testClaudeEndTurnIsNeedsYourTurn() throws {
        let dir = "-Users-demo-proj"
        let lines = [
            #"{"type":"user","cwd":"/Users/demo/proj"}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ]
        try writeClaudeFile(projectDir: dir, name: "sess.jsonl", lines: lines)
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.first?.state, .needsYourTurn)
    }

    func testClaudeSubagentFilesSkipped() throws {
        try writeClaudeFile(projectDir: "-Users-demo-proj", name: "agent-abc.jsonl", lines: [
            #"{"type":"user","cwd":"/Users/demo/proj"}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
        ])
        try writeClaudeSubagentFile(lines: [
            #"{"type":"user","cwd":"/Users/demo/proj"}"#,
        ])
        XCTAssertTrue(AgentActivityScanner.scan(home: home, now: Date()).isEmpty)
    }

    func testClaudeInterruptedByUserIsNeedsYourTurn() throws {
        try writeClaudeFile(projectDir: "-Users-demo-proj", name: "sess.jsonl", lines: [
            #"{"type":"user","cwd":"/Users/demo/proj","message":{"role":"user","content":"do it"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
        ])
        XCTAssertEqual(AgentActivityScanner.scan(home: home, now: Date()).first?.state, .needsYourTurn)
    }

    func testClaudeHeadlessSdkCliRunsSkipped() throws {
        try writeClaudeFile(projectDir: "-Users-demo-proj", name: "headless.jsonl", lines: [
            #"{"type":"user","cwd":"/Users/demo/proj","entrypoint":"sdk-cli","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ])
        try writeClaudeFile(projectDir: "-Users-demo-proj", name: "human.jsonl", lines: [
            #"{"type":"user","cwd":"/Users/demo/proj","entrypoint":"cli","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ])
        XCTAssertEqual(AgentActivityScanner.scan(home: home, now: Date()).count, 1)
    }

    // MARK: Tail window / boundaries

    func testGiantSingleEntrySurvivesTailEscalation() throws {
        // A single JSONL line larger than the 64 KiB tail window must not drop the session;
        // the seek window escalates until the line fits.
        let big = String(repeating: "a", count: 70_000)
        let dir = "-Users-demo-proj"
        let lines = [
            #"{"type":"user","cwd":"/Users/demo/proj"}"#,
            #"{"type":"filler","data":"\#(big)"}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ]
        try writeClaudeFile(projectDir: dir, name: "sess.jsonl", lines: lines)
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.first?.state, .needsYourTurn)
    }

    func testMultibyteContentInTailParses() throws {
        // Multibyte (emoji) content in the parsed region must not fail UTF-8 decoding.
        let padding = String(repeating: "p", count: 65_600)
        let dir = "-Users-demo-proj"
        let lines = [
            #"{"type":"user","cwd":"/Users/demo/proj"}"#,
            #"{"type":"filler","data":"\#(padding)"}"#,
            #"{"type":"user","message":"🎵 working on it"}"#,
        ]
        try writeClaudeFile(projectDir: dir, name: "sess.jsonl", lines: lines)
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        // A trailing user entry means a turn is in progress.
        XCTAssertEqual(sessions.first?.state, .working)
    }

    func testClaudeUnknownCwdUsesGenericLabelNotEncodedDirectory() throws {
        // No transcript line carries a cwd: the label must be the generic word, never the
        // mangled project directory name (which leaks a path-ish string into the pill).
        try writeClaudeFile(projectDir: "-Users-demo-secret-client", name: "sess.jsonl", lines: [
            #"{"type":"user","message":{"content":"hello"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ])
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.first?.projectLabel, "project")
        XCTAssertNil(sessions.first?.projectPath)
    }

    func testClaudeCwdSurvivesMultibyteCharacterSplitAtHeadBoundary() throws {
        // The cwd header read is capped at 32 KiB. Put a 4-byte emoji so the cap lands one
        // byte inside it: decoding the raw prefix as UTF-8 used to fail and drop the cwd.
        let first = #"{"type":"user","cwd":"/Users/demo/proj"}"#
        let fillerPrefix = #"{"type":"filler","data":""#
        let leadBytes = (first + "\n" + fillerPrefix).utf8.count
        let pad = String(repeating: "a", count: 32_767 - leadBytes)
        let emoji = String(repeating: "🎵", count: 64)
        try writeClaudeFile(projectDir: "-Users-demo-other", name: "sess.jsonl", lines: [
            first,
            fillerPrefix + pad + emoji + #""}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ])
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.first?.projectLabel, "proj")
    }

    func testCodexHeaderWithMultibyteContentAcrossReadChunkIsNotDropped() throws {
        // The header is read in 8 KiB chunks; a chunk boundary inside a multibyte character
        // after the newline must not fail the decode of the (already complete) first line.
        // Place the first 2-byte "é" at offset 8191 so the first chunk ends mid-character.
        let header = #"{"type":"session_meta","payload":{"cwd":"/Users/demo/acme-app","originator":"cli","source":"interop"}}"#
        let eventPrefix = #"{"type":"event_msg","payload":{"type":"agent_message","message":""#
        let pad = String(repeating: "a", count: 8_191 - (header.utf8.count + 1) - eventPrefix.utf8.count)
        let filler = String(repeating: "é", count: 200)
        try writeCodexFile(name: "rollout-mb.jsonl", lines: [
            header,
            eventPrefix + pad + filler + #""}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
        ])
        let codex = AgentActivityScanner.scan(home: home, now: Date()).filter { $0.source == .codex }
        XCTAssertEqual(codex.first?.projectLabel, "acme-app")
        XCTAssertEqual(codex.first?.state, .needsYourTurn)
    }

    // MARK: Tail escalation

    func testTailEscalatesWhenWindowHoldsLinesButNoTurnSignal() throws {
        // 90 filler lines (~90 KB) after the last turn marker: the first 64 KiB window is
        // non-empty but signal-free. It used to stop there and drop the session.
        let chunk = String(repeating: "x", count: 1_000)
        var lines = [
            #"{"type":"user","cwd":"/Users/demo/proj"}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ]
        lines += (0..<90).map { _ in #"{"type":"filler","data":"\#(chunk)"}"# }
        try writeClaudeFile(projectDir: "-Users-demo-proj", name: "sess.jsonl", lines: lines)
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.first?.state, .needsYourTurn)
    }

    func testTailEscalatesPastGiantTrailingEntry() throws {
        let big = String(repeating: "a", count: 70_000)
        try writeClaudeFile(projectDir: "-Users-demo-proj", name: "sess.jsonl", lines: [
            #"{"type":"user","cwd":"/Users/demo/proj"}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
            #"{"type":"filler","data":"\#(big)"}"#,
        ])
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.first?.state, .needsYourTurn)
    }

    // MARK: Turn-state cache

#if DEBUG
    func testUnchangedTranscriptReusesCachedTurnStateAndPrunesWhenGone() throws {
        let fixed = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate))
        let dir = "-Users-demo-proj"
        let user = #"{"type":"user","cwd":"/Users/demo/proj"}"#
        // "end_turn" and "tool_use" are the same length, so a rewrite keeps the file size.
        try writeClaudeFile(projectDir: dir, name: "sess.jsonl", lines: [
            user, #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ])
        let file = home.appendingPathComponent(".claude/projects/\(dir)/sess.jsonl")
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: file.path)

        XCTAssertEqual(AgentActivityScanner.scan(home: home, now: fixed).first?.state, .needsYourTurn)

        try writeClaudeFile(projectDir: dir, name: "sess.jsonl", lines: [
            user, #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
        ])
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: file.path)
        XCTAssertEqual(
            AgentActivityScanner.scan(home: home, now: fixed).first?.state, .needsYourTurn,
            "same (mtime, size) must come from the cache, not a re-read"
        )

        // A real change (new mtime) is re-read.
        try FileManager.default.setAttributes(
            [.modificationDate: fixed.addingTimeInterval(1)], ofItemAtPath: file.path
        )
        XCTAssertEqual(
            AgentActivityScanner.scan(home: home, now: fixed.addingTimeInterval(1)).first?.state, .working
        )

        XCTAssertEqual(AgentActivityScanner.turnCacheCountForTesting(), 1)
        try FileManager.default.removeItem(at: file)
        _ = AgentActivityScanner.scan(home: home, now: fixed.addingTimeInterval(2))
        XCTAssertEqual(AgentActivityScanner.turnCacheCountForTesting(), 0)
    }
#endif

    // MARK: Task titles (opt-in)

    func testTaskTitlesAreOffByDefault() throws {
        try writeClaudeFile(projectDir: "-Users-demo-proj", name: "sess.jsonl", lines: [
            #"{"type":"user","cwd":"/Users/demo/proj","message":{"content":"Secret client prompt"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
        ])
        try writeCodexFile(name: "rollout-t.jsonl", lines: [
            #"{"type":"session_meta","payload":{"cwd":"/p","originator":"cli","source":"interop"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Another secret"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        ])
        let sessions = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.taskTitle == nil })
    }

    func testClaudeTitleComesFromFirstUserPromptNotJustFirstLine() throws {
        try writeClaudeFile(projectDir: "-Users-demo-proj", name: "sess.jsonl", lines: [
            #"{"type":"summary","leafUuid":"x"}"#,
            #"{"type":"user","cwd":"/Users/demo/proj","message":{"content":"Refactor the login flow"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
        ])
        let sessions = AgentActivityScanner.scan(home: home, now: Date(), includeTaskTitles: true)
        XCTAssertEqual(sessions.first?.taskTitle, "Refactor the login flow")
    }

    func testCodexTitleResolvesPastSessionMetaHeader() throws {
        try writeCodexFile(name: "rollout-title.jsonl", lines: [
            #"{"type":"session_meta","payload":{"cwd":"/Users/demo/acme-app","originator":"cli","source":"interop"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Fix the flaky sync test"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        ])
        let codex = AgentActivityScanner.scan(home: home, now: Date(), includeTaskTitles: true)
            .filter { $0.source == .codex }
        XCTAssertEqual(codex.first?.taskTitle, "Fix the flaky sync test")
    }

    func testMissingTitleRetryPolicy() {
        let head = UInt64(AgentActivityScanner.titleHeadBytes)
        // Small file fully scanned: only a grown file is worth re-reading.
        XCTAssertFalse(AgentActivityScanner.shouldRetryMissingTitle(scannedSize: 500, currentSize: 500))
        XCTAssertTrue(AgentActivityScanner.shouldRetryMissingTitle(scannedSize: 500, currentSize: 900))
        // Head window exhausted: nothing appended later can fall inside it.
        XCTAssertFalse(AgentActivityScanner.shouldRetryMissingTitle(scannedSize: head, currentSize: head + 10))
        XCTAssertFalse(AgentActivityScanner.shouldRetryMissingTitle(scannedSize: head + 5, currentSize: head * 4))
    }

    // MARK: Session identity

    func testSameProjectSessionsGetDistinctOpaqueIdentityKeys() throws {
        for name in ["sess-a.jsonl", "sess-b.jsonl"] {
            try writeClaudeFile(projectDir: "-Users-demo-proj", name: name, lines: [
                #"{"type":"user","cwd":"/Users/demo/proj"}"#,
                #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
            ])
        }
        let first = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(Set(first.map(\.identityKey)).count, 2)
        for session in first {
            XCTAssertFalse(session.identityKey.contains("sess"), "identity is a hash, not a path")
            XCTAssertFalse(session.identityKey.contains("proj"))
        }
        // Stable across scans.
        let second = AgentActivityScanner.scan(home: home, now: Date())
        XCTAssertEqual(Set(first.map(\.identityKey)), Set(second.map(\.identityKey)))
    }

    // MARK: OpenCode cache policy

    func testOpenCodeCacheThrottlesWALOnlyChangesButNotDatabaseChanges() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let db = AgentActivityScanner.FileSignature(size: 100, modificationDate: t0)
        let wal1 = AgentActivityScanner.FileSignature(size: 10, modificationDate: t0)
        let wal2 = AgentActivityScanner.FileSignature(size: 20, modificationDate: t0.addingTimeInterval(1))
        let cached = AgentActivityScanner.OpenCodeQueryCacheEntry(
            signature: .init(path: "/x/opencode.db", database: db, wal: wal1, shm: nil),
            output: Data(),
            queriedAt: t0
        )
        let walOnly = AgentActivityScanner.OpenCodeDatabaseSignature(
            path: "/x/opencode.db", database: db, wal: wal2, shm: nil
        )
        let throttle = AgentActivityScanner.openCodeWALThrottle

        XCTAssertTrue(AgentActivityScanner.canReuseOpenCodeCache(cached, signature: cached.signature, now: t0.addingTimeInterval(throttle * 10)))
        XCTAssertTrue(AgentActivityScanner.canReuseOpenCodeCache(cached, signature: walOnly, now: t0.addingTimeInterval(throttle - 1)))
        XCTAssertFalse(AgentActivityScanner.canReuseOpenCodeCache(cached, signature: walOnly, now: t0.addingTimeInterval(throttle)))

        let newDB = AgentActivityScanner.FileSignature(size: 200, modificationDate: t0.addingTimeInterval(1))
        let dbChanged = AgentActivityScanner.OpenCodeDatabaseSignature(
            path: "/x/opencode.db", database: newDB, wal: wal1, shm: nil
        )
        XCTAssertFalse(AgentActivityScanner.canReuseOpenCodeCache(cached, signature: dbChanged, now: t0.addingTimeInterval(1)))
    }

#if DEBUG
    func testOpenCodeCacheReusesUnchangedDatabaseAndInvalidatesAfterWrite() throws {
        let database = try makeOpenCodeDatabase()
        let now = Date()

        let first = AgentActivityScanner.scan(home: home, now: now)
        XCTAssertEqual(first.map(\.projectLabel), ["alpha"])
        XCTAssertEqual(AgentActivityScanner.openCodeQueryExecutionCountForTesting(), 1)

        let unchanged = AgentActivityScanner.scan(home: home, now: now.addingTimeInterval(5))
        XCTAssertEqual(unchanged.map(\.projectLabel), ["alpha"])
        XCTAssertEqual(
            AgentActivityScanner.openCodeQueryExecutionCountForTesting(), 1,
            "an unchanged WAL database should reuse cached query output"
        )

        try runSQLite(
            database: database,
            sql: """
            INSERT INTO session VALUES('beta', '/projects/beta', \(Int64(now.timeIntervalSince1970 * 1_000)), NULL);
            INSERT INTO message VALUES('m-beta', 'beta', '{"role":"user"}', 1);
            """
        )
        let changed = AgentActivityScanner.scan(home: home, now: now.addingTimeInterval(30))
        XCTAssertEqual(changed.map(\.projectLabel).sorted(), ["alpha", "beta"])
        XCTAssertEqual(AgentActivityScanner.openCodeQueryExecutionCountForTesting(), 2)
    }
#endif

    // MARK: helpers

    private func writeCodexFile(name: String, lines: [String]) throws {
        let dir = home.appendingPathComponent(".codex/sessions/2026/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    private func writeClaudeFile(projectDir: String, name: String, lines: [String]) throws {
        let dir = home.appendingPathComponent(".claude/projects/\(projectDir)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    private func writeClaudeSubagentFile(lines: [String]) throws {
        let dir = home.appendingPathComponent(".claude/projects/-Users-demo-proj/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("sess2.jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func makeOpenCodeDatabase() throws -> URL {
        let directory = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("opencode.db")
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        try runSQLite(
            database: database,
            sql: """
            PRAGMA journal_mode=WAL;
            CREATE TABLE session(id TEXT PRIMARY KEY, directory TEXT, time_updated INTEGER, parent_id TEXT);
            CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER);
            CREATE TABLE part(id TEXT, session_id TEXT, data TEXT, time_created INTEGER);
            INSERT INTO session VALUES('alpha', '/projects/alpha', \(nowMilliseconds), NULL);
            INSERT INTO message VALUES('m-alpha', 'alpha', '{"role":"assistant"}', 1);
            INSERT INTO part VALUES('p-alpha', 'alpha', '{"type":"step-finish","reason":"stop"}', 1);
            """
        )
        return database
    }

    private func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
