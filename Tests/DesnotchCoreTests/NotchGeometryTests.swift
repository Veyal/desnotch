import XCTest
@testable import DesnotchCore

/// Panel anchoring and sizing rules, driven through the pure `NotchGeometry` entry points so
/// no real `NSScreen` is needed.
final class NotchGeometryTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // MARK: Placement

    func testNotchScreenPanelIsFlushWithTheTopAndCentered() {
        let placement = NotchGeometry.placement(
            screenFrame: builtIn, hasPhysicalNotch: true, windowSize: CGSize(width: 504, height: 392)
        )
        XCTAssertTrue(placement.hasPhysicalNotch)
        XCTAssertEqual(placement.frame, CGRect(x: 504, y: 590, width: 504, height: 392))
        XCTAssertEqual(placement.frame.maxY, builtIn.maxY)
        XCTAssertEqual(placement.frame.midX, builtIn.midX)
    }

    func testNotchlessScreenUsesTheSameFlushTopFakeNotchAnchor() {
        let size = CGSize(width: 504, height: 392)
        let real = NotchGeometry.placement(screenFrame: builtIn, hasPhysicalNotch: true, windowSize: size)
        let fake = NotchGeometry.placement(screenFrame: builtIn, hasPhysicalNotch: false, windowSize: size)
        XCTAssertFalse(fake.hasPhysicalNotch)
        XCTAssertEqual(fake.frame, real.frame, "both screen types share one code path")
    }

    func testFractionalWindowSizesProduceAnIntegralFrameThatStaysFlushWithTheTop() {
        let placement = NotchGeometry.placement(
            screenFrame: builtIn, hasPhysicalNotch: false, windowSize: CGSize(width: 503.2, height: 391.1)
        )
        XCTAssertEqual(placement.frame.size, CGSize(width: 504, height: 392))
        XCTAssertEqual(placement.frame.origin.x, placement.frame.origin.x.rounded())
        XCTAssertEqual(placement.frame.maxY, builtIn.maxY, "a fractional top edge leaves a wallpaper hairline")
    }

    func testPlacementFollowsASecondaryDisplayWithAnOffsetOrigin() {
        let external = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let placement = NotchGeometry.placement(
            screenFrame: external, hasPhysicalNotch: false, windowSize: CGSize(width: 500, height: 360)
        )
        XCTAssertEqual(placement.frame, CGRect(x: 2222, y: 520, width: 500, height: 360))
        XCTAssertEqual(placement.frame.maxY, external.maxY)
    }

    func testSelectedSnapshotDecidesWhichFramePlacementUses() {
        // Screen choice and placement compose: the notch display wins "Automatic", and the
        // panel lands on that display rather than on the first one.
        let external = ScreenSnapshot(
            identifier: "external", name: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415)
        )
        let laptop = ScreenSnapshot(
            identifier: "builtin", name: "Built-in",
            frame: CGRect(x: 2560, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 2560, y: 0, width: 1512, height: 944),
            safeAreaTop: 38,
            auxiliaryTopLeft: CGRect(x: 2560, y: 944, width: 656, height: 38),
            auxiliaryTopRight: CGRect(x: 3416, y: 944, width: 656, height: 38)
        )
        let screens = [external, laptop]
        guard let index = DisplaySelection.preferredIndex(in: screens, identifier: nil) else {
            return XCTFail("expected a display")
        }
        XCTAssertEqual(index, 1)
        let chosen = screens[index]
        let placement = NotchGeometry.placement(
            screenFrame: chosen.frame, hasPhysicalNotch: chosen.hasNotch, windowSize: CGSize(width: 504, height: 392)
        )
        XCTAssertTrue(placement.hasPhysicalNotch)
        XCTAssertEqual(placement.frame.midX, chosen.frame.midX)
        XCTAssertEqual(placement.frame.maxY, chosen.frame.maxY)
    }

    // MARK: Sizing

    func testWindowSizeAddsShadowRoomOnSidesAndBottomOnly() {
        XCTAssertEqual(
            NotchGeometry.windowSize(forContent: CGSize(width: 300, height: 100)),
            CGSize(
                width: 300 + NotchGeometry.shadowInsetX * 2,
                height: 100 + NotchGeometry.shadowInsetBottom
            )
        )
    }

    func testFallbackWindowSizeIsTheFallbackContentPlusShadowRoom() {
        XCTAssertEqual(
            NotchGeometry.fallbackWindowSize,
            NotchGeometry.windowSize(
                forContent: CGSize(width: NotchGeometry.fallbackWidth, height: NotchGeometry.fallbackHeight)
            )
        )
    }

    func testExpandedWidthHonorsPreferenceUntilTheShapeWouldNotCoverTheCutout() {
        // cutout 200 + two 44pt wings = 288 is the floor.
        XCTAssertEqual(NotchGeometry.expandedPillWidth(preferred: 300, cutoutWidth: 200, wingWidth: 44), 300)
        XCTAssertEqual(NotchGeometry.expandedPillWidth(preferred: 288, cutoutWidth: 200, wingWidth: 44), 288)
        XCTAssertEqual(NotchGeometry.expandedPillWidth(preferred: 250, cutoutWidth: 200, wingWidth: 44), 288)
    }

    /// The worst-case minimized pill (timer label wing + mic/camera lane, on both a synthetic
    /// and a real-notch cutout) is wider than the default 300pt; the expanded shape must never
    /// be narrower than the pill it grows from.
    func testExpandedWidthNeverNarrowerThanCompactWidth() {
        let extra = WingMetrics.extraWidth(
            left: .timer, right: .agent, timerShowsLabel: true, agentLabelLength: 2
        )
        for cutout in [CGFloat(200), 224] {
            let compact = cutout + 2 * (WingMetrics.baseWidth + extra + WingMetrics.privacyLane)
            XCTAssertGreaterThan(compact, 300, "the scenario really overflows the default width")
            XCTAssertEqual(
                NotchGeometry.expandedPillWidth(
                    preferred: 300, cutoutWidth: cutout, wingWidth: WingMetrics.baseWidth, compactWidth: compact
                ),
                compact
            )
            XCTAssertGreaterThanOrEqual(
                NotchGeometry.expandedPillWidth(
                    preferred: 420, cutoutWidth: cutout, wingWidth: WingMetrics.baseWidth, compactWidth: compact
                ),
                compact
            )
        }
    }

    // MARK: Cutout size

    func testNoSafeAreaMeansNoCutoutEvenWithAuxiliaryAreas() {
        XCTAssertNil(NotchGeometry.notchSize(
            safeAreaTop: 0, screenWidth: 1512, auxiliaryLeftWidth: 656, auxiliaryRightWidth: 656
        ))
    }

    func testCutoutWidthIsTheGapBetweenTheAuxiliaryAreas() {
        XCTAssertEqual(
            NotchGeometry.notchSize(
                safeAreaTop: 32, screenWidth: 1512, auxiliaryLeftWidth: 700, auxiliaryRightWidth: 740
            ),
            CGSize(width: 72, height: 32)
        )
    }

    func testOverlappingOrPartialAuxiliaryAreasFallBackToAGenerousDefault() {
        // Gap would be zero or negative.
        XCTAssertEqual(
            NotchGeometry.notchSize(
                safeAreaTop: 38, screenWidth: 1000, auxiliaryLeftWidth: 600, auxiliaryRightWidth: 400
            ),
            CGSize(width: 200, height: 38)
        )
        // Only one side reported.
        XCTAssertEqual(
            NotchGeometry.notchSize(
                safeAreaTop: 38, screenWidth: 1512, auxiliaryLeftWidth: 656, auxiliaryRightWidth: nil
            ),
            CGSize(width: 200, height: 38)
        )
    }
}
