import XCTest
@testable import DesnotchCore

/// The expanded stack trims its lists to fit the screen instead of running off it (it cannot
/// scroll: scrolling over the pill adjusts the volume).
final class PillStackBudgetTests: XCTestCase {
    /// Every section enabled with three items in each list: about 940pt when rendered.
    private let everything = PillStackEstimate(
        topInset: 38, hasNotification: true, hasMedia: true, hasTimer: true, agents: 3, processes: 3,
        hasCalendar: true, hasReminders: true, hasBattery: true, clipboard: 3, trayEnabled: true, tray: 3
    )

    func testUnlimitedOrUnknownScreenKeepsFullLists() {
        XCTAssertEqual(PillRowCaps.fitting(everything, maxHeight: nil), .full)
        XCTAssertEqual(PillRowCaps.fitting(everything, maxHeight: .infinity), .full)
        XCTAssertEqual(PillRowCaps.fitting(everything, maxHeight: .nan), .full)
    }

    func testEstimateTracksTheRenderedStackAndErrsHigh() {
        // Measured from the headless render of this exact configuration: ~939pt.
        let estimate = everything.height(caps: .full)
        XCTAssertGreaterThanOrEqual(estimate, 900)
        XCTAssertLessThanOrEqual(estimate, 1040)
    }

    func testTiersShrinkListsInOrderAsTheScreenGetsShorter() {
        let full = everything.height(caps: .full)
        let reduced = everything.height(caps: .reduced)
        let minimal = everything.height(caps: .minimal)
        XCTAssertGreaterThan(full, reduced)
        XCTAssertGreaterThan(reduced, minimal)

        XCTAssertEqual(PillRowCaps.fitting(everything, maxHeight: full), .full)
        XCTAssertEqual(PillRowCaps.fitting(everything, maxHeight: full - 1), .reduced)
        XCTAssertEqual(PillRowCaps.fitting(everything, maxHeight: reduced - 1), .minimal)
        XCTAssertEqual(PillRowCaps.fitting(everything, maxHeight: 100), .minimal, "never below one row")
    }

    func testAFewSectionsAlwaysFitAndOnlyRealRowsCount() {
        let light = PillStackEstimate(topInset: 38, hasMedia: true, agents: 1, trayEnabled: true, tray: 0)
        XCTAssertEqual(PillRowCaps.fitting(light, maxHeight: 700), .full)
        // A list with fewer items than its cap costs only its real rows.
        XCTAssertEqual(
            light.height(caps: .full), light.height(caps: .reduced),
            "one agent row is one agent row in every tier"
        )
    }

    func testFullTierMatchesTheStaticListLimits() {
        XCTAssertEqual(PillRowCaps.full.agents, PillLimits.agentRows)
        XCTAssertEqual(PillRowCaps.full.processes, PillLimits.processRows)
        XCTAssertEqual(PillRowCaps.full.tray, PillLimits.trayRows)
        XCTAssertEqual(PillRowCaps.full.clipboard, PillLimits.clipboardRows)
    }
}
