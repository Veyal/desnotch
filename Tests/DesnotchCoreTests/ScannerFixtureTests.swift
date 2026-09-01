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
        let changed = AgentActivityScanner.scan(home: home, now: now.addingTimeInterval(10))
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
