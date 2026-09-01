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
}
