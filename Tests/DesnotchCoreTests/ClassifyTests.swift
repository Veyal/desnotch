import XCTest
@testable import DesnotchCore

final class ClassifyTests: XCTestCase {
    func testWorkingWithinStalledWindow() {
        XCTAssertEqual(AgentActivityScanner.classify(elapsed: 60, turnInProgress: true), .working)
        XCTAssertEqual(AgentActivityScanner.classify(elapsed: 9 * 60, turnInProgress: true), .working)
    }

    func testStalledBetweenWindows() {
        XCTAssertEqual(AgentActivityScanner.classify(elapsed: 15 * 60, turnInProgress: true), .stalled)
        XCTAssertEqual(AgentActivityScanner.classify(elapsed: 40 * 60, turnInProgress: true), .stalled)
    }

    func testStalledSessionDroppedAfterMax() {
        // Beyond stalledSessionMax, a presumed-hung session is treated as dead (nil), not stalled.
        XCTAssertNil(AgentActivityScanner.classify(elapsed: 50 * 60, turnInProgress: true))
    }

    func testNeedsYourTurnRecentCompleted() {
        XCTAssertEqual(AgentActivityScanner.classify(elapsed: 60, turnInProgress: false), .needsYourTurn)
        XCTAssertEqual(AgentActivityScanner.classify(elapsed: 4 * 60, turnInProgress: false), .needsYourTurn)
    }

    func testIdleAfterNeedsWindow() {
        XCTAssertEqual(AgentActivityScanner.classify(elapsed: 10 * 60, turnInProgress: false), .idle)
    }

    func testPresentationLabelsStayGeneric() {
        XCTAssertEqual(AgentActivityState.working.presentationLabel, "running")
        XCTAssertEqual(AgentActivityState.needsYourTurn.presentationLabel, "waiting you")
        XCTAssertEqual(AgentActivityState.stalled.presentationLabel, "no recent progress")
        XCTAssertEqual(AgentActivityState.idle.presentationLabel, "finished")
        XCTAssertEqual(AgentActivityState.working.presentationReason, "processing")
    }

    func testFreshnessBucketsAvoidSecondChurn() {
        let now = Date()
        XCTAssertEqual(AgentActivityPresentation.freshness(for: now, now: now), "now")
        XCTAssertEqual(AgentActivityPresentation.freshness(for: now.addingTimeInterval(-61), now: now), "updated 1m")
        XCTAssertEqual(AgentActivityPresentation.freshness(for: now.addingTimeInterval(-3601), now: now), "updated 1h")
    }
}