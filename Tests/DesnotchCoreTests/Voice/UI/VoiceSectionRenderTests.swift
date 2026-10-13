import AppKit
import SwiftUI
import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceSectionRenderTests: XCTestCase {
    /// Six lines of exactly 38 characters. 6 x 38 + 5 newlines = 233, still reviewable.
    private let worstCaseLiteral = Array(repeating: String(repeating: "x", count: 38), count: 6)
        .joined(separator: "\n")

    private var motion: NotchAnimation.Motion {
        NotchAnimation.resolve(style: .minimal, reduceMotion: true)
    }

    func testMeterWithNoLevelsDoesNotCrash() {
        let size = fittedSize(VoiceMeter(levels: [], motion: motion), width: 40)
        XCTAssertEqual(size.width, VoiceMeter.totalWidth, accuracy: 1)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertEqual(VoiceMeter.barCount, 5)
        XCTAssertEqual(VoiceMeter.minBarHeight, 3)
    }

    func testMeterWithOneLevelDoesNotCrash() {
        let size = fittedSize(VoiceMeter(levels: [0.5], motion: motion), width: 40)
        XCTAssertEqual(size.width, VoiceMeter.totalWidth, accuracy: 1)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testMeterIgnoresExtraLevels() {
        let size = fittedSize(VoiceMeter(levels: [1, 1, 1, 1, 1, 1, 1], motion: motion), width: 40)
        XCTAssertEqual(size.width, VoiceMeter.totalWidth, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, VoiceMeter.maxBarHeight + 1)
    }

    func testEveryNonIdleStateFitsItsHeightBudget() {
        let states = VoiceState.allCases.filter { $0 != .idle }
        XCTAssertEqual(states.count, 10)
        for state in states {
            let snapshot = snapshot(for: state)
            let presentation = VoiceSectionPresentation(snapshot, privacyMode: false, now: Date())
            let size = fittedSize(section(presentation, width: 268), width: 268)
            XCTAssertGreaterThan(size.width, 0, "\(state)")
            XCTAssertGreaterThan(size.height, 0, "\(state)")
            XCTAssertEqual(size.width, 268, accuracy: 1, "\(state)")
            XCTAssertLessThanOrEqual(size.height, presentation.heightBudget, "\(state)")
        }
    }

    func testReviewableLiteralsAreFullyLaidOutAndTheCardStaysWithinBudget() {
        XCTAssertEqual(worstCaseLiteral.count, 233)
        XCTAssertTrue(VoiceCardLayout.isLiteralReviewable(worstCaseLiteral))
        let fixtures = [
            String(repeating: "a", count: 240),
            "a\nb\nc\nd\ne\nf",
            worstCaseLiteral
        ]
        for literal in fixtures {
            XCTAssertTrue(VoiceCardLayout.isLiteralReviewable(literal), literal.count.description)
            for width in [CGFloat(268), CGFloat(228)] {
                let presentation = cardPresentation(literal: literal, source: .hermes)
                let approve = presentation.buttons.first { $0.role == .approveHold }
                XCTAssertEqual(approve?.isEnabled, true, "\(literal.count) @ \(width)")
                assertLiteralIsNotClipped(literal, width: width)
                let size = fittedSize(section(presentation, width: width), width: width)
                XCTAssertEqual(size.width, width, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, 300)
                XCTAssertLessThanOrEqual(size.height, presentation.heightBudget)
            }
        }
    }

    func testLiteralsPastTheCapDisableApproveAndStayWithinBudget() {
        let byLength = Array(repeating: String(repeating: "y", count: 40), count: 6).joined(separator: "\n")
        XCTAssertEqual(byLength.count, 245)
        XCTAssertFalse(VoiceCardLayout.isLiteralReviewable(byLength))
        let byLines = "a\nb\nc\nd\ne\nf\ng"
        XCTAssertFalse(VoiceCardLayout.isLiteralReviewable(byLines))
        for literal in [byLength, byLines] {
            for width in [CGFloat(268), CGFloat(228)] {
                let presentation = cardPresentation(literal: literal, source: .local)
                XCTAssertEqual(presentation.card?.note, "Too long to review here")
                XCTAssertEqual(presentation.buttons.first { $0.role == .approveClick }?.isEnabled, false)
                let size = fittedSize(section(presentation, width: width), width: width)
                XCTAssertEqual(size.width, width, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, VoiceCardLayout.approvalHeightBudget)
            }
        }
    }

    func testFiveFlagChipRowFitsTheApprovalBudgetAtTheMinimumWidth() {
        let presentation = cardPresentation(
            literal: "ls",
            source: .hermes,
            risk: [.destructive, .url, .pipe, .chaining, .redirect]
        )
        XCTAssertEqual(presentation.card?.riskWords, ["destructive", "redirect", "chained", "pipe"])
        XCTAssertEqual(presentation.card?.riskOverflow, 1)
        let size = fittedSize(section(presentation, width: 228), width: 228)
        XCTAssertEqual(size.width, 228, accuracy: 1)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThanOrEqual(size.height, 300)
    }

    func testCommitRefusesADisabledOrStaleNonce() {
        let box = Approvals()
        let actions = VoiceSectionActions(
            stop: {}, resume: {}, cancel: {},
            approve: { box.nonces.append($0) },
            deny: { _ in }
        )
        let disabled = VoiceButtonSpec(
            role: .approveHold, title: "Approve", glyph: nil, isEnabled: false, nonce: "card"
        )
        XCTAssertFalse(VoiceApproveButton.commit(spec: disabled, presentedNonce: "card", actions: actions))
        let missing = VoiceButtonSpec(
            role: .approveHold, title: "Approve", glyph: nil, isEnabled: true, nonce: nil
        )
        XCTAssertFalse(VoiceApproveButton.commit(spec: missing, presentedNonce: "card", actions: actions))
        let mismatch = VoiceButtonSpec(
            role: .approveClick, title: "Approve", glyph: nil, isEnabled: true, nonce: "card"
        )
        XCTAssertFalse(VoiceApproveButton.commit(spec: mismatch, presentedNonce: "other", actions: actions))
        XCTAssertTrue(box.nonces.isEmpty)
        let ready = VoiceButtonSpec(
            role: .approveHold, title: "Approve", glyph: nil, isEnabled: true, nonce: "card"
        )
        XCTAssertTrue(VoiceApproveButton.commit(spec: ready, presentedNonce: "card", actions: actions))
        XCTAssertEqual(box.nonces, ["card"])
        XCTAssertFalse(VoiceApproveButton.commit(spec: ready, presentedNonce: "card-2", actions: actions))
        XCTAssertEqual(box.nonces, ["card"])
    }

    func testDisabledApproveButtonStylingAndAccessibilityLabel() {
        let disabledSpec = VoiceButtonSpec(
            role: .approveHold, title: "Approve", glyph: nil, isEnabled: false, nonce: "card"
        )
        XCTAssertEqual(VoiceApproveButton.disabledOpacity, 0.45)
        XCTAssertEqual(
            VoiceApproveButton.disabledAccessibilityLabel(spec: disabledSpec, note: "Can't approve this from voice"),
            "Approve, Can't approve this from voice"
        )
        XCTAssertEqual(
            VoiceApproveButton.disabledAccessibilityLabel(spec: disabledSpec, note: "Too long to review here"),
            "Approve, Too long to review here"
        )
        XCTAssertEqual(
            VoiceApproveButton.disabledAccessibilityLabel(spec: disabledSpec, note: "Turn off Privacy mode to review"),
            "Approve, Turn off Privacy mode to review"
        )
        XCTAssertEqual(
            VoiceApproveButton.disabledAccessibilityLabel(spec: disabledSpec, note: nil),
            "Approve, cannot be used"
        )
    }

    func testDisabledApproveCardRendersWithinHeightBudget() {
        let request = ConfirmationRequest(
            nonce: "disabled-nonce",
            tier: .t3,
            source: .hermes,
            summary: "Run command",
            literal: "curl https://example.com"
        )
        let presentation = VoiceSectionPresentation(
            VoiceSectionSnapshot(state: .awaitingApproval, pending: request),
            privacyMode: false,
            now: Date()
        )
        XCTAssertEqual(presentation.card?.note, "Can't approve this from voice")
        XCTAssertEqual(presentation.buttons.first { $0.role == .approveHold }?.isEnabled, false)
        let size = fittedSize(section(presentation, width: 268), width: 268)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThanOrEqual(size.height, presentation.heightBudget)
    }

    private func assertLiteralIsNotClipped(_ literal: String, width: CGFloat) {
        let block = VoiceLiteralBlock(text: literal).frame(width: width)
        let size = fittedSize(block, width: width)
        let textWidth = width - 2 * VoiceLiteralBlock.horizontalPadding
        let bounds = NSAttributedString(
            string: literal,
            attributes: [.font: VoiceCardLayout.literalNSFont]
        ).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let minimum = bounds.height + 2 * VoiceLiteralBlock.verticalPadding
        XCTAssertGreaterThanOrEqual(size.height, minimum, "literal height at \(width)")
    }

    private func cardPresentation(
        literal: String, source: VoiceLane, risk: RiskFlags = []
    ) -> VoiceSectionPresentation {
        let request = ConfirmationRequest(
            nonce: "render-nonce",
            tier: .t2,
            source: source,
            summary: source == .local ? literal : "Run the command",
            literal: literal,
            risk: risk
        )
        return VoiceSectionPresentation(
            VoiceSectionSnapshot(state: .awaitingApproval, pending: request),
            privacyMode: false,
            now: Date()
        )
    }

    private func snapshot(for state: VoiceState) -> VoiceSectionSnapshot {
        switch state {
        case .listening:
            return VoiceSectionSnapshot(state: state, partialTranscript: "open maps")
        case .review:
            return VoiceSectionSnapshot(
                state: state,
                finalTranscript: "volume thirty",
                reviewDeadline: Date().addingTimeInterval(1.5),
                routeSummary: "Set volume to 30%"
            )
        case .acting:
            return VoiceSectionSnapshot(
                state: state,
                steps: [VoiceStep(id: 1, kind: "read")],
                stepsStarted: 1,
                lane: .hermes
            )
        case .speaking:
            return VoiceSectionSnapshot(state: state, reply: "Volume is 30")
        case .error:
            return VoiceSectionSnapshot(state: state, errorText: "Timed out", errorSeverity: .warning)
        case .paused:
            return VoiceSectionSnapshot(state: state, survivors: ["alpha", "beta"])
        case .awaitingApproval:
            return VoiceSectionSnapshot(
                state: state,
                pending: ConfirmationRequest(
                    nonce: "n", tier: .t2, source: .local, summary: "Set volume to 90%", literal: "Set volume to 90%"
                )
            )
        default:
            return VoiceSectionSnapshot(state: state)
        }
    }

    private func section(_ presentation: VoiceSectionPresentation, width: CGFloat) -> some View {
        VoiceSectionView(
            presentation: presentation,
            levels: [0.2, 0.4, 0.8, 0.4, 0.2],
            width: width,
            motion: motion,
            contrast: .standard,
            reduceTransparency: false,
            actions: .none
        )
    }

    private func fittedSize<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 4)
        host.layoutSubtreeIfNeeded()
        drainMainQueue()
        return host.fittingSize
    }

    private final class Approvals {
        var nonces: [String] = []
    }
}
