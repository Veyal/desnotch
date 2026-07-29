import XCTest
@testable import DesnotchCore

final class SummaryTests: XCTestCase {
    func testHeadlineMultipleAgents() {
        let s = AgentActivitySummary(sessions: makeSessions(working: 2, needsYourTurn: 1))
        XCTAssertEqual(s.actionableCount, 3)
        XCTAssertTrue(s.hasActivity)
        XCTAssertEqual(s.headline, "3 agents: 2 working, 1 needs you")
    }

    func testHeadlineSingleAgent() {
        let s = AgentActivitySummary(sessions: makeSessions(working: 1))
        XCTAssertEqual(s.headline, "1 agent: 1 working")
    }

    func testHeadlineWithStalled() {
        let s = AgentActivitySummary(sessions: makeSessions(working: 0, needsYourTurn: 0, stalled: 2))
        XCTAssertEqual(s.headline, "2 agents: 2 stalled")
    }

    func testAllIdleIsInactive() {
        let s = AgentActivitySummary(sessions: makeSessions(idle: 5))
        XCTAssertEqual(s.actionableCount, 0)
        XCTAssertFalse(s.hasActivity)
    }

    func testEquatableSameCountsEqual() {
        let a = AgentActivitySummary(sessions: makeSessions(working: 1, needsYourTurn: 2))
        let b = AgentActivitySummary(sessions: makeSessions(working: 1, needsYourTurn: 2, idle: 9))
        // Counts (not session identity) drive equality; idle differs but counts match.
        XCTAssertEqual(a, b)
    }

    func testEquatableDifferentCountsNotEqual() {
        let a = AgentActivitySummary(sessions: makeSessions(working: 1))
        let b = AgentActivitySummary(sessions: makeSessions(working: 2))
        XCTAssertNotEqual(a, b)
    }

    // MARK: helpers

    private func makeSessions(
        working: Int = 0, needsYourTurn: Int = 0, stalled: Int = 0, idle: Int = 0
    ) -> [AgentSession] {
        var out: [AgentSession] = []
        let now = Date()
        out.append(contentsOf: (0..<working).map { _ in
            AgentSession(source: .claudeCode, projectLabel: "p", state: .working, lastActivity: now)
        })
        out.append(contentsOf: (0..<needsYourTurn).map { _ in
            AgentSession(source: .claudeCode, projectLabel: "p", state: .needsYourTurn, lastActivity: now)
        })
        out.append(contentsOf: (0..<stalled).map { _ in
            AgentSession(source: .claudeCode, projectLabel: "p", state: .stalled, lastActivity: now)
        })
        out.append(contentsOf: (0..<idle).map { _ in
            AgentSession(source: .claudeCode, projectLabel: "p", state: .idle, lastActivity: now)
        })
        return out
    }
}
