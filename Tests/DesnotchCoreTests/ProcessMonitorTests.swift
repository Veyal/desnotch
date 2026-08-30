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
