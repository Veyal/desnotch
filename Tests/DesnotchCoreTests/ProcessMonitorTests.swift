import XCTest
@testable import DesnotchCore

final class ProcessMonitorTests: XCTestCase {
    func testCPUTimeParsing() {
        XCTAssertEqual(ProcessCPUSnapshot.parseCPUTime("12:34.56")!, 754.56, accuracy: 0.001)
        XCTAssertEqual(ProcessCPUSnapshot.parseCPUTime("155:22.48")!, 9_322.48, accuracy: 0.001)
        XCTAssertEqual(ProcessCPUSnapshot.parseCPUTime("1:02:03.45")!, 3_723.45, accuracy: 0.001)
        XCTAssertEqual(ProcessCPUSnapshot.parseCPUTime("2-03:04:05.67")!, 183_845.67, accuracy: 0.001)
        XCTAssertNil(ProcessCPUSnapshot.parseCPUTime("bad"))
        XCTAssertNil(ProcessCPUSnapshot.parseCPUTime("1:60"))
    }

    func testUtilizationUsesOnlyLatestInterval() throws {
        var calculator = ProcessCPUCalculator()
        let process = { (cpuTime: TimeInterval) in
            ProcessCPUSnapshot(pid: 42, totalCPUTime: cpuTime, name: "spinner")
        }

        XCTAssertTrue(calculator.utilization(from: [process(100)], sampledAt: 1_000).isEmpty)

        let busy = try XCTUnwrap(
            calculator.utilization(from: [process(105)], sampledAt: 1_005).first
        )
        XCTAssertEqual(busy.cpu, 100, accuracy: 0.001)

        let recovered = try XCTUnwrap(
            calculator.utilization(from: [process(105)], sampledAt: 1_010).first
        )
        XCTAssertEqual(recovered.cpu, 0, accuracy: 0.001)
    }

    func testFlaggedProcessIsRemovedOnFirstLowSample() {
        var state = ProcessHotState(cpuThreshold: 90, sustainedFor: 10 * 60, maxShown: 3)
        let started = Date(timeIntervalSince1970: 1_000)
        let hotSample = [(pid: Int32(42), cpu: 100.0, name: "spinner")]

        XCTAssertTrue(state.apply(sample: hotSample, now: started).shown.isEmpty)

        let flagged = state.apply(
            sample: hotSample,
            now: started.addingTimeInterval(10 * 60)
        )
        XCTAssertEqual(flagged.shown.map(\.pid), [42])
        XCTAssertEqual(flagged.newlyFlagged.map(\.pid), [42])

        let recovered = state.apply(
            sample: [(pid: Int32(42), cpu: 0, name: "spinner")],
            now: started.addingTimeInterval(10 * 60 + 5)
        )
        XCTAssertTrue(recovered.shown.isEmpty)
        XCTAssertTrue(recovered.newlyFlagged.isEmpty)
    }

    func testThresholdAndDurationBoundariesAreInclusive() {
        var state = ProcessHotState(cpuThreshold: 90, sustainedFor: 600, maxShown: 3)
        let started = Date(timeIntervalSince1970: 5_000)
        let exactThreshold = [(pid: Int32(7), cpu: 90.0, name: "worker")]

        XCTAssertTrue(state.apply(sample: exactThreshold, now: started).shown.isEmpty)
        let atBoundary = state.apply(
            sample: exactThreshold,
            now: started.addingTimeInterval(600)
        )
        XCTAssertEqual(atBoundary.shown.map(\.pid), [7])
    }

    func testPIDNameChangeStartsANewStreakAndMaxShownKeepsHottest() {
        var state = ProcessHotState(cpuThreshold: 90, sustainedFor: 600, maxShown: 2)
        let started = Date(timeIntervalSince1970: 9_000)
        let initial = [
            (pid: Int32(1), cpu: 91.0, name: "old"),
            (pid: Int32(2), cpu: 140.0, name: "hotter"),
            (pid: Int32(3), cpu: 110.0, name: "hot")
        ]
        _ = state.apply(sample: initial, now: started)

        let boundary = started.addingTimeInterval(600)
        let renamed = [
            (pid: Int32(1), cpu: 150.0, name: "new"),
            (pid: Int32(2), cpu: 140.0, name: "hotter"),
            (pid: Int32(3), cpu: 110.0, name: "hot")
        ]
        let update = state.apply(sample: renamed, now: boundary)

        XCTAssertEqual(update.shown.map(\.pid), [2, 3])
        XCTAssertFalse(update.shown.contains(where: { $0.name == "new" }))
    }
}

