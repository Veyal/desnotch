import XCTest
@testable import DesnotchCore

final class PillAnimationPolicyTests: XCTestCase {
    func testReducedMotionRemovesEveryGeometricAndPerpetualToken() {
        let motion = NotchAnimation.resolve(style: .dynamic, reduceMotion: true)

        XCTAssertFalse(motion.allowsGeometry)
        XCTAssertFalse(motion.allowsLooping)
        XCTAssertFalse(motion.allowsPulse)
        XCTAssertEqual(motion.pressScale, 1)
        XCTAssertEqual(motion.expansionContentScale, 1)
        XCTAssertEqual(motion.expansionContentOffset, 0)
        XCTAssertEqual(motion.equalizerMinimumInterval, 1)
    }

    func testMinimalStyleUsesTheSameSuppressedTokens() {
        let motion = NotchAnimation.resolve(style: .minimal, reduceMotion: false)

        XCTAssertFalse(motion.allowsGeometry)
        XCTAssertFalse(motion.allowsLooping)
        XCTAssertFalse(motion.allowsPulse)
        XCTAssertEqual(motion.pressScale, 1)
        XCTAssertEqual(motion.expansionContentOpacity, 0)
    }

    func testDynamicMotionUsesCentralizedChoreography() {
        let motion = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)

        XCTAssertEqual(motion.pressScale, 0.90)
        XCTAssertEqual(motion.expansionContentScale, 0.96)
        XCTAssertGreaterThan(motion.expansionContentOffset, 0)
        XCTAssertLessThan(motion.equalizerMinimumInterval, 1.0 / 10.0)
    }

    func testPolicyUsesDeterministicHighestPriorityEvent() {
        let motion = NotchAnimation.resolve(style: .subtle, reduceMotion: false)
        let policy = NotchAnimation.policy(
            for: [.pollingRefresh, .contentReplacement, .structuralInsertion, .feedback],
            motion: motion
        )

        XCTAssertEqual(policy.event, .structuralInsertion)
        XCTAssertEqual(policy.channel, .primary)
        XCTAssertTrue(policy.allowsGeometry)
        XCTAssertTrue(policy.allowsPulse)
    }

    func testPollingRefreshIsAnimationFree() {
        let motion = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)
        let policy = NotchAnimation.policy(for: [.pollingRefresh], motion: motion)

        XCTAssertEqual(policy.event, .pollingRefresh)
        XCTAssertEqual(policy.channel, .none)
        XCTAssertFalse(policy.allowsGeometry)
        XCTAssertFalse(policy.allowsPulse)
    }

    func testExpansionWinsOverDirectManipulationAndFeedback() {
        let motion = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)
        let policy = NotchAnimation.policy(
            for: [.expansion, .directManipulation, .feedback],
            motion: motion
        )

        XCTAssertEqual(policy.event, .expansion)
        XCTAssertEqual(policy.channel, .primary)
    }
}
