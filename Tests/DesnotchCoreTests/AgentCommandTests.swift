import Darwin
import XCTest
@testable import DesnotchCore

final class AgentCommandTests: XCTestCase {
    func testPolicyAllowsOnlyConstrainedReadOnlyCommands() {
        let policy = AgentCommandPolicy()
        XCTAssertEqual(policy.decision(for: AgentCommandProposal(command: "pwd")), .readOnly)
        XCTAssertEqual(
            policy.decision(for: AgentCommandProposal(command: "git", arguments: ["status", "--short"])),
            .readOnly
        )
        assertConfirmation(policy.decision(for: AgentCommandProposal(command: "git", arguments: ["push"])))
        assertConfirmation(policy.decision(for: AgentCommandProposal(command: "git", arguments: ["branch", "new-branch"])))
        assertConfirmation(policy.decision(for: AgentCommandProposal(command: "cat", arguments: ["~/.ssh/id_ed25519"])))
        assertConfirmation(policy.decision(for: AgentCommandProposal(command: "ls", arguments: ["../"])))
    }

    func testGitOutputAndRepositoryBoundaryOptionsRequireConfirmation() {
        let policy = AgentCommandPolicy()
        let cwd = FileManager.default.temporaryDirectory
        for arguments in [["status", "--output=result"], ["diff", "--output", "result"], ["status", "--config", "x=y"], ["status", "--work-tree", "/tmp"], ["status", "--git-dir", "/tmp/repo/.git"]] {
            assertConfirmation(policy.decision(for: AgentCommandProposal(command: "git", arguments: arguments), cwd: cwd))
        }
    }

