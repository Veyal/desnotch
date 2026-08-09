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
}
