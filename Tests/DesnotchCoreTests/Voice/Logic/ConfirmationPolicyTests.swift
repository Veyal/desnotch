import XCTest
@testable import DesnotchCore

final class ConfirmationPolicyTests: XCTestCase {
    func testVolumeSetBoundaries() {
        XCTAssertEqual(ConfirmationPolicy.tier(of: .volumeSet(percent: -1)), .t4)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .volumeSet(percent: 0)), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .volumeSet(percent: 70)), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .volumeSet(percent: 71)), .t2)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .volumeSet(percent: 100)), .t2)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .volumeSet(percent: 101)), .t4)
    }

    func testTimerStartBoundaries() {
        XCTAssertEqual(ConfirmationPolicy.tier(of: .timerStart(minutes: 0)), .t4)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .timerStart(minutes: 1)), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .timerStart(minutes: 120)), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .timerStart(minutes: 121)), .t4)
    }

    func testTheOtherIntentsAreT0() {
        XCTAssertEqual(ConfirmationPolicy.tier(of: .mediaPlay), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .mediaPause), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .mediaNext), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .mediaPrevious), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .volumeStep(delta: 10)), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .volumeStep(delta: -5)), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .mute), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .unmute), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .openApp(bundleID: "com.apple.Safari",
                                                            name: "Safari")), .t0)
        XCTAssertEqual(ConfirmationPolicy.tier(of: .timerCancel), .t0)
    }

    func testDecideAllTenCombinations() {
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t0, secondFactorAvailable: false), .allow)
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t0, secondFactorAvailable: true), .allow)
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t1, secondFactorAvailable: false), .allow)
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t1, secondFactorAvailable: true), .allow)
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t2, secondFactorAvailable: false), .confirm)
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t2, secondFactorAvailable: true), .confirm)
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t3, secondFactorAvailable: false),
                       .deny(.secondFactorUnavailable))
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t3, secondFactorAvailable: true), .confirm)
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t4, secondFactorAvailable: false),
                       .deny(.tierT4))
        XCTAssertEqual(ConfirmationPolicy.decide(tier: .t4, secondFactorAvailable: true),
                       .deny(.tierT4))
    }
}
