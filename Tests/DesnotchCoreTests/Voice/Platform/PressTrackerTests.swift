import XCTest
@testable import DesnotchCore

final class PressTrackerTests: XCTestCase {
    func testNormalHoldAndRelease() {
        var tracker = PressTracker()
        XCTAssertTrue(tracker.press(at: 100.0))
        let held = tracker.release(at: 100.75)
        XCTAssertNotNil(held)
        if let held = held {
            XCTAssertEqual(held, 0.75, accuracy: 0.0001)
        }
    }

    func testDuplicatePressWhileDownIsIgnored() {
        var tracker = PressTracker()
        XCTAssertTrue(tracker.press(at: 100.0))
        XCTAssertFalse(tracker.press(at: 100.2))
        let held = tracker.release(at: 100.75)
        XCTAssertNotNil(held)
        if let held = held {
            XCTAssertEqual(held, 0.75, accuracy: 0.0001)
        }
    }

    func testReleaseWithoutPressReturnsNil() {
        var tracker = PressTracker()
        XCTAssertNil(tracker.release(at: 100.0))
    }

    func testReleaseBeforePressTimeClampsToZero() {
        var tracker = PressTracker()
        XCTAssertTrue(tracker.press(at: 100.0))
        let held = tracker.release(at: 99.0)
        XCTAssertNotNil(held)
        if let held = held {
            XCTAssertEqual(held, 0.0, accuracy: 0.0001)
        }
    }

    func testTwoConsecutivePressReleaseCycles() {
        var tracker = PressTracker()
        XCTAssertTrue(tracker.press(at: 100.0))
        let held1 = tracker.release(at: 100.5)
        XCTAssertNotNil(held1)
        if let held1 = held1 {
            XCTAssertEqual(held1, 0.5, accuracy: 0.0001)
        }

        XCTAssertTrue(tracker.press(at: 101.0))
        let held2 = tracker.release(at: 101.25)
        XCTAssertNotNil(held2)
        if let held2 = held2 {
            XCTAssertEqual(held2, 0.25, accuracy: 0.0001)
        }
    }

    func testPressWithinStaleWindowIsIgnored() {
        var tracker = PressTracker()
        XCTAssertTrue(tracker.press(at: 100.0))
        XCTAssertFalse(tracker.press(at: 134.9))
    }

    func testPressBeyondStaleThresholdResetsAndSucceeds() {
        var tracker = PressTracker()
        XCTAssertTrue(tracker.press(at: 100.0))
        XCTAssertTrue(tracker.press(at: 135.1))
        let held = tracker.release(at: 135.5)
        XCTAssertNotNil(held)
        if let held = held {
            XCTAssertEqual(held, 0.4, accuracy: 0.0001)
        }
    }
}

final class CarbonHotKeyOutcomeTests: XCTestCase {
    func testIsOwnRecognition() {
        let sig = CarbonHotKeyBox.signature
        let showNotchSig: OSType = 0x4453_4E54 // 'DSNT'

        XCTAssertTrue(CarbonHotKeyBox.isOwn(signature: sig, id: 1))
        XCTAssertTrue(CarbonHotKeyBox.isOwn(signature: sig, id: 2))
        XCTAssertTrue(CarbonHotKeyBox.isOwn(signature: sig, id: 3))

        XCTAssertFalse(CarbonHotKeyBox.isOwn(signature: sig, id: 0))
        XCTAssertFalse(CarbonHotKeyBox.isOwn(signature: sig, id: 4))
        XCTAssertFalse(CarbonHotKeyBox.isOwn(signature: showNotchSig, id: 1))
        XCTAssertFalse(CarbonHotKeyBox.isOwn(signature: 0, id: 1))
    }

    func testOutcomeMapping() {
        let sig = CarbonHotKeyBox.signature
        let showNotchSig: OSType = 0x4453_4E54

        XCTAssertEqual(CarbonHotKeyBox.outcome(signature: sig, id: 1, isRelease: false), .talkPressed)
        XCTAssertEqual(CarbonHotKeyBox.outcome(signature: sig, id: 1, isRelease: true), .talkReleased)
        XCTAssertEqual(CarbonHotKeyBox.outcome(signature: sig, id: 2, isRelease: false), .stopChord)
        XCTAssertNil(CarbonHotKeyBox.outcome(signature: sig, id: 2, isRelease: true))
        XCTAssertEqual(CarbonHotKeyBox.outcome(signature: sig, id: 3, isRelease: false), .escPressed)
        XCTAssertNil(CarbonHotKeyBox.outcome(signature: sig, id: 3, isRelease: true))

        XCTAssertNil(CarbonHotKeyBox.outcome(signature: showNotchSig, id: 1, isRelease: false))
        XCTAssertNil(CarbonHotKeyBox.outcome(signature: showNotchSig, id: 1, isRelease: true))
        XCTAssertNil(CarbonHotKeyBox.outcome(signature: sig, id: 9, isRelease: false))
    }

    func testPressTrackerEventMapping() {
        var tracker = PressTracker()
        let event1 = tracker.event(for: .talkPressed, at: 100.0)
        XCTAssertEqual(event1, .pressed)

        let eventDuplicate = tracker.event(for: .talkPressed, at: 100.2)
        XCTAssertNil(eventDuplicate)

        let stop = tracker.event(for: .stopChord, at: 100.4)
        XCTAssertEqual(stop, .stopKey)

        let esc = tracker.event(for: .escPressed, at: 100.5)
        XCTAssertEqual(esc, .cancelKey)

        let eventRelease = tracker.event(for: .talkReleased, at: 100.75)
        XCTAssertEqual(eventRelease, .released(heldSeconds: 0.75))

        let orphanRelease = tracker.event(for: .talkReleased, at: 101.0)
        XCTAssertNil(orphanRelease)
    }
}

@MainActor
final class CarbonPushToTalkLifecycleTests: XCTestCase {
    func testInitRegistersNothingAndDropIsSafe() {
        let ptt = CarbonPushToTalk(choice: .optionCommandV)
        _ = ptt
    }

    func testStopIsIdempotent() {
        let ptt = CarbonPushToTalk(choice: .optionCommandV)
        ptt.stop()
        ptt.stop()
    }

    func testStartAfterStopIsUnavailable() {
        let ptt = CarbonPushToTalk(choice: .optionCommandV)
        ptt.stop()
        let status = ptt.start()
        XCTAssertEqual(status, .unavailable)
    }

    func testCancelKeyArmingAfterStopIsANoOp() {
        let ptt = CarbonPushToTalk(choice: .optionCommandV)
        ptt.stop()
        ptt.setCancelKeyArmed(true)
        ptt.setCancelKeyArmed(false)
    }
}
