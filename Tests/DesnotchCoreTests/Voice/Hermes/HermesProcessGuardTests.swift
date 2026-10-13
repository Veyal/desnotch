import Darwin
import Foundation
import XCTest
@testable import DesnotchCore

final class HermesProcessGuardTests: XCTestCase {
    private var directory: URL!
    private var owned: [HermesProcessGuard] = []
    private var transports: [ProcessACPTransport] = []
    private var pids: [Int32] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "desnotch-hermes-\(UUID().uuidString)", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for item in owned { item.terminateNow() }
        for transport in transports { transport.terminate() }
        for pid in pids where pid > 1 {
            Darwin.kill(pid, SIGKILL)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testHardStopKillsTheWholeTree() async throws {
        let item = own(command: "sleep 61 & sleep 61 & echo tree-up; wait")
        let transport = try item.ensureRunning()
        let line = await nextLine(of: transport)
        XCTAssertEqual(line, "tree-up")
        let shell = try XCTUnwrap(transport.processID)
        remember(shell)
        let children = HermesProcessGuard.descendants(of: shell)
        XCTAssertEqual(children.count, 2)
        remember(children)
        let report = await item.hardStop(sendCancel: {})
        for child in children { XCTAssertTrue(isDeadOrZombie(child)) }
        XCTAssertTrue(report.survivors.isEmpty)
    }

    func testHardStopReportsAProcessThatLeftTheGroup() async throws {
        let command = #"/usr/bin/perl -MPOSIX=setsid -e "\$|=1; setsid(); print qq(setsid-up \$\$\n); sleep 62" & wait"#
        let item = own(command: command)
        let transport = try item.ensureRunning()
        let announced = await nextLine(of: transport)
        let line = try XCTUnwrap(announced)
        XCTAssertTrue(line.hasPrefix("setsid-up "))
        let survivor = try XCTUnwrap(Int32(line.split(separator: " ").last.map(String.init) ?? ""))
        remember(survivor)
        let report = await item.hardStop(sendCancel: {})
        XCTAssertEqual(report.survivors, ["perl"])
        XCTAssertEqual(Darwin.kill(survivor, 0), 0)
        XCTAssertFalse(isDeadOrZombie(survivor))
    }

    func testTerminateNowKillsTheTreeSynchronously() async throws {
        let item = own(command: "sleep 64 & sleep 64 & echo tree-up; wait")
        let transport = try item.ensureRunning()
        let announced = await nextLine(of: transport)
        XCTAssertEqual(announced, "tree-up")
        let shell = try XCTUnwrap(transport.processID)
        remember(shell)
        let children = HermesProcessGuard.descendants(of: shell)
        XCTAssertEqual(children.count, 2)
        remember(children)
        item.terminateNow()
        for child in children { XCTAssertTrue(isDeadOrZombie(child)) }
        XCTAssertTrue(isDeadOrZombie(shell))
    }

    func testStalePidFileForAnUnrelatedProcessIsNotKilled() async throws {
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        sleep.arguments = ["sleep", "63"]
        try sleep.run()
        let sleepPID = sleep.processIdentifier
        remember(sleepPID)
        let started = await waitForStart(sleepPID)
        let start = try XCTUnwrap(started)
        try writePid(sleepPID, start: start)
        let item = own(command: "echo ready; sleep 3600 & wait")
        let transport = try item.ensureRunning()
        let announced = await nextLine(of: transport)
        XCTAssertEqual(announced, "ready")
        XCTAssertTrue(HermesProcessGuard.alive(sleepPID))
        let parsed = try XCTUnwrap(readPid())
        XCTAssertEqual(parsed.pid, transport.processID)
        XCTAssertNotEqual(parsed.pid, sleepPID)
        if let pid = transport.processID { remember(pid) }
    }

    func testStalePidFileForALeftoverVoiceAcpIsKilled() async throws {
        let stale = try await dropShell("echo up; sleep 66 & wait # hermes -p voice acp")
        let item = own(command: "echo ready; sleep 3600 & wait")
        let transport = try item.ensureRunning()
        let announced = await nextLine(of: transport)
        XCTAssertEqual(announced, "ready")
        XCTAssertTrue(isDeadOrZombie(stale.shell))
        for child in stale.children { XCTAssertTrue(isDeadOrZombie(child)) }
        let parsed = try XCTUnwrap(readPid())
        XCTAssertEqual(parsed.pid, transport.processID)
        if let pid = transport.processID { remember(pid) }
    }

    func testStalePidFileWithoutDashPVoiceIsNotKilled() async throws {
        let stale = try await dropShell("echo up; sleep 67 & wait # hermes acp")
        let item = own(command: "echo ready; sleep 3600 & wait")
        let transport = try item.ensureRunning()
        let announced = await nextLine(of: transport)
        XCTAssertEqual(announced, "ready")
        XCTAssertTrue(HermesProcessGuard.alive(stale.shell))
        for child in stale.children { XCTAssertTrue(HermesProcessGuard.alive(child)) }
        let parsed = try XCTUnwrap(readPid())
        XCTAssertEqual(parsed.pid, transport.processID)
        XCTAssertNotEqual(parsed.pid, stale.shell)
        if let pid = transport.processID { remember(pid) }
    }

    func testStalePidFileWithAStartTimeMismatchIsNotKilled() async throws {
        try await mismatch(delta: -3600, marker: "68")
        try await mismatch(delta: 3600, marker: "68")
    }

    func testGuardRegistersTheTransportBeforeStart() throws {
        let transport = HermesFakeTransport()
        let slot = GuardSlot()
        let item = HermesProcessGuard(
            launch: { ACPLaunch.hermes(path: URL(fileURLWithPath: "/test/hermes")) },
            pidFileDirectory: directory, workingDirectoryRoot: directory,
            transportFactory: { _, _ in transport }
        )
        slot.item = item
        owned.append(item)
        transport.onStart = { XCTAssertTrue(slot.item?.liveTransport === transport) }
        _ = try item.ensureRunning()
    }

    func testTerminateNowDuringStartMakesStartFailFast() {
        let transport = HermesFakeTransport()
        let slot = GuardSlot()
        let made = HermesProcessGuard(
            launch: { ACPLaunch.hermes(path: URL(fileURLWithPath: "/test/hermes")) },
            pidFileDirectory: directory, workingDirectoryRoot: directory,
            transportFactory: { _, _ in transport }
        )
        slot.item = made
        owned.append(made)
        transport.onStart = { slot.item?.terminateNow() }
        XCTAssertThrowsError(try made.ensureRunning()) { error in
            XCTAssertEqual(error as? HermesGuardError, .spawnFailed)
        }
        XCTAssertGreaterThanOrEqual(transport.terminateCount, 1)
        XCTAssertNil(made.liveTransport)
    }

    func testBackoffAfterTheChildExits() throws {
        let clock = HermesClock()
        let created = TransportList()
        let item = HermesProcessGuard(
            launch: { ACPLaunch.hermes(path: URL(fileURLWithPath: "/test/hermes")) },
            pidFileDirectory: directory, workingDirectoryRoot: directory,
            transportFactory: { _, _ in
                let transport = HermesFakeTransport()
                created.add(transport)
                return transport
            },
            now: { clock.now() }
        )
        owned.append(item)
        _ = try item.ensureRunning()
        created.items[0].simulateExit(uptime: 0.1)
        XCTAssertThrowsError(try item.ensureRunning()) { error in
            XCTAssertEqual(error as? HermesGuardError, .backoff)
        }
        XCTAssertEqual(created.items.count, 1)
        clock.advance(1)
        _ = try item.ensureRunning()
        XCTAssertEqual(created.items.count, 2)
        item.terminateNow()
        _ = try item.ensureRunning()
        XCTAssertEqual(created.items.count, 3)
    }

    func testStopDoesNotSignalAnAlreadyExitedChild() async throws {
        let signals = SignalLog()
        let exited = HermesFakeTransport()
        exited.processID = 999_999
        let first = HermesProcessGuard(
            launch: { ACPLaunch.hermes(path: URL(fileURLWithPath: "/test/hermes")) },
            pidFileDirectory: directory, workingDirectoryRoot: directory,
            transportFactory: { _, _ in exited },
            killGroup: { pid, code in signals.add(pid, code); return 0 }
        )
        owned.append(first)
        _ = try first.ensureRunning()
        exited.simulateExit(uptime: 5)
        XCTAssertEqual(exited.terminateCount, 1)
        XCTAssertTrue(signals.values.isEmpty)
        first.terminateNow()
        _ = await first.hardStop(sendCancel: {})
        XCTAssertTrue(signals.values.isEmpty)
        XCTAssertEqual(exited.terminateCount, 1)

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        remember(pid)
        let living = HermesFakeTransport()
        living.processID = pid
        let second = HermesProcessGuard(
            launch: { ACPLaunch.hermes(path: URL(fileURLWithPath: "/test/hermes")) },
            pidFileDirectory: directory.appendingPathComponent("other", isDirectory: true),
            workingDirectoryRoot: directory,
            transportFactory: { _, _ in living },
            killGroup: { pgid, code in
                signals.add(pgid, code)
                if code == SIGTERM { Darwin.kill(pgid, SIGKILL) }
                return 0
            }
        )
        owned.append(second)
        _ = try second.ensureRunning()
        second.terminateNow()
        XCTAssertEqual(signals.values.filter { $0.0 == pid && $0.1 == SIGTERM }.count, 1)
        XCTAssertEqual(signals.values.filter { $0.0 == pid && $0.1 == SIGKILL }.count, 1)
    }

    func testProcessTransportSendAfterTheChildExitedThrowsAndTheProcessSurvives() async {
        let transport = ProcessACPTransport(
            launch: .command("exit 0"), workingDirectoryRoot: FileManager.default.temporaryDirectory
        )
        transports.append(transport)
        let exited = expectation(description: "child exited")
        transport.setExitHandler { _ in exited.fulfill() }
        try? transport.start()
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertThrowsError(try transport.send(line: Data(#"{"jsonrpc":"2.0"}"#.utf8)))
    }

    func testProcessTransportSendAfterTerminateThrows() async throws {
        let transport = ProcessACPTransport(
            launch: .command("sleep 69 & wait"), workingDirectoryRoot: directory
        )
        transports.append(transport)
        try transport.start()
        let shell = try XCTUnwrap(transport.processID)
        remember(shell)
        remember(HermesProcessGuard.descendants(of: shell))
        transport.terminate()
        XCTAssertThrowsError(try transport.send(line: Data("{\"a\":1}".utf8)))
    }

    func testProcessTransportReportsTheExitEvenWhenAGrandchildHoldsStdout() async throws {
        let command = #"/usr/bin/perl -MPOSIX=setsid -e 'setsid(); exec \"sleep\",\"70\"' & echo child-$!"#
        let transport = ProcessACPTransport(launch: .command(command), workingDirectoryRoot: directory)
        transports.append(transport)
        let counter = CountBox()
        let exited = expectation(description: "leader exited")
        transport.setExitHandler { _ in
            counter.add()
            exited.fulfill()
        }
        try transport.start()
        let announced = await nextLine(of: transport)
        let line = try XCTUnwrap(announced)
        XCTAssertTrue(line.hasPrefix("child-"))
        let sleepPID = try XCTUnwrap(Int32(line.dropFirst("child-".count)))
        remember(sleepPID)
        await fulfillment(of: [exited], timeout: 5)
        let drained = expectation(description: "lines finished")
        let task = Task {
            var iterator = transport.lines.makeAsyncIterator()
            while await iterator.next() != nil {}
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 5)
        task.cancel()
        transport.terminate()
        XCTAssertEqual(counter.value, 1)
    }

    func testProcessTransportTerminateKillsTheWholeTree() async throws {
        let transport = ProcessACPTransport(
            launch: .command("sleep 65 & sleep 65 & echo tree-up; wait"), workingDirectoryRoot: directory
        )
        transports.append(transport)
        let counter = CountBox()
        transport.setExitHandler { _ in counter.add() }
        try transport.start()
        let announced = await nextLine(of: transport)
        XCTAssertEqual(announced, "tree-up")
        let shell = try XCTUnwrap(transport.processID)
        let children = HermesProcessGuard.descendants(of: shell)
        XCTAssertEqual(children.count, 2)
        remember(shell)
        remember(children)
        transport.terminate()
        for child in children { XCTAssertTrue(isDeadOrZombie(child)) }
        XCTAssertTrue(isDeadOrZombie(shell))
        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transport.workingDirectory.path))
        transport.terminate()
        XCTAssertEqual(counter.value, 1)
    }

    func testProcessTransportTerminateEscalatesToKillWhenSigtermIsIgnored() async throws {
        let transport = ProcessACPTransport(
            launch: .command("trap '' TERM; sleep 65 & echo tree-up; wait"), workingDirectoryRoot: directory
        )
        transports.append(transport)
        try transport.start()
        let announced = await nextLine(of: transport)
        XCTAssertEqual(announced, "tree-up")
        let shell = try XCTUnwrap(transport.processID)
        let children = HermesProcessGuard.descendants(of: shell)
        remember(shell)
        remember(children)
        transport.terminate()
        for _ in 0..<2000 where !isDeadOrZombie(shell) { await Task.yield() }
        XCTAssertTrue(isDeadOrZombie(shell), describe(shell))
        for child in children {
            XCTAssertTrue(isDeadOrZombie(child), describe(child))
        }
    }

    private func describe(_ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,stat=,pgid=,command=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "ps-failed" }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "gone" : text
    }

    func testGuardEvaluatesTheLaunchProviderAtEverySpawn() throws {
        let slot = LaunchSlot()
        let seen = LaunchList()
        let item = HermesProcessGuard(
            launch: { slot.value },
            pidFileDirectory: directory, workingDirectoryRoot: directory,
            transportFactory: { launch, _ in
                seen.add(launch)
                return HermesFakeTransport()
            }
        )
        owned.append(item)
        XCTAssertThrowsError(try item.ensureRunning()) { error in
            XCTAssertEqual(error as? HermesGuardError, .spawnFailed)
        }
        XCTAssertTrue(seen.items.isEmpty)
        XCTAssertNil(item.liveTransport)
        XCTAssertThrowsError(try item.ensureRunning()) { error in
            XCTAssertEqual(error as? HermesGuardError, .spawnFailed)
        }
        slot.value = ACPLaunch.hermes(path: URL(fileURLWithPath: "/test/hermes-b"))
        _ = try item.ensureRunning()
        XCTAssertEqual(Array(seen.items[0].arguments.suffix(4)), ["/test/hermes-b", "-p", "voice", "acp"])
        slot.value = ACPLaunch.hermes(path: URL(fileURLWithPath: "/test/hermes-c"))
        item.terminateNow()
        _ = try item.ensureRunning()
        XCTAssertEqual(Array(seen.items[1].arguments.suffix(4)), ["/test/hermes-c", "-p", "voice", "acp"])
    }

    func testIsHermesACPParsePidFileAndStartTimes() {
        XCTAssertTrue(HermesProcessGuard.isHermesACP(commandLine: "/usr/bin/python3 -I -c import x -p voice acp"))
        XCTAssertTrue(HermesProcessGuard.isHermesACP(commandLine: "python3 -c script -p voice acp\n"))
        XCTAssertFalse(HermesProcessGuard.isHermesACP(commandLine: "hermes acp"))
        XCTAssertFalse(HermesProcessGuard.isHermesACP(commandLine: "hermes -p default acp"))
        XCTAssertFalse(HermesProcessGuard.isHermesACP(commandLine: "-p voiceX acp"))
        XCTAssertFalse(HermesProcessGuard.isHermesACP(commandLine: "-p voice"))
        XCTAssertFalse(HermesProcessGuard.isHermesACP(commandLine: "voice -p acp"))
        XCTAssertFalse(HermesProcessGuard.isHermesACP(commandLine: ""))
        XCTAssertEqual(HermesProcessGuard.parsePidFile("123 1700000000\n")?.pid, 123)
        XCTAssertEqual(HermesProcessGuard.parsePidFile("123 1700000000")?.startSeconds, 1_700_000_000)
        XCTAssertNil(HermesProcessGuard.parsePidFile(""))
        XCTAssertNil(HermesProcessGuard.parsePidFile("123"))
        XCTAssertNil(HermesProcessGuard.parsePidFile("123 abc"))
        XCTAssertNil(HermesProcessGuard.parsePidFile("1 1700000000"))
        XCTAssertNil(HermesProcessGuard.parsePidFile("123  1700000000"))
        XCTAssertNil(HermesProcessGuard.parsePidFile("123 1700000000 9"))
        XCTAssertTrue(HermesProcessGuard.startTimesAgree(recorded: 10, actual: 10))
        XCTAssertTrue(HermesProcessGuard.startTimesAgree(recorded: 10, actual: 15))
        XCTAssertFalse(HermesProcessGuard.startTimesAgree(recorded: 10, actual: 16))
        XCTAssertFalse(HermesProcessGuard.startTimesAgree(recorded: 10, actual: 4))
    }

    private func own(command: String) -> HermesProcessGuard {
        let item = HermesProcessGuard(
            launch: { ACPLaunch.command(command) },
            pidFileDirectory: directory, workingDirectoryRoot: directory
        )
        owned.append(item)
        return item
    }

    private func remember(_ pid: Int32) { pids.append(pid) }

    private func remember(_ pids: [Int32]) { self.pids.append(contentsOf: pids) }

    private func writePid(_ pid: Int32, start: Int) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("hermes-acp.pid")
        try "\(pid) \(start)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func readPid() -> (pid: Int32, startSeconds: Int)? {
        let url = directory.appendingPathComponent("hermes-acp.pid")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return HermesProcessGuard.parsePidFile(text)
    }

