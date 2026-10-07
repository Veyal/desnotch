import XCTest
@testable import DesnotchCore

final class NeedsYouTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testNewNeedsYouKeyIsFreshOnceThenKnown() {
        var tracker = NeedsYouTracker()
        XCTAssertEqual(tracker.update(needsYou: ["a"], present: ["a"], now: t0), ["a"])
        XCTAssertEqual(tracker.update(needsYou: ["a"], present: ["a"], now: t0.addingTimeInterval(5)), [])
    }

    func testSessionDroppedByATransientScanDoesNotNotifyAgainWhenItReturns() {
        var tracker = NeedsYouTracker()
        _ = tracker.update(needsYou: ["a"], present: ["a"], now: t0)
        // A failed source scan returns nothing at all.
        XCTAssertEqual(tracker.update(needsYou: [], present: [], now: t0.addingTimeInterval(5)), [])
        XCTAssertEqual(tracker.update(needsYou: ["a"], present: ["a"], now: t0.addingTimeInterval(10)), [])
    }

    func testAbsenceBeyondTheGraceForgetsTheKey() {
        var tracker = NeedsYouTracker()
        _ = tracker.update(needsYou: ["a"], present: ["a"], now: t0)
        _ = tracker.update(needsYou: [], present: [], now: t0.addingTimeInterval(NeedsYouTracker.grace + 1))
        XCTAssertEqual(
            tracker.update(needsYou: ["a"], present: ["a"], now: t0.addingTimeInterval(NeedsYouTracker.grace + 5)),
            ["a"]
        )
    }

    func testSessionBackToWorkingNotifiesOnItsNextFlip() {
        var tracker = NeedsYouTracker()
        _ = tracker.update(needsYou: ["a"], present: ["a"], now: t0)
        // Present but no longer needs-you: a quick turn must not be swallowed.
        XCTAssertEqual(tracker.update(needsYou: [], present: ["a"], now: t0.addingTimeInterval(5)), [])
        XCTAssertEqual(tracker.update(needsYou: ["a"], present: ["a"], now: t0.addingTimeInterval(20)), ["a"])
    }

    func testResetForgetsEverything() {
        var tracker = NeedsYouTracker()
        _ = tracker.update(needsYou: ["a"], present: ["a"], now: t0)
        tracker.reset()
        XCTAssertEqual(tracker.update(needsYou: ["a"], present: ["a"], now: t0.addingTimeInterval(1)), ["a"])
    }
}
