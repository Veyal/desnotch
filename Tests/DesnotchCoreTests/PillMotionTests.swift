import SwiftUI
import XCTest
@testable import DesnotchCore

final class PillStaggerTests: XCTestCase {
    func testDelayScalesWithIndexAndClampsAtTheCap() {
        XCTAssertEqual(PillStagger.delay(index: 0, step: 0.035, cap: 6), 0)
        XCTAssertEqual(PillStagger.delay(index: 3, step: 0.035, cap: 6), 0.105, accuracy: 1e-9)
        XCTAssertEqual(PillStagger.delay(index: 6, step: 0.035, cap: 6), 0.21, accuracy: 1e-9)
        XCTAssertEqual(PillStagger.delay(index: 10, step: 0.035, cap: 6), 0.21, accuracy: 1e-9)
    }

    func testNegativeIndexAndNegativeCapNeverProduceNegativeDelay() {
        XCTAssertEqual(PillStagger.delay(index: -4, step: 0.05, cap: 6), 0)
        XCTAssertEqual(PillStagger.delay(index: 4, step: 0.05, cap: -1), 0)
    }

    func testZeroStepIsNoStagger() {
        XCTAssertEqual(PillStagger.delay(index: 5, step: 0, cap: 6), 0)
    }

    func testNaturalRankFollowsStackOrder() {
        for (index, kind) in PillSectionKind.allCases.enumerated() {
            XCTAssertEqual(PillStagger.rank(of: kind, spotlight: nil), index)
        }
    }

    /// The staged mount walks sections by `order`, so it must be the stack position.
    func testSectionOrderIsTheStackPosition() {
        for (index, kind) in PillSectionKind.allCases.enumerated() {
            XCTAssertEqual(kind.order, index)
        }
    }

    func testSpotlightRanksFirstAndShiftsOnlyTheSectionsAboveIt() {
        let order = PillSectionKind.allCases
        let spotlight = PillSectionKind.agents
        let spotlightIndex = order.firstIndex(of: spotlight)!
        XCTAssertEqual(PillStagger.rank(of: spotlight, spotlight: spotlight), 0)
        for (index, kind) in order.enumerated() where kind != spotlight {
            let expected = index < spotlightIndex ? index + 1 : index
            XCTAssertEqual(PillStagger.rank(of: kind, spotlight: spotlight), expected)
        }
    }

    func testSpotlightRanksAreAUniquePermutation() {
        let order = PillSectionKind.allCases
        for spotlight in order {
            let ranks = order.map { PillStagger.rank(of: $0, spotlight: spotlight) }
            XCTAssertEqual(Set(ranks), Set(0..<order.count), "spotlight \(spotlight)")
        }
    }

    func testSpotlightOutsideTheOrderFallsBackToNaturalRank() {
        let order: [PillSectionKind] = [.media, .timer]
        XCTAssertEqual(PillStagger.rank(of: .timer, order: order, spotlight: .tray), 1)
        XCTAssertEqual(PillStagger.rank(of: .tray, order: order, spotlight: nil), 0)
    }
}

final class PillFlashKindTests: XCTestCase {
    func testEveryKindHasAPositiveHoldAndASpotlightSection() {
        for kind in PillFlashKind.allCases {
            XCTAssertGreaterThan(kind.holdDuration, 0)
            XCTAssertTrue(PillSectionKind.allCases.contains(kind.spotlight))
        }
    }

    func testHoldDurationsAndSpotlights() {
        XCTAssertEqual(PillFlashKind.tray.holdDuration, 1.6)
        XCTAssertEqual(PillFlashKind.power.holdDuration, 2.4)
        XCTAssertEqual(PillFlashKind.reminder.holdDuration, 1.6)
        XCTAssertEqual(PillFlashKind.timerStarted.holdDuration, 2.0)
        XCTAssertEqual(PillFlashKind.timerComplete.holdDuration, 4.0)
        XCTAssertEqual(PillFlashKind.notification.holdDuration, 4.0)
        XCTAssertEqual(PillFlashKind.tray.spotlight, .tray)
        XCTAssertEqual(PillFlashKind.power.spotlight, .battery)
        XCTAssertEqual(PillFlashKind.reminder.spotlight, .reminders)
        XCTAssertEqual(PillFlashKind.timerStarted.spotlight, .timer)
        XCTAssertEqual(PillFlashKind.timerComplete.spotlight, .timer)
        XCTAssertEqual(PillFlashKind.notification.spotlight, .notification)
    }

