import Foundation
@testable import DesnotchCore

/// Test doubles for the machine-control tools (prefix `Tools`). Nothing here touches the real
/// workspace, clipboard, network or a process.

/// Fake AppKit side: records what would have happened.
@MainActor
final class ToolsFakeSystem: AgentSystemServing {
    var intents: [LocalIntent] = []
    var opened: [URL] = []
    var launched: [String] = []
    var clipboard: String? = "clipboard secret"

    func execute(_ intent: LocalIntent) async -> LocalExecutionResult {
        intents.append(intent)
        return .success(spoken: "ok")
    }

    func resolveApp(_ query: String) -> AgentAppMatch? {
        query.lowercased() == "safari" ? AgentAppMatch(bundleID: "com.apple.Safari", name: "Safari") : nil
    }

    func launchApp(_ match: AgentAppMatch) async -> Bool {
        launched.append(match.bundleID)
        return true
    }

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return true
    }

    func readClipboard() -> String? { clipboard }

    func writeClipboard(_ text: String) -> Bool {
        clipboard = text
        return true
    }

    func snapshot() -> AgentSystemSnapshot {
        AgentSystemSnapshot(date: Date(timeIntervalSince1970: 0), timeZone: "UTC")
    }
}

/// Scripted process runner: records every run and answers with `reply`.
/// Thread safety: guarded by `lock`.
final class ToolsScriptedRunner: AgentProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let reply: AgentProcessOutcome

    init(reply: AgentProcessOutcome = .finished(exitCode: 0, output: "done", truncated: false)) {
        self.reply = reply
    }

    var runs: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(executable: String, arguments: [String], cwd: URL, input: Data?, timeout: TimeInterval) async -> AgentProcessOutcome {
        record([executable] + arguments)
        return reply
    }

    private func record(_ argv: [String]) {
        lock.lock(); recorded.append(argv); lock.unlock()
    }
}

/// Scripted fetcher: never touches the network. Thread safety: guarded by `lock`.
final class ToolsScriptedFetcher: AgentWebFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private let reply: AgentFetchResult

    init(reply: AgentFetchResult = .page(status: 200, contentType: "text/html", text: "page text")) {
        self.reply = reply
    }

    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return recorded }

    func fetch(_ url: URL) async -> AgentFetchResult {
        record(url)
        return reply
    }

    private func record(_ url: URL) {
        lock.lock(); recorded.append(url); lock.unlock()
    }
}

/// Records audit drafts. Thread safety: guarded by `lock`.
final class ToolsRecordingAudit: AuditLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AuditDraft] = []

    var drafts: [AuditDraft] { lock.lock(); defer { lock.unlock() }; return recorded }

    func append(_ draft: AuditDraft) async -> Bool {
        record(draft)
        return true
    }

    func verify() async -> AuditVerification { .empty }

    private func record(_ draft: AuditDraft) {
        lock.lock(); recorded.append(draft); lock.unlock()
    }
}

/// Collects backend events and answers cards on cue. Thread safety: guarded by `lock`.
final class ToolsEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentEvent] = []

    var events: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return recorded }

    func append(_ event: AgentEvent) {
        lock.lock(); recorded.append(event); lock.unlock()
    }

    var cards: [ConfirmationRequest] {
        events.compactMap { event in
            if case .approvalNeeded(let request) = event { return request }
            return nil
        }
    }

    var steps: [String] {
        events.compactMap { event in
            if case .toolActivity(let kind) = event { return kind }
            return nil
        }
    }
}

/// A temporary stand-in for home: `Documents/notes.txt`, `Downloads`, `Library/LaunchAgents`,
/// `.config`, a `scratch` folder and a denied `voice` folder. Created per test instance and
/// removed in `tearDown`; no test ever touches the real home folder.
struct ToolsFixture: Sendable {
    let root: URL
    let paths: AgentPathContext

    init(_ prefix: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        root = AgentToolPaths.canonical(base)
        let home = root.appendingPathComponent("home")
        let fm = FileManager.default
        for folder in ["Documents", "Downloads", "Library/LaunchAgents", ".config", "scratch", "voice"] {
            try? fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try? Data("hello\nworld\n".utf8).write(to: home.appendingPathComponent("Documents/notes.txt"))
        paths = AgentPathContext(
            home: home,
            scratch: home.appendingPathComponent("scratch"),
            denied: [home.appendingPathComponent("voice")]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
