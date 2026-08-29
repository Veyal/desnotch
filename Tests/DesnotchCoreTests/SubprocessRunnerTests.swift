import Darwin
import XCTest
@testable import DesnotchCore

final class SubprocessRunnerTests: XCTestCase {
    func testTimeout() async throws {
        let runner = SubprocessRunner(outputByteCap: 1_024)
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                cwd: FileManager.default.temporaryDirectory,
                timeout: 0.1
            )
            XCTFail("expected timeout")
        } catch let error as SubprocessError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testRejectsOversizedStdin() async throws {
        let runner = SubprocessRunner(outputByteCap: 1_024)
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                cwd: FileManager.default.temporaryDirectory,
                standardInput: Data(repeating: 0x41, count: SubprocessRunner.inputByteCap + 1)
            )
            XCTFail("expected input cap")
        } catch let error as SubprocessError {
            XCTAssertEqual(error, .inputTooLarge)
        }
    }

    func testCannotLaunchAfterShutdownBoundary() async throws {
        let runner = SubprocessRunner(outputByteCap: 1_024)
        runner.shutdown()
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                cwd: FileManager.default.temporaryDirectory
            )
            XCTFail("expected shutdown runner to reject new work")
        } catch let error as SubprocessError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testCancellation() async throws {
        let runner = SubprocessRunner(outputByteCap: 1_024)
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
        } catch let error as SubprocessError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testDoesNotLeaveDescendantsAfterLeaderExits() async throws {
        let runner = SubprocessRunner(outputByteCap: 1_024)
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

    func testCapsStreamCallbacksWhileDraining() async throws {
        let cap = 1_024
        let counter = LockedCounter()
        let runner = SubprocessRunner(outputByteCap: cap)
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                cwd: FileManager.default.temporaryDirectory,
                timeout: 0.1,
                onStdout: { counter.add($0.count) }
            )
            XCTFail("expected timeout")
        } catch let error as SubprocessError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThanOrEqual(counter.value, cap)
    }

    func testSanitizesDangerousEnvironmentOverrides() {
        let environment = SubprocessRunner.sanitizedEnvironment(base: [
            "HOME": "/tmp/home",
            "PATH": "/tmp/attacker",
            "GIT_EXTERNAL_DIFF": "/tmp/evil",
            "PERL5OPT": "-Mbad",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"
        ])
        XCTAssertEqual(environment["HOME"], "/tmp/home")
        XCTAssertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(environment["GIT_EXTERNAL_DIFF"])
        XCTAssertNil(environment["PERL5OPT"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add(_ value: Int) { lock.lock(); count += value; lock.unlock() }
    }
}
