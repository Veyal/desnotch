import AppKit
import XCTest
@testable import DesnotchCore

/// Collapsed-wing sizing and the small fixes that keep wing content off the pill's edge:
/// wide indicators grow the wings symmetrically, the privacy dots get their own lane, the
/// agent count is capped, and trailing icon buttons align to the content edge.
final class WingMetricsTests: XCTestCase {
    private func extra(
        _ left: WingIndicator?, _ right: WingIndicator?,
        timerLabel: Bool = true, agentLength: Int = 1
    ) -> CGFloat {
        WingMetrics.extraWidth(
            left: left, right: right, timerShowsLabel: timerLabel, agentLabelLength: agentLength
        )
    }

    func testSingleGlyphIndicatorsNeedNoExtraWidth() {
        for indicator in [WingIndicator.media, .hotProcess, .calendar, .reminder, .notification, .volume] {
            XCTAssertEqual(extra(indicator, indicator), 0, "\(indicator) fits the base wing")
        }
        XCTAssertEqual(extra(nil, nil), 0)
        XCTAssertEqual(extra(.media, .timer, timerLabel: false), 0, "the ring alone fits")
    }

    func testTextWingsKeepTheSameEdgeInsetAsIconWings() {
        // A single 16-18pt glyph in the 44pt wing keeps >= 10pt on each side; the agent count
        // (even one digit) and the timer label must not sit closer to the shape's edge.
        for indicator in [WingIndicator.timer, .agent] {
            let content = WingMetrics.contentWidth(of: indicator, timerShowsLabel: true, agentLabelLength: 1)
            let wing = WingMetrics.baseWidth + extra(indicator, nil, timerLabel: true, agentLength: 1)
            let visible = wing - NotchGeometry.topEar
            XCTAssertGreaterThanOrEqual((visible - content) / 2, WingMetrics.textInset, "\(indicator)")
        }
        let media = WingMetrics.contentWidth(of: .media, timerShowsLabel: true, agentLabelLength: 1)
        XCTAssertGreaterThanOrEqual(
            (WingMetrics.baseWidth - NotchGeometry.topEar - media) / 2, WingMetrics.persistentInset,
            "the base wing is sized for the icon rhythm"
        )
        XCTAssertGreaterThan(extra(.media, .agent, agentLength: 1), 0, "a one-digit count grows the wing")
    }

    func testTimerLabelAndWideAgentCountsGrowTheWings() {
        let timer = extra(.timer, .agent)
        XCTAssertGreaterThan(timer, 0, "ring + '25m' does not fit 44pt with air on both sides")
        let twoDigits = extra(.media, .agent, agentLength: 2)
        XCTAssertGreaterThan(twoDigits, 0)
        XCTAssertGreaterThan(extra(.media, .agent, agentLength: 3), twoDigits)
        // The widest of the two wings decides, whichever side it is on.
        XCTAssertEqual(extra(.timer, nil), extra(nil, .timer))
        // After growing, the content keeps the minimum inset.
        let wing = WingMetrics.baseWidth + timer
        let visible = wing - NotchGeometry.topEar
        let content = WingMetrics.contentWidth(of: .timer, timerShowsLabel: true, agentLabelLength: 1)
        XCTAssertGreaterThanOrEqual((visible - content) / 2, WingMetrics.textInset)
    }

    /// The constants are rounded-up measurements of the real system font at the real sizes;
    /// if a font/size change makes the content wider than the budget, this fails.
    func testBudgetsCoverTheMeasuredFontWidths() {
        func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            return (text as NSString).size(withAttributes: [.font: font]).width
        }
        for label in ["59s", "50m", "25m", "15m", "5m"] {
            XCTAssertLessThanOrEqual(
                width(label, size: PillTextStyle.wingTimer.size, weight: .semibold),
                WingMetrics.timerLabelWidth, "timer label \(label)"
            )
        }
        for count in [1, 9, 12, 99, 120] {
            let text = PillCountLabel.text(count)
            XCTAssertLessThanOrEqual(
                width(text, size: PillTextStyle.wingCount.size, weight: .bold),
                WingMetrics.agentCharacterWidth * CGFloat(text.count) + 0.5, "agent count \(text)"
            )
        }
    }

    func testAgentCountLabelCapsAtNinetyNinePlus() {
        XCTAssertEqual(PillCountLabel.text(0), "0")
        XCTAssertEqual(PillCountLabel.text(9), "9")
        XCTAssertEqual(PillCountLabel.text(12), "12")
        XCTAssertEqual(PillCountLabel.text(99), "99")
        XCTAssertEqual(PillCountLabel.text(100), "99+")
        XCTAssertEqual(PillCountLabel.text(-3), "0")
    }

    func testPrivacyLaneClearsTheWingContentAndTheEar() {
        // The dot column sits `topEar + 4` from the pill's trailing edge and is 6-7pt wide;
        // the lane must reach past its leading edge plus a margin, else dots sit on a badge.
        let dotLeadingEdge = NotchGeometry.topEar + 4 + 7
        XCTAssertGreaterThanOrEqual(WingMetrics.privacyLane, dotLeadingEdge - NotchGeometry.topEar)
    }

    func testTrailingIconSlackMatchesTheGlyphInsideTheHitBox() {
        XCTAssertEqual(PillIconLabel.trailingSlack(side: 24, glyph: 12), 6)
        XCTAssertEqual(PillIconLabel.trailingSlack(side: 24, glyph: 11), 6.5)
        XCTAssertEqual(PillIconLabel.trailingSlack(side: 10, glyph: 12), 0, "never negative")
    }

    func testSeekTrackAndArtworkEdgeMeetNonTextContrast() {
        for increased in [false, true] {
            let level = CGFloat(PillPalette.seekTrackLevel(increasedContrast: increased))
            let contrast = PillPalette.contrastOnBlack(red: level, green: level, blue: level)
            XCTAssertGreaterThanOrEqual(contrast, 3, "unfilled seek track, increased=\(increased)")
        }
        XCTAssertGreaterThan(
            PillPalette.seekTrackLevel(increasedContrast: true),
            PillPalette.seekTrackLevel(increasedContrast: false)
        )
    }

    func testSpotlightCardStaysInsideTheBottomCorner() {
        // Content sits contentInsetX in from the frame and the ears take topEar of that, so the
        // visible side is `contentInsetX - topEar` from the content edge.
        let cardInsetFromSide = NotchGeometry.contentInsetX - NotchGeometry.topEar
            - SpotlightCard.horizontalBleed
        let cornerAtContentEdge = SpotlightCard.cornerInset(above: NotchGeometry.contentBottomInset)
        XCTAssertEqual(cornerAtContentEdge, 3.2, accuracy: 0.05)
        let lastBottom = NotchGeometry.contentBottomInset
            - SpotlightCard.bottomBleed(isLastInStack: true)
        XCTAssertGreaterThan(cardInsetFromSide, SpotlightCard.cornerInset(above: lastBottom) + 1,
                             "the last section's card bottom clears the pill corner")
        // The usual 4pt bleed would sit where the corner inset is larger.
        XCTAssertGreaterThan(SpotlightCard.cornerInset(above: NotchGeometry.contentBottomInset - 4),
                             SpotlightCard.cornerInset(above: lastBottom))
        XCTAssertEqual(SpotlightCard.bottomBleed(isLastInStack: true), SpotlightCard.lastSectionBottomBleed)
        XCTAssertEqual(SpotlightCard.bottomBleed(isLastInStack: false), SpotlightCard.verticalBleed)
    }
}
