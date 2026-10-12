import XCTest
@testable import DesnotchCore

private func dateAt(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

/// Ten `.t1` events at 1000...1009, each allowed.
private func filledT1() -> RateLimiter {
    var rate = RateLimiter()
    for index in 0..<10 {
        XCTAssertEqual(rate.tryConsume(tier: .t1, now: dateAt(1000 + Double(index))), .allowed)
    }
    return rate
}

final class RateLimiterTests: XCTestCase {
    func testL1_tenT1ConsumesAllowed() {
        var rate = RateLimiter()
        for index in 0..<10 {
            XCTAssertEqual(rate.tryConsume(tier: .t1, now: dateAt(1000 + Double(index))), .allowed)
        }
    }

    func testL2_eleventhT1IsLimited() {
        var rate = filledT1()
        guard case .limited(let retryAfter) = rate.tryConsume(tier: .t1, now: dateAt(1010)) else {
            XCTFail("expected limited")
            return
        }
        XCTAssertEqual(retryAfter, 50, accuracy: 0.0001)
    }

    func testL3_retryAfterShrinks() {
        var rate = filledT1()
        _ = rate.tryConsume(tier: .t1, now: dateAt(1010))
        guard case .limited(let retryAfter) = rate.tryConsume(tier: .t1, now: dateAt(1059.5)) else {
            XCTFail("expected limited")
            return
        }
        XCTAssertEqual(retryAfter, 0.5, accuracy: 0.0001)
    }

    func testL4_eventExactlyOneWindowOldIsDropped() {
        var rate = filledT1()
        _ = rate.tryConsume(tier: .t1, now: dateAt(1010))
        _ = rate.tryConsume(tier: .t1, now: dateAt(1059.5))
        XCTAssertEqual(rate.tryConsume(tier: .t1, now: dateAt(1060)), .allowed)
    }

    func testL5_threeT2Allowed() {
        var rate = RateLimiter()
        XCTAssertEqual(rate.tryConsume(tier: .t2, now: dateAt(0)), .allowed)
        XCTAssertEqual(rate.tryConsume(tier: .t2, now: dateAt(100)), .allowed)
        XCTAssertEqual(rate.tryConsume(tier: .t2, now: dateAt(200)), .allowed)
    }

    func testL6_fourthT2IsLimited() {
        var rate = RateLimiter()
        _ = rate.tryConsume(tier: .t2, now: dateAt(0))
        _ = rate.tryConsume(tier: .t2, now: dateAt(100))
        _ = rate.tryConsume(tier: .t2, now: dateAt(200))
        guard case .limited(let retryAfter) = rate.tryConsume(tier: .t2, now: dateAt(300)) else {
            XCTFail("expected limited")
            return
        }
        XCTAssertEqual(retryAfter, 300, accuracy: 0.0001)
    }

    func testL7_t2FreesAtSixHundred() {
        var rate = RateLimiter()
        _ = rate.tryConsume(tier: .t2, now: dateAt(0))
        _ = rate.tryConsume(tier: .t2, now: dateAt(100))
        _ = rate.tryConsume(tier: .t2, now: dateAt(200))
        _ = rate.tryConsume(tier: .t2, now: dateAt(300))
        XCTAssertEqual(rate.tryConsume(tier: .t2, now: dateAt(600)), .allowed)
    }

    func testL8_t3SharesT2Bucket() {
        var rate = RateLimiter()
        _ = rate.tryConsume(tier: .t2, now: dateAt(0))
        _ = rate.tryConsume(tier: .t2, now: dateAt(100))
        _ = rate.tryConsume(tier: .t2, now: dateAt(200))
        guard case .limited = rate.tryConsume(tier: .t3, now: dateAt(300)) else {
            XCTFail("expected limited")
            return
        }
    }

    func testL9_refusedCallLeavesEventsUnchanged() {
        var rate = filledT1()
        _ = rate.tryConsume(tier: .t1, now: dateAt(1010))
        XCTAssertEqual(rate.t1Events.count, 10)
        XCTAssertEqual(rate.t2Events.count, 0)
    }

    func testL10_t1AndT2WindowsAreIndependent() {
        var rate = filledT1()
        XCTAssertEqual(rate.tryConsume(tier: .t2, now: dateAt(1010)), .allowed)
        XCTAssertEqual(rate.t1Events.count, 10)
        XCTAssertEqual(rate.t2Events.count, 1)
    }

    func testL11_t0AndT4AreUnlimited() {
        var rate = RateLimiter()
        for index in 0..<100 {
            XCTAssertEqual(rate.tryConsume(tier: .t0, now: dateAt(Double(index))), .allowed)
            XCTAssertEqual(rate.tryConsume(tier: .t4, now: dateAt(Double(index))), .allowed)
        }
        XCTAssertTrue(rate.t1Events.isEmpty)
        XCTAssertTrue(rate.t2Events.isEmpty)
    }
}