final class ProcessSamplerTests: XCTestCase {
    func testParsesPSRowsWithSpacesAndSkipsOwnPidAndGarbage() {
        let text = """
            1   9:48.84 /sbin/launchd
        97355   0:00.00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          500   1:02:03.45 /usr/sbin/mds
          777   0:01.00 /usr/bin/self
        not-a-row
        """
        let parsed = PSProcessSampler.parse(text, excludingPID: 777)
        XCTAssertEqual(parsed.map(\.pid), [1, 97_355, 500])
        XCTAssertEqual(parsed.map(\.name), ["launchd", "Google Chrome", "mds"])
        XCTAssertEqual(parsed[2].totalCPUTime, 3_723.45, accuracy: 0.001)
    }

    func testPartialSampleKeepsEachPidsOwnInterval() throws {
        var calculator = ProcessCPUCalculator()
        let a = { (cpu: TimeInterval) in ProcessCPUSnapshot(pid: 1, totalCPUTime: cpu, name: "a") }
        let b = { (cpu: TimeInterval) in ProcessCPUSnapshot(pid: 2, totalCPUTime: cpu, name: "b") }

        XCTAssertTrue(calculator.utilization(from: [a(0), b(0)], sampledAt: 0).isEmpty)
        // Quick refresh of pid 1 only, 5s in.
        let quick = try XCTUnwrap(calculator.utilization(from: [a(5)], sampledAt: 5, isPartial: true).first)
        XCTAssertEqual(quick.cpu, 100, accuracy: 0.001)
        // The next full scan at 30s measures pid 2 over its own 30s, pid 1 over 25s.
        let full = calculator.utilization(from: [a(30), b(15)], sampledAt: 30)
        XCTAssertEqual(full.first { $0.pid == 1 }?.cpu ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(full.first { $0.pid == 2 }?.cpu ?? -1, 50, accuracy: 0.001)
    }

    func testPartialApplyLeavesOtherStreaksAndDropsQueriedExits() {
        var state = ProcessHotState(cpuThreshold: 90, sustainedFor: 600, maxShown: 3)
        let started = Date(timeIntervalSince1970: 20_000)
        let hot = [
            (pid: Int32(1), cpu: 100.0, name: "one"),
            (pid: Int32(2), cpu: 100.0, name: "two")
        ]
        _ = state.apply(sample: hot, now: started)
        let flagged = state.apply(sample: hot, now: started.addingTimeInterval(600))
        XCTAssertEqual(Set(flagged.shown.map(\.pid)), [1, 2])

        // Quick refresh asks only about pid 1 and gets nothing back (exited): pid 2 stays.
        let update = state.apply(sample: [], now: started.addingTimeInterval(605), queried: [1])
        XCTAssertEqual(update.shown.map(\.pid), [2])
    }

    func testAWallClockStepDoesNotAgeOrRewindAStreak() {
        var state = ProcessHotState(cpuThreshold: 90, sustainedFor: 600, maxShown: 3)
        let started = Date(timeIntervalSince1970: 30_000)
        let hot = [(pid: Int32(7), cpu: 100.0, name: "seven")]
        _ = state.apply(sample: hot, now: started, uptime: 1_000)

        // 30s of real (uptime) time pass, but the wall clock jumps forward an hour (NTP step,
        // manual change): the streak is still 30s old, so nothing is flagged or notified.
        let stepped = state.apply(sample: hot, now: started.addingTimeInterval(3_630), uptime: 1_030)
        XCTAssertTrue(stepped.shown.isEmpty)
        XCTAssertTrue(stepped.newlyFlagged.isEmpty)
        XCTAssertEqual(stepped.ages[7] ?? -1, 30, accuracy: 0.001)

        // A backwards step must not hold a genuinely old streak back either.
        let later = state.apply(sample: hot, now: started.addingTimeInterval(-3_600), uptime: 1_600)
        XCTAssertEqual(later.shown.map(\.pid), [7])
        XCTAssertEqual(later.newlyFlagged.map(\.pid), [7])
        XCTAssertEqual(later.ages[7] ?? -1, 600, accuracy: 0.001)
    }
}