    private func waitForStart(_ pid: Int32) async -> Int? {
        for _ in 0..<2000 {
            if let start = HermesProcessGuard.processStartSeconds(pid: pid) { return start }
            await Task.yield()
        }
        return nil
    }

    private func dropShell(_ command: String) async throws -> (shell: Int32, children: [Int32]) {
        var holder: HermesProcessGuard? = HermesProcessGuard(
            launch: { ACPLaunch.command(command) },
            pidFileDirectory: directory, workingDirectoryRoot: directory
        )
        let transport = try XCTUnwrap(try? holder?.ensureRunning())
        let announced = await nextLine(of: transport)
        XCTAssertEqual(announced, "up")
        let shell = try XCTUnwrap(transport.processID)
        var children: [Int32] = []
        for _ in 0..<5000 {
            children = HermesProcessGuard.descendants(of: shell)
            if !children.isEmpty { break }
            await Task.yield()
        }
        XCTAssertFalse(children.isEmpty)
        remember(shell)
        remember(children)
        holder = nil
        return (shell, children)
    }

    private func mismatch(delta: Int, marker: String) async throws {
        let stale = try await dropShell("echo up; sleep \(marker) & wait # hermes -p voice acp")
        let actual = try XCTUnwrap(HermesProcessGuard.processStartSeconds(pid: stale.shell))
        try writePid(stale.shell, start: actual + delta)
        let item = own(command: "echo ready; sleep 3600 & wait")
        let transport = try item.ensureRunning()
        let announced = await nextLine(of: transport)
        XCTAssertEqual(announced, "ready")
        XCTAssertTrue(HermesProcessGuard.alive(stale.shell))
        let parsed = try XCTUnwrap(readPid())
        XCTAssertEqual(parsed.pid, transport.processID)
        XCTAssertNotEqual(parsed.pid, stale.shell)
        if let pid = transport.processID { remember(pid) }
        item.terminateNow()
    }

    private final class GuardSlot: @unchecked Sendable {
        var item: HermesProcessGuard?
    }

    private final class LaunchSlot: @unchecked Sendable {
        var value: ACPLaunch?
    }

    private final class LaunchList: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ACPLaunch] = []

        func add(_ launch: ACPLaunch) {
            lock.lock()
            stored.append(launch)
            lock.unlock()
        }

        var items: [ACPLaunch] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class TransportList: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HermesFakeTransport] = []

        func add(_ transport: HermesFakeTransport) {
            lock.lock()
            stored.append(transport)
            lock.unlock()
        }

        var items: [HermesFakeTransport] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class SignalLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(Int32, Int32)] = []

        func add(_ pid: Int32, _ code: Int32) {
            lock.lock()
            stored.append((pid, code))
            lock.unlock()
        }

        var values: [(Int32, Int32)] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class CountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0

        func add() {
            lock.lock()
            stored += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