    func testPowerRimFollowsChargingState() {
        XCTAssertEqual(PillFlashKind.power.rim(pluggedIn: true).hue, .green)
        XCTAssertEqual(PillFlashKind.power.rim(pluggedIn: false).hue, .amber)
        XCTAssertEqual(PillFlashKind.timerStarted.rim().hue, .cyan)
        XCTAssertEqual(PillFlashKind.tray.rim().hue, .neutral)
    }

    func testRimOpacitiesAreVisibleButSubtle() {
        for kind in PillFlashKind.allCases {
            let opacity = kind.rim().opacity
            XCTAssertGreaterThanOrEqual(opacity, 0.25)
            XCTAssertLessThanOrEqual(opacity, 0.6)
        }
    }
}

final class NotchShapeTests: XCTestCase {
    func testRadiiAreClampedToTheRect() {
        let tiny = NotchShape.clampedRadii(topEar: 6, bottomRadius: 24, in: CGSize(width: 10, height: 8))
        XCTAssertLessThanOrEqual(tiny.ear, 4)
        XCTAssertGreaterThanOrEqual(tiny.bottom, 0)
        XCTAssertLessThanOrEqual(tiny.bottom, 4)
    }

    func testRadiiNeverGoNegativeOrNaN() {
        for size in [CGSize.zero, CGSize(width: -5, height: -5), CGSize(width: 0, height: 30),
                     CGSize(width: 288, height: 0)] {
            let radii = NotchShape.clampedRadii(
                topEar: -3, bottomRadius: .nan, in: size
            )
            XCTAssertEqual(radii.ear, 0)
            XCTAssertEqual(radii.bottom, 0)
        }
    }

    func testCollapsedAndExpandedRadiiSurviveUnclamped() {
        let collapsed = NotchShape.clampedRadii(
            topEar: NotchGeometry.topEar, bottomRadius: NotchGeometry.collapsedBottomRadius,
            in: CGSize(width: 288, height: 30)
        )
        XCTAssertEqual(collapsed.ear, NotchGeometry.topEar)
        XCTAssertEqual(collapsed.bottom, NotchGeometry.collapsedBottomRadius)
        let expanded = NotchShape.clampedRadii(
            topEar: NotchGeometry.topEar, bottomRadius: NotchGeometry.expandedBottomRadius,
            in: CGSize(width: 300, height: 240)
        )
        XCTAssertEqual(expanded.ear, NotchGeometry.topEar)
        XCTAssertEqual(expanded.bottom, NotchGeometry.expandedBottomRadius)
    }

    func testPathStaysInsideTheRectAndIsFinite() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 240)
        for (ear, bottom) in [(CGFloat(6), CGFloat(10)), (6, 24), (0, 0), (50, 500), (6, 24)] {
            let bounds = NotchShape(topEar: ear, bottomRadius: bottom).path(in: rect).boundingRect
            XCTAssertTrue(bounds.minX.isFinite && bounds.maxY.isFinite)
            XCTAssertEqual(bounds.minX, rect.minX, accuracy: 0.001)
            XCTAssertEqual(bounds.maxX, rect.maxX, accuracy: 0.001)
            XCTAssertEqual(bounds.minY, rect.minY, accuracy: 0.001)
            XCTAssertEqual(bounds.maxY, rect.maxY, accuracy: 0.001)
        }
    }

    func testAnimatableDataRoundTripsBothRadii() {
        var shape = NotchShape(topEar: 6, bottomRadius: 10)
        shape.animatableData = AnimatablePair(4, 18)
        XCTAssertEqual(shape.topEar, 4)
        XCTAssertEqual(shape.bottomRadius, 18)
        XCTAssertEqual(shape.animatableData.first, 4)
        XCTAssertEqual(shape.animatableData.second, 18)
    }

    func testExpandedContentClearsTheBottomCorner() {
        // The content's bottom corner (inset from the left edge by contentInsetX, up by
        // contentBottomInset) must sit inside the bottom-corner arc, so rows never touch
        // the rounded corner.
        let radius = NotchGeometry.expandedBottomRadius
        let centerX = NotchGeometry.topEar + radius
        let dx = centerX - NotchGeometry.contentInsetX
        let dy = radius - NotchGeometry.contentBottomInset
        XCTAssertLessThan((dx * dx + dy * dy).squareRoot(), radius)
    }
}