    func testSymlinkEscapingWorkspaceRequiresConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let decision = AgentCommandPolicy().decision(
            for: AgentCommandProposal(command: "cat", arguments: ["link/outside.txt"]),
            cwd: root
        )
        assertConfirmation(decision)
    }

    func testDangerousCategoriesNeverAutoRun() {
        let policy = AgentCommandPolicy()
        let proposals = [
            AgentCommandProposal(command: "rm", arguments: ["-rf", "x"]),
            AgentCommandProposal(command: "sudo", arguments: ["whoami"]),
            AgentCommandProposal(command: "curl", arguments: ["https://example.com"]),
            AgentCommandProposal(command: "ssh", arguments: ["host"]),
            AgentCommandProposal(command: "brew", arguments: ["install", "thing"]),
            AgentCommandProposal(command: "zsh", arguments: ["-c", "echo hi > file"]),
            AgentCommandProposal(command: "security", arguments: ["find-generic-password"])
        ]
        for proposal in proposals { assertConfirmation(policy.decision(for: proposal)) }
    }

    func testMalformedProposalIsBlocked() {
        let proposal = AgentCommandProposal(command: "bad command", arguments: [])
        if case .blocked = AgentCommandPolicy().decision(for: proposal) { return }
        XCTFail("malformed command should be blocked")
    }

    func testCodexJSONLParsesAgentMessageProposalButNotInternalExecution() {
        let marker = #"{"command":"ls","arguments":["-la"]}"#
        XCTAssertEqual(CodexCLITransport.parseMarker(marker)?.argv, ["ls", "-la"])
        let message = #"{"type":"item.completed","item":{"type":"agent_message","text":"Ready\nDESNOTCH_COMMAND_JSON: {\"command\":\"pwd\",\"arguments\":[]}"}}"#
        XCTAssertEqual(CodexCLITransport.parseJSONL(message)?.proposal?.command, "pwd")
        let internalCommand = #"{"type":"item.started","item":{"type":"command_execution","command":"rm -rf /"}}"#
        XCTAssertNil(CodexCLITransport.parseJSONL(internalCommand)?.proposal)
        let unknownText = #"{"type":"future.internal","text":"DESNOTCH_COMMAND_JSON: {\"command\":\"pwd\",\"arguments\":[]}"}"#
        XCTAssertNil(CodexCLITransport.parseJSONL(unknownText))
        XCTAssertNil(CodexCLITransport.parseJSONL("DESNOTCH_COMMAND_JSON: \(marker)"))
    }

    func testSecretRedactionAndByteLimit() {
        let source = "\u{001B}[31mAuthorization: Bearer sk-abcdefghijklmnop\npassword=hunter2"
        let redacted = SecretRedactor.redactAndLimit(source, utf8ByteCap: 80)
        XCTAssertFalse(redacted.contains("sk-abcdefghijklmnop"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("[31m"))
        XCTAssertLessThanOrEqual(redacted.utf8.count, 83) // cap plus ellipsis
    }

    func testSecretRedactionHandlesQuotedJSONValues() {
        let redacted = SecretRedactor.redact(#"{"api_key": "quoted secret", "password": 'another secret'}"#)
        XCTAssertFalse(redacted.contains("quoted secret"))
        XCTAssertFalse(redacted.contains("another secret"))
    }

    func testAuditDoesNotStoreSensitiveFieldsAndUsesPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("audit.jsonl")
        AgentCommandAudit(url: url).record(event: "execute", outcome: "ok", byteCount: 4)
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("execute"))
        XCTAssertFalse(text.contains("prompt"))
        XCTAssertFalse(text.contains("/Users/"))
        let permissions = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testProcessRunnerTimeout() async throws {
        let runner = AgentProcessRunner(outputByteCap: 1_024)
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                cwd: FileManager.default.temporaryDirectory,
                timeout: 0.1
            )
            XCTFail("expected timeout")
        } catch let error as AgentProcessError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testProcessRunnerRejectsOversizedStdin() async throws {
        let runner = AgentProcessRunner(outputByteCap: 1_024)
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                cwd: FileManager.default.temporaryDirectory,
                standardInput: Data(repeating: 0x41, count: AgentProcessRunner.inputByteCap + 1)
            )
            XCTFail("expected input cap")
        } catch let error as AgentProcessError {
            XCTAssertEqual(error, .inputTooLarge)
        }
    }

    func testProcessRunnerCancellation() async throws {
        let runner = AgentProcessRunner(outputByteCap: 1_024)
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                cwd: FileManager.default.temporaryDirectory,
                timeout: 10
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as AgentProcessError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testProcessRunnerDoesNotLeaveDescendantsAfterLeaderExits() async throws {
        let runner = AgentProcessRunner(outputByteCap: 1_024)
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM HUP; sleep 30 >/dev/null 2>&1 & echo $!"],
            cwd: FileManager.default.temporaryDirectory,
            timeout: 2
        )
        guard let pid = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return XCTFail("missing descendant pid")
        }
        let deadline = Date().addingTimeInterval(1)
        while Darwin.kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0)
    }

    func testProcessRunnerTimeoutIsNotBlockedByUnreadStdin() async throws {
        let runner = AgentProcessRunner(outputByteCap: 1_024)
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                cwd: FileManager.default.temporaryDirectory,
                timeout: 0.1,
                standardInput: Data(repeating: 0x61, count: AgentProcessRunner.inputByteCap)
            )
            XCTFail("expected timeout")
        } catch let error as AgentProcessError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testProcessRunnerCapsStreamCallbacksWhileDraining() async throws {
        let cap = 1_024
        let counter = LockedCounter()
        let runner = AgentProcessRunner(outputByteCap: cap)
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                cwd: FileManager.default.temporaryDirectory,
                timeout: 0.1,
                onStdout: { counter.add($0.count) }
            )
            XCTFail("expected timeout")
        } catch let error as AgentProcessError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThanOrEqual(counter.value, cap)
    }

    func testProcessRunnerSanitizesDangerousEnvironmentOverrides() {
        let environment = AgentProcessRunner.sanitizedEnvironment(base: [
            "HOME": "/tmp/home",
            "PATH": "/tmp/attacker",
            "GIT_EXTERNAL_DIFF": "/tmp/evil",
            "PERL5OPT": "-Mbad",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"
        ])
        XCTAssertEqual(environment["HOME"], "/tmp/home")
        XCTAssertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(environment["GIT_EXTERNAL_DIFF"])
        XCTAssertNil(environment["PERL5OPT"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
    }

    func testGitExecutionDisablesPagersExternalDiffAndTextConversion() {
        let arguments = AgentCommandController.hardenedArguments(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["show", "HEAD"]
        )
        XCTAssertTrue(arguments.contains("--no-pager"))
        XCTAssertTrue(arguments.contains("--no-ext-diff"))
        XCTAssertTrue(arguments.contains("--no-textconv"))
        XCTAssertTrue(arguments.contains("core.hooksPath=/dev/null"))
    }

    @MainActor
    func testControllerRequiresConfirmationThenRunsCommand() async throws {
        let backend = StubBackend(proposal: AgentCommandProposal(command: "echo", arguments: ["hello"]))
        let controller = AgentCommandController(
            cwd: FileManager.default.temporaryDirectory,
            backend: backend,
            automaticReadOnly: true,
            timeout: 5,
            outputByteCap: 4_096
        )
        controller.submit(transcribedPrompt: "say hello")
        try await waitUntil { controller.state == .awaitingConfirmation }
        controller.confirm()
        try await waitUntil { controller.state == .finished }
        XCTAssertEqual(controller.output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    @MainActor
    func testControllerDrainsBackgroundProposalBeforeFinishing() async throws {
        let controller = AgentCommandController(
            cwd: FileManager.default.temporaryDirectory,
            backend: BackgroundBackend(proposal: AgentCommandProposal(command: "echo", arguments: ["hello"])),
            automaticReadOnly: false,
            timeout: 5,
            outputByteCap: 4_096
        )
        controller.submit(transcribedPrompt: "say hello")
        try await waitUntil { controller.state == .awaitingConfirmation }
        XCTAssertEqual(controller.proposedCommand?.command, "echo")
    }

    private func assertConfirmation(_ decision: AgentCommandPolicyDecision) {
        if case .confirmationRequired = decision { return }
        XCTFail("expected confirmation, got \(decision)")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private struct StubBackend: AgentCommandBackend {
        let proposal: AgentCommandProposal
        func stream(
            prompt: String,
            cwd: URL,
            timeout: TimeInterval,
            onEvent: @escaping @Sendable (AgentCommandEvent) -> Void
        ) async throws -> AgentCommandOutput {
            XCTAssertEqual(timeout, 5)
            onEvent(AgentCommandEvent(kind: .status, text: "Planning"))
            onEvent(AgentCommandEvent(kind: .proposal, proposal: proposal))
            return AgentCommandOutput()
        }
    }

    private struct BackgroundBackend: AgentCommandBackend {
        let proposal: AgentCommandProposal
        func stream(
            prompt: String,
            cwd: URL,
            timeout: TimeInterval,
            onEvent: @escaping @Sendable (AgentCommandEvent) -> Void
        ) async throws -> AgentCommandOutput {
            await Task.detached {
                onEvent(AgentCommandEvent(kind: .proposal, proposal: proposal))
            }.value
            return AgentCommandOutput()
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add(_ value: Int) { lock.lock(); count += value; lock.unlock() }
    }
}
