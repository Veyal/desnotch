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
}
