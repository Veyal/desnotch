import XCTest
@testable import DesnotchCore

final class PillAnimationPolicyTests: XCTestCase {
    func testReducedMotionRemovesEveryGeometricEffectAndPerpetualToken() {
        let motion = NotchAnimation.resolve(style: .dynamic, reduceMotion: true)

        XCTAssertFalse(motion.allowsGeometry)
        XCTAssertFalse(motion.allowsLooping)
        XCTAssertFalse(motion.allowsPulse)
        XCTAssertFalse(motion.allowsBlur)
        XCTAssertNil(motion.shapeOpen)
        XCTAssertNil(motion.shapeClose)
        XCTAssertNil(motion.structural)
        XCTAssertEqual(motion.pressScale, 1)
        XCTAssertEqual(motion.revealScale, 1)
        XCTAssertEqual(motion.revealOffsetY, 0)
        XCTAssertEqual(motion.revealBlur, 0)
        XCTAssertEqual(motion.compactLeaveScale, 1)
        XCTAssertEqual(motion.compactLeaveBlur, 0)
        XCTAssertEqual(motion.rowArrivalScale, 1)
        XCTAssertEqual(motion.rowArrivalOffsetY, 0)
        XCTAssertEqual(motion.rowArrivalBlur, 0)
        XCTAssertEqual(motion.rowRemovalBlur, 0)
        XCTAssertEqual(motion.staggerStep, 0)
        XCTAssertEqual(motion.staggerCap, 0)
        XCTAssertEqual(motion.shapeLeadDelay, 0)
        XCTAssertEqual(motion.collapseShapeDelay, 0)
        XCTAssertEqual(motion.spotlightDimOpacity, 1, "no dimming under Reduce Motion")
        XCTAssertEqual(motion.equalizerMinimumInterval, 1)
    }

    func testMinimalStyleUsesTheSameSuppressedTokens() {
        let motion = NotchAnimation.resolve(style: .minimal, reduceMotion: false)

        XCTAssertEqual(motion, NotchAnimation.resolve(style: .dynamic, reduceMotion: true))
        XCTAssertFalse(motion.allowsGeometry)
        XCTAssertFalse(motion.allowsLooping)
        XCTAssertFalse(motion.allowsPulse)
        XCTAssertEqual(motion.pressScale, 1)
    }

    func testDynamicMotionUsesCentralizedChoreography() {
        let motion = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)

        XCTAssertEqual(motion.pressScale, 0.90)
        XCTAssertEqual(motion.revealScale, 0.92)
        XCTAssertLessThan(motion.revealOffsetY, 0, "sections drop out of the notch")
        XCTAssertEqual(motion.revealBlur, 6)
        XCTAssertLessThan(motion.equalizerMinimumInterval, 1.0 / 10.0)
    }

    func testFluidDefaultIsSubtlerThanLivelyOnEveryEffectAxis() {
        let fluid = NotchAnimation.resolve(style: .subtle, reduceMotion: false)
        let lively = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)

        XCTAssertGreaterThan(fluid.revealScale, lively.revealScale)
        XCTAssertGreaterThan(fluid.revealOffsetY, lively.revealOffsetY)
        XCTAssertLessThan(fluid.revealBlur, lively.revealBlur)
        XCTAssertLessThan(fluid.staggerStep, lively.staggerStep)
        XCTAssertGreaterThan(fluid.compactLeaveScale, lively.compactLeaveScale)
        XCTAssertGreaterThan(fluid.rowArrivalScale, lively.rowArrivalScale)
    }

    func testEffectsStayWithinThePerformanceGuardrails() {
        for style in [AnimationStyle.subtle, .dynamic] {
            let motion = NotchAnimation.resolve(style: style, reduceMotion: false)
            XCTAssertLessThanOrEqual(motion.revealBlur, 6, "blur is capped at 6pt")
            XCTAssertLessThanOrEqual(motion.compactLeaveBlur, 6)
            XCTAssertLessThanOrEqual(motion.rowArrivalBlur, 6)
            XCTAssertLessThanOrEqual(motion.rowRemovalBlur, 6)
            XCTAssertTrue(motion.allowsBlur)
            // Worst-case stagger keeps the whole open choreography under ~0.6s of delay.
            let worstDelay = motion.shapeLeadDelay
                + PillStagger.delay(index: 99, step: motion.staggerStep, cap: motion.staggerCap)
            XCTAssertLessThan(worstDelay, 0.4)
            // Content leads the shape on open, and the shape trails the content on close.
            XCTAssertGreaterThan(motion.shapeLeadDelay, 0)
            XCTAssertGreaterThan(motion.collapseShapeDelay, 0)
            XCTAssertNotNil(motion.shapeOpen)
            XCTAssertNotNil(motion.shapeClose)
        }
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
