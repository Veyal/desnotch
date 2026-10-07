import XCTest
@testable import DesnotchCore

@MainActor
final class NotchPillPresentationTests: XCTestCase {
    func testRepeatedOpenFlashPublishesDistinctFeedbackEvents() {
        let presentation = NotchPillPresentation()
        presentation.flashOpen(for: 60)
        let first = presentation.feedbackToken

        presentation.flashOpen(for: 60)

        XCTAssertTrue(presentation.openFlash)
        XCTAssertEqual(presentation.feedbackToken, first + 1)
        presentation.reset()
    }

    func testResetClearsEveryTransientPresentationState() {
        let presentation = NotchPillPresentation()
        presentation.setHovering(true)
        presentation.flashVolume(0.5)
        presentation.flashOpen(for: 60)

        presentation.reset()

        XCTAssertFalse(presentation.isHovering)
        XCTAssertNil(presentation.volumeFlash)
        XCTAssertFalse(presentation.openFlash)
    }

    func testFlashKindDrivesDefaultHoldAndClearsWithTheFlash() {
        let presentation = NotchPillPresentation()
        presentation.flashOpen(kind: .power)
        XCTAssertTrue(presentation.openFlash)
        XCTAssertEqual(presentation.flashKind, .power)

        presentation.reset()
        XCTAssertNil(presentation.flashKind)
        XCTAssertFalse(presentation.openFlash)
    }

    func testReflashReplacesKindAndExtendsHoldWithoutClosing() {
        let presentation = NotchPillPresentation()
        presentation.flashOpen(for: 60, kind: .tray)
        let first = presentation.feedbackToken
        presentation.flashOpen(for: 60, kind: .reminder)

        XCTAssertEqual(presentation.flashKind, .reminder)
        XCTAssertTrue(presentation.openFlash)
        XCTAssertEqual(presentation.feedbackToken, first + 1)
        presentation.flashOpen(for: 60)
        XCTAssertNil(presentation.flashKind, "an unclassified flash has no spotlight")
        presentation.reset()
    }

    func testAShorterFlashNeverCutsALongerHoldShort() {
        // A 4s hold, then a 1.6s flash 0.5s later: the hold still ends at the original 4s and
        // the longer flash keeps owning the spotlight kind.
        let held = NotchPillPresentation.mergedHold(currentDeadline: 104, now: 100.5, duration: 1.6)
        XCTAssertEqual(held.deadline, 104)
        XCTAssertFalse(held.extends)
        // A longer flash extends the hold and takes over.
        let longer = NotchPillPresentation.mergedHold(currentDeadline: 102, now: 100.5, duration: 4)
        XCTAssertEqual(longer.deadline, 104.5)
        XCTAssertTrue(longer.extends)
        // Equal deadlines go to the newer flash; an expired or absent hold starts fresh.
        XCTAssertTrue(NotchPillPresentation.mergedHold(currentDeadline: 102, now: 100, duration: 2).extends)
        XCTAssertEqual(NotchPillPresentation.mergedHold(currentDeadline: 99, now: 100, duration: 1).deadline, 101)
        XCTAssertEqual(NotchPillPresentation.mergedHold(currentDeadline: nil, now: 100, duration: 1).deadline, 101)

        let presentation = NotchPillPresentation()
        presentation.flashOpen(for: 60, kind: .timerComplete)
        presentation.flashOpen(for: 1, kind: .reminder)
        XCTAssertEqual(presentation.flashKind, .timerComplete, "the longer hold keeps its kind")
        XCTAssertTrue(presentation.openFlash)
        presentation.reset()
    }

    func testFlashKindClearsWhenTheHoldExpires() async throws {
        let presentation = NotchPillPresentation()
        presentation.flashOpen(for: 0.05, kind: .notification)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(presentation.openFlash)
        XCTAssertNil(presentation.flashKind)
    }
}
