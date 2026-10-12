import XCTest
@testable import DesnotchCore

final class LevelMeterTests: XCTestCase {
    func testLevelFromRMSZeroAndOne() {
        XCTAssertEqual(LevelMeter.level(fromRMS: 0), 0)
        XCTAssertEqual(LevelMeter.level(fromRMS: 1.0), 1.0)
    }

    func testLevelFromRMSDecibelPoints() {
        XCTAssertEqual(LevelMeter.level(fromRMS: 0.00316), 0, accuracy: 0.001)
        XCTAssertEqual(LevelMeter.level(fromRMS: 0.0316), 0.4, accuracy: 0.01)
        XCTAssertEqual(LevelMeter.level(fromRMS: 0.1), 0.6, accuracy: 0.01)
    }

    func testLevelFromRMSClampingAndNaN() {
        XCTAssertEqual(LevelMeter.level(fromRMS: 2.0), 1.0)
        XCTAssertEqual(LevelMeter.level(fromRMS: -0.5), 0)
        XCTAssertEqual(LevelMeter.level(fromRMS: Float.nan), 0)
    }

    func testBarsPaddingAndSlicing() {
        XCTAssertEqual(LevelMeter.bars(from: []), [0, 0, 0, 0, 0])
        XCTAssertEqual(LevelMeter.bars(from: [0.5]), [0, 0, 0, 0, 0.5])

        let sevenValues: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        let expectedLastFive: [Float] = [0.3, 0.4, 0.5, 0.6, 0.7]
        XCTAssertEqual(LevelMeter.bars(from: sevenValues), expectedLastFive)
    }

    func testEmitThrottleCadenceAndMonotonicity() {
        var throttle = EmitThrottle(maxHz: 15)
        let t0: TimeInterval = 10.0

        // First call emits
        XCTAssertTrue(throttle.shouldEmit(at: t0))

        // Call at +0.03125 (< 0.0667s) does not emit
        XCTAssertFalse(throttle.shouldEmit(at: t0 + 0.03125))

        // Call at +0.0703125 (>= 0.0667s from last emit at t0) emits
        XCTAssertTrue(throttle.shouldEmit(at: t0 + 0.0703125))

        // Non-monotonic time (earlier than last emit) does not emit
        XCTAssertFalse(throttle.shouldEmit(at: t0 + 0.05))
    }
}
