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
                CGSize(width: .infinity, height: 80)
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

    func testGrowthNeverShrinksTheOtherDimension() {
        let current = CGSize(width: 504, height: 700)
        let target = PillPanelSizingPolicy.growthTarget(
            contentSize: CGSize(width: 520, height: 100),
            currentWindowSize: current
        )
        XCTAssertEqual(target, CGSize(width: 544, height: 700))
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
