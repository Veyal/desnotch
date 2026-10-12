import XCTest
@testable import DesnotchCore

final class PillInteractionPolicyTests: XCTestCase {
    func testCursorAloneDrivesHover() {
        XCTAssertTrue(PillInteractionPolicy.wantsHover(cursorInside: true, pinnedOpen: false, voiceActive: false))
        XCTAssertFalse(PillInteractionPolicy.wantsHover(cursorInside: false, pinnedOpen: false, voiceActive: false))
    }

    func testPinKeepsTheHoverStateWithoutTheCursor() {
        XCTAssertTrue(PillInteractionPolicy.wantsHover(cursorInside: false, pinnedOpen: true, voiceActive: false))
        XCTAssertTrue(PillInteractionPolicy.wantsHover(cursorInside: true, pinnedOpen: true, voiceActive: false))
    }

    func testPinNeverMakesThePanelSwallowClicksOutsideThePill() {
        XCTAssertFalse(PillInteractionPolicy.acceptsMouse(cursorInside: false))
        XCTAssertTrue(PillInteractionPolicy.acceptsMouse(cursorInside: true))
    }

    // MARK: Interactive rect

    /// Content-floor panel at the top of a 1512x982 screen: midX 752, maxY 976.
    private let panel = CGRect(x: 500, y: 600, width: 504, height: 376)

    func testNoInteractiveRectUntilThePillReportsASize() {
        XCTAssertNil(PillInteractionPolicy.interactiveRect(panelFrame: panel, pillContentSize: .zero))
        XCTAssertNil(PillInteractionPolicy.interactiveRect(panelFrame: panel, pillContentSize: CGSize(width: 300, height: 0)))
        XCTAssertNil(PillInteractionPolicy.interactiveRect(panelFrame: panel, pillContentSize: CGSize(width: 0, height: 40)))
    }

    func testInteractiveRectIsTopCenteredWithSlackAndTopOverscan() {
        let rect = PillInteractionPolicy.interactiveRect(
            panelFrame: panel, pillContentSize: CGSize(width: 300, height: 40)
        )
        // 4pt slack each side and below; 2pt extra above the panel top.
        XCTAssertEqual(rect, CGRect(x: 598, y: 932, width: 308, height: 46))
    }

    func testCursorPinnedToTheAbsoluteScreenTopCountsAsInside() {
        guard let rect = PillInteractionPolicy.interactiveRect(
            panelFrame: panel, pillContentSize: CGSize(width: 300, height: 40)
        ) else { return XCTFail("expected a rect") }
        XCTAssertTrue(rect.contains(CGPoint(x: 752, y: 976)), "y == screen top must hit")
        XCTAssertFalse(rect.contains(CGPoint(x: 752, y: 978)), "overscan is only 2pt")
    }

    func testPointsOutsideTheSlackAreMenuBarClicksNotPillHits() {
        guard let rect = PillInteractionPolicy.interactiveRect(
            panelFrame: panel, pillContentSize: CGSize(width: 300, height: 40)
        ) else { return XCTFail("expected a rect") }
        XCTAssertTrue(rect.contains(CGPoint(x: 598, y: 960)))
        XCTAssertFalse(rect.contains(CGPoint(x: 597, y: 960)))
        XCTAssertFalse(rect.contains(CGPoint(x: 752, y: 931)))
    }

    func testInteractiveRectNeverExceedsThePanel() {
        let rect = PillInteractionPolicy.interactiveRect(
            panelFrame: panel, pillContentSize: CGSize(width: 900, height: 700)
        )
        XCTAssertEqual(rect, CGRect(x: 500, y: 600, width: 504, height: 378))
    }
}
