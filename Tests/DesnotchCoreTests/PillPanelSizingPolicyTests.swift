import XCTest
@testable import DesnotchCore

final class PillPanelSizingPolicyTests: XCTestCase {
    func testNormalizesFractionalAndInvalidMeasurements() {
        XCTAssertEqual(
            PillPanelSizingPolicy.normalizedContentSize(CGSize(width: 299.1, height: 80.01)),
            CGSize(width: 300, height: 81)
        )
        XCTAssertEqual(
            PillPanelSizingPolicy.normalizedContentSize(
                CGSize(width: CGFloat.infinity, height: 80)
            ),
            .zero
        )
    }

    func testStableFloorNeedsNoResizeForNormalExpansion() {
        let current = NotchGeometry.windowSize(forContent: NotchGeometry.contentFloor)
        XCTAssertNil(
            PillPanelSizingPolicy.growthTarget(
                contentSize: CGSize(width: 300, height: 240),
                currentWindowSize: current
            )
        )
    }

    func testSpringOvershootAndTypicalStacksNeverResizeThePanel() {
        let current = NotchGeometry.windowSize(forContent: NotchGeometry.contentFloor)
        // Widest supported pill (480) plus 5% overshoot (504), and a tall realistic stack.
        for size in [CGSize(width: 504, height: 430), CGSize(width: 480, height: 420),
                     CGSize(width: 506, height: 700)] {
            XCTAssertNil(
                PillPanelSizingPolicy.growthTarget(contentSize: size, currentWindowSize: current),
                "\(size) must fit the stable floor"
            )
        }
    }

    @MainActor
    func testFloorCoversTheWidestExpandedWidthWithOvershoot() {
        let widest = CGFloat(SettingsStore.expandedWidthRange.upperBound)
        XCTAssertGreaterThanOrEqual(NotchGeometry.contentFloor.width, widest * 1.054)
    }

    func testGrowthIsQuantizedWithHeadroomAndNeverShrinksTheOtherDimension() {
        let current = NotchGeometry.windowSize(forContent: NotchGeometry.contentFloor)
        // 800pt of content exceeds the 720pt floor: 800 + 64 headroom rounds up to 896.
        let target = PillPanelSizingPolicy.growthTarget(
            contentSize: CGSize(width: 300, height: 800),
            currentWindowSize: current
        )
        XCTAssertEqual(
            target,
            NotchGeometry.windowSize(forContent: CGSize(width: NotchGeometry.contentFloor.width, height: 896))
        )
    }

    func testSmallGrowthStepsAbsorbedByHeadroomDoNotResizeAgain() {
        let current = NotchGeometry.windowSize(forContent: NotchGeometry.contentFloor)
        guard let first = PillPanelSizingPolicy.growthTarget(
            contentSize: CGSize(width: 300, height: 725), currentWindowSize: current
        ) else { return XCTFail("725pt of content exceeds the floor") }
        // One more row (up to the headroom) must not trigger another AppKit resize.
        XCTAssertNil(
            PillPanelSizingPolicy.growthTarget(
                contentSize: CGSize(width: 300, height: 760), currentWindowSize: first
            )
        )
    }

    func testGrownCapacityNeverShrinksAndRespectsTheFloor() {
        XCTAssertEqual(PillPanelSizingPolicy.grownCapacity(content: 100, current: 300, floor: 520), 520)
        XCTAssertEqual(PillPanelSizingPolicy.grownCapacity(content: 100, current: 900, floor: 520), 900)
        XCTAssertEqual(PillPanelSizingPolicy.grownCapacity(content: 521, current: 520, floor: 520), 640)
        XCTAssertEqual(PillPanelSizingPolicy.grownCapacity(content: 520, current: 520, floor: 520), 520)
    }

    func testFloorIsCappedToSmallScreens() {
        let small = NotchGeometry.effectiveContentFloor(forScreenSize: CGSize(width: 400, height: 500))
        XCTAssertEqual(small, CGSize(width: 400 - NotchGeometry.shadowInsetX * 2, height: 460))
        let large = NotchGeometry.effectiveContentFloor(forScreenSize: CGSize(width: 3000, height: 2000))
        XCTAssertEqual(large, NotchGeometry.contentFloor)
    }

    func testGrowthUsesTheSuppliedFloor() {
        let floor = CGSize(width: 300, height: 200)
        let current = NotchGeometry.windowSize(forContent: floor)
        XCTAssertNil(
            PillPanelSizingPolicy.growthTarget(
                contentSize: CGSize(width: 280, height: 190), currentWindowSize: current, floor: floor
            )
        )
        XCTAssertNotNil(
            PillPanelSizingPolicy.growthTarget(
                contentSize: CGSize(width: 280, height: 210), currentWindowSize: current, floor: floor
            )
        )
    }

    func testCoalescingKeepsLargestSampleFromOneFrame() {
        XCTAssertEqual(
            PillPanelSizingPolicy.coalesced(
                CGSize(width: 300, height: 180),
                CGSize(width: 280, height: 260)
            ),
            CGSize(width: 300, height: 260)
        )
    }
}
