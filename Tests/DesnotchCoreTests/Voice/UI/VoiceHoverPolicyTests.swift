import XCTest
@testable import DesnotchCore

final class VoiceHoverPolicyTests: XCTestCase {
    func testWantsHoverTruthTable() {
        let rows: [(cursor: Bool, pinned: Bool, voice: Bool, hover: Bool)] = [
            (false, false, false, false),
            (true, false, false, true),
            (false, true, false, true),
            (false, false, true, true),
            (true, true, false, true),
            (true, false, true, true),
            (false, true, true, true),
            (true, true, true, true)
        ]
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            XCTAssertEqual(
                PillInteractionPolicy.wantsHover(
                    cursorInside: row.cursor, pinnedOpen: row.pinned, voiceActive: row.voice
                ),
                row.hover,
                "cursor \(row.cursor) pinned \(row.pinned) voice \(row.voice)"
            )
        }
    }

    func testAcceptsMouseIsUnchanged() {
        XCTAssertTrue(PillInteractionPolicy.acceptsMouse(cursorInside: true))
        XCTAssertFalse(PillInteractionPolicy.acceptsMouse(cursorInside: false))
    }
}
