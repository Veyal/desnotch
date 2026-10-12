import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceSectionPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testIdleHasAnEmptyPresentation() {
        let presentation = present(.init(state: .idle))
        XCTAssertEqual(presentation.title, "")
        XCTAssertTrue(presentation.bodyLines.isEmpty)
        XCTAssertTrue(presentation.chips.isEmpty)
        XCTAssertTrue(presentation.buttons.isEmpty)
        XCTAssertNil(presentation.wingLeft)
        XCTAssertEqual(presentation.wingRight, .none)
        XCTAssertEqual(presentation.tint, .neutral)
        XCTAssertEqual(presentation.heightBudget, 112)
        XCTAssertEqual(presentation.titleLineLimit, 1)
        XCTAssertFalse(presentation.showsCloudBadge)
        XCTAssertFalse(presentation.showsMeter)
        XCTAssertNil(presentation.countdown)
        XCTAssertNil(presentation.card)
        XCTAssertEqual(presentation.accessibilityLabel, "")
    }

    func testArmedShowsStartingAndStop() {
        let presentation = present(.init(state: .armed))
        XCTAssertEqual(presentation.title, "Starting…")
        XCTAssertEqual(presentation.buttons.map(\.role), [.stop])
        XCTAssertEqual(presentation.wingLeft, .mic)
        XCTAssertEqual(presentation.tint, .calm)
        XCTAssertEqual(presentation.wingRight, .none)
    }

    func testListeningShowsPartialAndMeter() {
        let presentation = present(.init(state: .listening, partialTranscript: "open maps"))
        XCTAssertEqual(presentation.title, "open maps")
        XCTAssertEqual(presentation.titleLineLimit, 2)
        XCTAssertEqual(presentation.bodyLines, [
            VoiceBodyLine(text: "Esc cancels", lineLimit: 1, emphasis: .caption)
        ])
        XCTAssertTrue(presentation.showsMeter)
        XCTAssertEqual(presentation.buttons.map(\.role), [.stop])
        XCTAssertEqual(presentation.wingLeft, .mic)
        XCTAssertEqual(presentation.wingRight, .meter)
        XCTAssertEqual(presentation.tint, .neutral)
    }

    func testListeningWithEmptyPartialSaysListening() {
        let presentation = present(.init(state: .listening))
        XCTAssertEqual(presentation.title, "Listening…")
        XCTAssertTrue(presentation.showsMeter)
        XCTAssertEqual(presentation.buttons.map(\.role), [.stop])
    }

    func testTranscribingShowsEllipsisAndStop() {
        let presentation = present(.init(state: .transcribing))
        XCTAssertEqual(presentation.title, "Transcribing…")
        XCTAssertEqual(presentation.wingLeft, .ellipsis)
        XCTAssertEqual(presentation.tint, .calm)
        XCTAssertEqual(presentation.buttons.map(\.role), [.stop])
    }

    func testReviewShowsHeardAndRouteSummary() {
        let presentation = present(.init(
            state: .review,
            finalTranscript: "volume thirty",
            reviewDeadline: now.addingTimeInterval(1.5),
            routeSummary: "Set volume to 30%"
        ))
        XCTAssertEqual(presentation.title, "Heard: volume thirty")
        XCTAssertEqual(presentation.titleLineLimit, 2)
        XCTAssertEqual(presentation.bodyLines, [
            VoiceBodyLine(text: "Set volume to 30%", lineLimit: 1, emphasis: .secondary)
        ])
        XCTAssertNotNil(presentation.countdown)
        XCTAssertEqual(presentation.countdown?.total, VoiceTiming.reviewWindow)
        XCTAssertEqual(presentation.buttons.map(\.role), [.cancel, .stop])
        XCTAssertEqual(presentation.wingLeft, .checkmark)
    }

    func testReviewShowsRouteSummaryVerbatim() {
        let presentation = present(.init(
            state: .review,
            finalTranscript: "ask hermes",
            routeSummary: "Send to Hermes (cloud)",
            lane: .hermes
        ))
        XCTAssertEqual(presentation.bodyLines.map(\.text), ["Send to Hermes (cloud)"])
        XCTAssertFalse(presentation.bodyLines.contains { $0.text.contains("sending") })
    }

    func testThinkingTitleAndStop() {
        let presentation = present(.init(state: .thinking))
        XCTAssertEqual(presentation.title, "Thinking…")
        XCTAssertEqual(presentation.wingLeft, .ellipsis)
        XCTAssertEqual(presentation.buttons.map(\.role), [.stop])
        XCTAssertTrue(presentation.chips.isEmpty)
    }

    func testActingAgentWithZeroStepsSaysWorking() {
        let presentation = present(.init(state: .acting, lane: .hermes))
        XCTAssertEqual(presentation.title, "Working…")
        XCTAssertTrue(presentation.chips.isEmpty)
        XCTAssertEqual(presentation.wingLeft, .gear)
        XCTAssertEqual(presentation.buttons.map(\.role), [.stop])
        XCTAssertEqual(presentation.tint, .neutral)
    }

    func testActingLocalShowsRouteSummary() {
        let presentation = present(.init(
            state: .acting, routeSummary: "Set volume to 30%", lane: .local
        ))
        XCTAssertEqual(presentation.title, "Set volume to 30%")
        XCTAssertTrue(presentation.chips.isEmpty)
        XCTAssertFalse(presentation.showsCloudBadge)
    }

    func testActingWithNilLaneIsTreatedAsHermes() {
        let presentation = present(.init(
            state: .acting,
            steps: [VoiceStep(id: 1, kind: "read")],
            stepsStarted: 1
        ))
        XCTAssertEqual(presentation.title, "Working…")
        XCTAssertEqual(presentation.chips.map(\.text), ["read"])
        XCTAssertEqual(presentation.chips.map(\.glyph), [nil])
    }

    func testActingHermesChipsKeepOrderAndOverflow() {
        let steps = (1...5).map { VoiceStep(id: $0, kind: "step\($0)") }
        let presentation = present(.init(state: .acting, steps: steps, stepsStarted: 5, lane: .hermes))
        XCTAssertEqual(presentation.chips.map(\.text), ["step3", "step4", "step5", "+2"])
    }

    func testAwaitingApprovalWithoutAPendingRequestOffersOnlyStop() {
        let presentation = present(.init(state: .awaitingApproval))
        XCTAssertNil(presentation.card)
        XCTAssertEqual(presentation.buttons.map(\.role), [.stop])
        XCTAssertEqual(presentation.wingRight, .amberDot)
        XCTAssertEqual(presentation.tint, .amber)
        XCTAssertEqual(presentation.title, "Needs approval")
        XCTAssertEqual(presentation.heightBudget, 300)
    }

    func testSpeakingShowsTheReplyOrDone() {
        let spoken = present(.init(state: .speaking, reply: "Volume is 30"))
        XCTAssertEqual(spoken.title, "Volume is 30")
        XCTAssertEqual(spoken.titleLineLimit, 3)
        XCTAssertEqual(spoken.wingLeft, .speaker)
        let done = present(.init(state: .speaking))
        XCTAssertEqual(done.title, "Done")
    }

    func testErrorWithNilTextUsesTheGenericFallback() {
        let presentation = present(.init(state: .error))
        XCTAssertEqual(presentation.title, "Something went wrong")
        XCTAssertEqual(presentation.titleLineLimit, 2)
        XCTAssertEqual(presentation.wingLeft, .warning)
        XCTAssertEqual(presentation.buttons.map(\.role), [.stop])
    }

    func testErrorSeverityStyling() {
        XCTAssertEqual(present(.init(state: .error, errorSeverity: .info)).tint, .calm)
        XCTAssertEqual(present(.init(state: .error, errorText: "Timed out", errorSeverity: .warning)).tint, .amber)
        XCTAssertEqual(present(.init(state: .error, errorSeverity: .alert)).tint, .red)
        XCTAssertEqual(present(.init(state: .error, errorText: "Timed out")).title, "Timed out")
    }

    func testPausedAfterTripwireShowsTheTripwireText() {
        let presentation = present(.init(
            state: .paused, errorText: "Agent stopped: unapproved tool", errorSeverity: .alert
        ))
        XCTAssertEqual(presentation.title, "Agent stopped: unapproved tool")
        XCTAssertEqual(presentation.tint, .red)
        XCTAssertEqual(presentation.wingLeft, .pause)
    }

    func testPausedAfterUserStopShowsAgentStopped() {
        let presentation = present(.init(state: .paused))
        XCTAssertEqual(presentation.title, "Agent stopped")
        XCTAssertTrue(presentation.bodyLines.isEmpty)
    }

    func testPausedShowsSurvivorsAndResume() {
        let presentation = present(.init(state: .paused, survivors: ["alpha", "beta"]))
        XCTAssertEqual(presentation.bodyLines, [
            VoiceBodyLine(text: "2 still running: alpha, beta", lineLimit: 2, emphasis: .caption)
        ])
        XCTAssertEqual(presentation.buttons.map(\.role), [.resume])
        XCTAssertEqual(presentation.buttons.map(\.title), ["Resume"])
    }

    func testPausedSurvivorsAreCappedAtThreeNames() {
        let presentation = present(.init(state: .paused, survivors: ["a", "b", "c", "d", "e"]))
        XCTAssertEqual(presentation.bodyLines.map(\.text), ["5 still running: a, b, c, +2"])
    }

    func testPausedHasNoStopButtonAndListeningHasNoCancelButton() {
        let paused = present(.init(state: .paused))
        XCTAssertFalse(paused.buttons.contains { $0.role == .stop })
        XCTAssertEqual(paused.buttons.map(\.role), [.resume])
        let listening = present(.init(state: .listening, partialTranscript: "hello"))
        XCTAssertFalse(listening.buttons.contains { $0.role == .cancel })
        XCTAssertEqual(listening.buttons.map(\.role), [.stop])
    }

    func testTitleLineLimitPerState() {
        for state in VoiceState.allCases {
            let limit = present(.init(state: state)).titleLineLimit
            switch state {
            case .listening, .review, .error:
                XCTAssertEqual(limit, 2, "\(state)")
            case .speaking:
                XCTAssertEqual(limit, 3, "\(state)")
            default:
                XCTAssertEqual(limit, 1, "\(state)")
            }
        }
    }

    func testWingGlyphMatchesThePresentationForEveryState() {
        XCTAssertEqual(VoiceState.allCases.count, 11)
        for state in VoiceState.allCases {
            let presentation = present(.init(state: state))
            XCTAssertEqual(VoiceGlyph.wing(for: state), presentation.wingLeft, "\(state)")
        }
    }

    func testCloudBadgeWhenLaneIsHermes() {
        let fromLane = present(.init(state: .thinking, lane: .hermes, usesCloud: false))
        XCTAssertTrue(fromLane.showsCloudBadge)
        let fromFlag = present(.init(state: .thinking, usesCloud: true))
        XCTAssertTrue(fromFlag.showsCloudBadge)
        let local = present(.init(state: .acting, lane: .local))
        XCTAssertFalse(local.showsCloudBadge)
    }

    func testInterruptListeningAddsTheAbortLineAndMeter() {
        let thinking = present(.init(state: .thinking, lane: .hermes, interruptListening: true))
        XCTAssertEqual(thinking.bodyLines.map(\.text), ["Say “abort agent” to stop"])
        XCTAssertEqual(thinking.bodyLines.map(\.emphasis), [.caption])
        XCTAssertTrue(thinking.showsMeter)
        XCTAssertEqual(thinking.title, "Thinking…")
        let acting = present(.init(state: .acting, lane: .hermes, interruptListening: true))
        XCTAssertTrue(acting.bodyLines.contains { $0.text == "Say “abort agent” to stop" })
        XCTAssertTrue(acting.showsMeter)
    }

    func testAbortLineAndMeterAreNotAddedOnTheApprovalCard() {
        let presentation = present(.init(
            state: .awaitingApproval,
            pending: card(source: .hermes, summary: "Run ls", literal: "ls"),
            interruptListening: true
        ))
        XCTAssertFalse(presentation.showsMeter)
        XCTAssertFalse(presentation.bodyLines.contains { $0.text.contains("abort agent") })
        XCTAssertNotNil(presentation.card)
    }

    func testPrivacyModeReviewTitleKeepsHeardAndRedactsTheTranscript() {
        let presentation = present(
            .init(state: .review, finalTranscript: "SECRET-FINAL"),
            privacyMode: true
        )
        XCTAssertEqual(presentation.title, "Heard: Voice command")
    }

    func testAccessibilityLabelJoinFormat() {
        let approval = present(.init(
            state: .awaitingApproval,
            pending: card(source: .hermes, summary: "ignored", literal: "ls", risk: .destructive)
        ))
        XCTAssertEqual(approval.accessibilityLabel, "Voice: needs approval, T2, destructive")

        let confirming = present(.init(
            state: .review, finalTranscript: "volume thirty", routeSummary: "Set volume to 30%"
        ))
        XCTAssertEqual(confirming.accessibilityLabel, "Voice: confirming, Set volume to 30%")

        let thinking = present(.init(state: .thinking, lane: .hermes))
        XCTAssertEqual(thinking.accessibilityLabel, "Voice: thinking, sent to the Hermes cloud agent")

        let remoteReview = present(.init(
            state: .review,
            finalTranscript: "ask",
            routeSummary: "Send to Hermes (cloud)",
            lane: .hermes
        ))
        XCTAssertEqual(
            remoteReview.accessibilityLabel,
            "Voice: confirming, goes to the Hermes cloud agent, Send to Hermes (cloud)"
        )

        let stopped = present(.init(
            state: .paused,
            errorText: "Agent stopped: unapproved tool",
            survivors: ["one", "two"]
        ))
        XCTAssertEqual(
            stopped.accessibilityLabel,
            "Voice: stopped, Agent stopped: unapproved tool, 2 still running"
        )
    }

    func testSnapshotMemberwiseInitIsAvailable() {
        let snapshot = VoiceSectionSnapshot(state: .review, finalTranscript: "x")
        XCTAssertEqual(snapshot.state, .review)
        XCTAssertEqual(snapshot.finalTranscript, "x")
        XCTAssertEqual(snapshot.partialTranscript, "")
        XCTAssertEqual(snapshot.reply, "")
        XCTAssertNil(snapshot.pending)
        XCTAssertEqual(snapshot.stepsStarted, 0)
    }

    func testLiteralLayoutSemantics() {
        XCTAssertTrue(VoiceCardLayout.isLiteralReviewable("ls -la"))
        XCTAssertEqual(VoiceCardLayout.displayedLiteral("ls -la"), "ls -la")

        let long = String(repeating: "a", count: 241)
        XCTAssertFalse(VoiceCardLayout.isLiteralReviewable(long))
        XCTAssertEqual(VoiceCardLayout.displayedLiteral(long), String(repeating: "a", count: 240) + "…")

        let crlf = "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng"
        XCTAssertEqual(VoiceCardLayout.lines(of: crlf).count, 13)
        XCTAssertFalse(VoiceCardLayout.isLiteralReviewable(crlf))
        XCTAssertEqual(VoiceCardLayout.displayedLiteral(crlf), "a\n\nb\n\nc\n…")

        let six = "a\nb\nc\nd\ne\nf"
        XCTAssertEqual(VoiceCardLayout.lines(of: six).count, 6)
        XCTAssertTrue(VoiceCardLayout.isLiteralReviewable(six))
        XCTAssertEqual(VoiceCardLayout.displayedLiteral(six), six)

        let seven = "a\nb\nc\nd\ne\nf\ng"
        XCTAssertEqual(seven.count, 13)
        XCTAssertFalse(VoiceCardLayout.isLiteralReviewable(seven))
        XCTAssertEqual(VoiceCardLayout.displayedLiteral(seven), "a\nb\nc\nd\ne\nf…")

        XCTAssertTrue(VoiceCardLayout.isLiteralReviewable(""))
        XCTAssertEqual(VoiceCardLayout.lines(of: "").count, 1)
        XCTAssertEqual(VoiceCardLayout.displayedLiteral(""), "")

        let wideLine = String(repeating: "x", count: 50)
        let wide = Array(repeating: wideLine, count: 6).joined(separator: "\n")
        XCTAssertEqual(wide.count, 305)
        XCTAssertFalse(VoiceCardLayout.isLiteralReviewable(wide))
        let shown = VoiceCardLayout.displayedLiteral(wide)
        XCTAssertEqual(shown, String(wide.prefix(240)) + "…")
        XCTAssertLessThanOrEqual(shown.count, 241)
        XCTAssertLessThanOrEqual(VoiceCardLayout.lines(of: String(shown.dropLast())).count, 6)
    }

    func testAwaitingApprovalCardDisablesApproveWhenLiteralTooLong() throws {
        let literal = String(repeating: "a", count: 241)
        let presentation = present(.init(
            state: .awaitingApproval,
            pending: card(source: .local, summary: "Run", literal: literal)
        ))
        let approve = try button(.approveClick, presentation)
        XCTAssertFalse(approve.isEnabled)
        XCTAssertEqual(presentation.card?.note, "Too long to review here")
        XCTAssertEqual(presentation.card?.isLiteralComplete, false)
        XCTAssertTrue(presentation.card?.literal.hasSuffix("…") == true)
        XCTAssertTrue(try button(.deny, presentation).isEnabled)
        XCTAssertTrue(try button(.stop, presentation).isEnabled)
    }

    func testApproveDisabledWhenLiteralHasMoreThanSixLines() throws {
        let presentation = present(.init(
            state: .awaitingApproval,
            pending: card(source: .hermes, summary: "Run", literal: "a\nb\nc\nd\ne\nf\ng")
        ))
        XCTAssertFalse(try button(.approveHold, presentation).isEnabled)
        XCTAssertEqual(presentation.card?.note, "Too long to review here")
        XCTAssertEqual(presentation.card?.isLiteralComplete, false)
    }

    func testHermesCardRequiresHold() throws {
        let presentation = present(
            .init(state: .awaitingApproval, pending: card(source: .hermes, summary: "Run ls", literal: "ls")),
            privacyMode: false
        )
        let approve = try button(.approveHold, presentation)
        XCTAssertTrue(approve.isEnabled)
        XCTAssertEqual(presentation.card?.requiresHold, true)
        XCTAssertEqual(presentation.card?.hint, "Hold Approve to confirm")
        XCTAssertEqual(presentation.buttons.map(\.role), [.deny, .approveHold, .stop])
    }

    func testPrivacyModeDisablesApproveOnAnAgentCard() throws {
        let request = card(source: .hermes, summary: "Run ls", literal: "ls -la", nonce: "agent-nonce")
        let hidden = present(.init(state: .awaitingApproval, pending: request), privacyMode: true)
        let approve = try button(.approveHold, hidden)
        XCTAssertFalse(approve.isEnabled)
        XCTAssertEqual(hidden.card?.note, "Turn off Privacy mode to review")
        XCTAssertNil(hidden.card?.hint)
        let deny = try button(.deny, hidden)
        let stop = try button(.stop, hidden)
        XCTAssertTrue(deny.isEnabled)
        XCTAssertTrue(stop.isEnabled)
        XCTAssertEqual(deny.nonce, "agent-nonce")
        XCTAssertNil(stop.nonce)
        let shown = present(.init(state: .awaitingApproval, pending: request), privacyMode: false)
        XCTAssertTrue(try button(.approveHold, shown).isEnabled)
        XCTAssertEqual(shown.card?.hint, "Hold Approve to confirm")
        let local = present(
            .init(
                state: .awaitingApproval,
                pending: card(source: .local, summary: "Set volume to 90%", literal: "Set volume to 90%", nonce: "local-nonce")
            ),
            privacyMode: true
        )
        XCTAssertTrue(try button(.approveClick, local).isEnabled)
        XCTAssertEqual(local.card?.summary, "Set volume to 90%")
    }

    func testLocalCardApprovesWithClick() throws {
        let presentation = present(.init(
            state: .awaitingApproval,
            pending: card(source: .local, summary: "Set volume to 90%", literal: "Set volume to 90%")
        ))
        XCTAssertEqual(presentation.buttons.map(\.role), [.deny, .approveClick, .stop])
        XCTAssertTrue(try button(.approveClick, presentation).isEnabled)
        XCTAssertNil(presentation.card?.hint)
        XCTAssertEqual(presentation.card?.requiresHold, false)
        XCTAssertEqual(presentation.card?.summary, presentation.card?.literal)
    }

    func testTruncatedRequestCannotBeApproved() throws {
        let presentation = present(.init(
            state: .awaitingApproval,
            pending: card(source: .local, summary: "Run", literal: "ls", isTruncated: true)
        ))
        XCTAssertFalse(try button(.approveClick, presentation).isEnabled)
        XCTAssertEqual(presentation.card?.note, "Too long to review here")
    }

    func testTier3RequestCannotBeApproved() throws {
        let presentation = present(.init(
            state: .awaitingApproval,
            pending: card(source: .hermes, summary: "Fetch", literal: "curl", tier: .t3)
        ))
        XCTAssertFalse(try button(.approveHold, presentation).isEnabled)
        XCTAssertFalse(presentation.card?.literal.isEmpty == true)
    }

    func testButtonsCarryTheNonceOfTheCardOnScreen() throws {
        let presentation = present(.init(
            state: .awaitingApproval,
            pending: card(source: .hermes, summary: "Run", literal: "ls", nonce: "card-nonce")
        ))
        XCTAssertEqual(try button(.deny, presentation).nonce, "card-nonce")
        XCTAssertEqual(try button(.approveHold, presentation).nonce, "card-nonce")
        XCTAssertNil(try button(.stop, presentation).nonce)
        XCTAssertEqual(presentation.card?.nonce, "card-nonce")
    }

    func testRiskWordsOrderAndCap() {
        let five = VoiceRiskWords.words(for: [.destructive, .url, .pipe, .chaining, .redirect])
        XCTAssertEqual(five.words, ["destructive", "redirect", "chained", "pipe"])
        XCTAssertEqual(five.overflow, 1)
        let pipeAndURL = VoiceRiskWords.words(for: [.url, .pipe])
        XCTAssertEqual(pipeAndURL.words, ["pipe", "network"])
        XCTAssertEqual(pipeAndURL.overflow, 0)
        let chained = VoiceRiskWords.words(for: [.chaining, .destructive])
        XCTAssertEqual(chained.words, ["destructive", "chained"])
        let none = VoiceRiskWords.words(for: [])
        XCTAssertEqual(none.words, [])
        XCTAssertEqual(none.overflow, 0)
        let expected: [(RiskFlags, String)] = [
            (.destructive, "destructive"),
            (.sudo, "sudo"),
            (.protectedPath, "protected path"),
            (.pipeToInterpreter, "pipe to shell"),
            (.base64Decode, "base64"),
            (.evalUse, "eval"),
            (.commandSubstitution, "substitution"),
            (.hiddenCharacters, "hidden characters"),
            (.unscanned, "unscanned"),
            (.redirect, "redirect"),
            (.chaining, "chained"),
            (.pipe, "pipe"),
            (.url, "network")
        ]
        for pair in expected {
            XCTAssertEqual(VoiceRiskWords.word(for: pair.0), pair.1)
        }
    }

    func testCountdownRemainingFraction() {
        let deadline = Date(timeIntervalSince1970: 100)
        let countdown = VoiceCountdown(deadline: deadline, total: VoiceTiming.reviewWindow)
        XCTAssertEqual(countdown.remainingFraction(now: deadline), 0)
        XCTAssertEqual(countdown.remainingFraction(now: deadline.addingTimeInterval(-1.5)), 1)
        XCTAssertEqual(countdown.remainingFraction(now: deadline.addingTimeInterval(-0.75)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(countdown.remainingFraction(now: deadline.addingTimeInterval(4)), 0)
        XCTAssertEqual(countdown.remainingFraction(now: deadline.addingTimeInterval(-9)), 1)
        let thinking = present(.init(state: .thinking, reviewDeadline: deadline))
        XCTAssertNil(thinking.countdown)
        let review = present(.init(state: .review, reviewDeadline: deadline))
        XCTAssertEqual(review.countdown?.deadline, deadline)
        XCTAssertEqual(review.countdown?.total, VoiceTiming.reviewWindow)
    }

    func testPrivacyModeRedactsTranscriptReplyAndLiteral() {
        let secretPartial = "SECRET-PARTIAL"
        let secretFinal = "SECRET-FINAL"
        let secretReply = "SECRET-REPLY"
        let secretSummary = "SECRET-SUMMARY"
        let secretLiteral = "SECRET-LITERAL"
        let secretProcess = "SECRET-PROCESS"
        let secrets = [secretPartial, secretFinal, secretReply, secretSummary, secretLiteral, secretProcess]
        let listening = present(.init(state: .listening, partialTranscript: secretPartial), privacyMode: true)
        let review = present(.init(state: .review, finalTranscript: secretFinal), privacyMode: true)
        let speaking = present(.init(state: .speaking, reply: secretReply), privacyMode: true)
        let agent = present(
            .init(
                state: .awaitingApproval,
                pending: card(source: .hermes, summary: secretSummary, literal: secretLiteral),
                survivors: [secretProcess]
            ),
            privacyMode: true
        )
        let paused = present(.init(state: .paused, survivors: [secretProcess]), privacyMode: true)
        for presentation in [listening, review, speaking, agent, paused] {
            let blob = joinedText(presentation)
            for secret in secrets {
                XCTAssertFalse(blob.contains(secret), secret)
            }
        }
        XCTAssertEqual(agent.card?.summary, "Agent action")
        XCTAssertEqual(agent.card?.literal, "Command")
        XCTAssertEqual(paused.bodyLines.map(\.text), ["1 still running: process"])
        let local = present(
            .init(
                state: .awaitingApproval,
                pending: card(source: .local, summary: "Set volume to 30%", literal: "Set volume to 30%")
            ),
            privacyMode: true
        )
        XCTAssertEqual(local.card?.summary, "Set volume to 30%")
        XCTAssertFalse(joinedText(local).contains(secretSummary))
    }

    func testNoPresentationOffersASpokenApproval() {
        let banned = ["say yes", "say \"yes\"", "always allow", "allow for session", "allow always"]
        for state in VoiceState.allCases {
            let presentation = present(.init(
                state: state,
                pending: card(source: .hermes, summary: "Run ls", literal: "ls"),
                routeSummary: "Set volume to 30%"
            ))
            let blob = joinedText(presentation).lowercased()
            for phrase in banned {
                XCTAssertFalse(blob.contains(phrase), "\(state) \(phrase)")
            }
        }
    }

    func testAccessibilityLabelNeverContainsLiveContent() {
        let secrets = ["SECRET-PARTIAL", "SECRET-FINAL", "SECRET-REPLY", "SECRET-SUMMARY", "SECRET-LITERAL", "SECRET-PROCESS"]
        for privacy in [false, true] {
            let snapshots = [
                VoiceSectionSnapshot(state: .listening, partialTranscript: secrets[0]),
                VoiceSectionSnapshot(state: .review, finalTranscript: secrets[1], routeSummary: "Set volume to 30%"),
                VoiceSectionSnapshot(state: .speaking, reply: secrets[2]),
                VoiceSectionSnapshot(
                    state: .awaitingApproval,
                    pending: card(source: .hermes, summary: secrets[3], literal: secrets[4], risk: .destructive),
                    survivors: [secrets[5]]
                ),
                VoiceSectionSnapshot(state: .paused, errorText: "Agent stopped: unapproved tool", survivors: [secrets[5]])
            ]
            for snapshot in snapshots {
                let label = present(snapshot, privacyMode: privacy).accessibilityLabel
                for secret in secrets {
                    XCTAssertFalse(label.contains(secret), label)
                }
            }
        }
    }

    func testSettingsWordsCoverEveryPreflightFailure() {
        let expected: [PreflightFailure: String] = [
            .binaryMissing: "Hermes not found",
            .profileMissing: "no voice profile",
            .approvalsOff: "approvals off",
            .allowlistNotEmpty: "allowlist not empty",
            .toolsetOutsideAllowlist: "toolsets not empty",
            .configNotLocked: "profile not locked",
            .mcpConfigured: "MCP configured",
            .protocolMismatch: "protocol mismatch",
            .notImplemented: "not available"
        ]
        XCTAssertEqual(Set(PreflightFailure.allCases), Set(expected.keys))
        for failure in PreflightFailure.allCases {
            let word = VoiceSettingsWords.preflightWord(failure)
            XCTAssertEqual(word, expected[failure])
            XCTAssertEqual(VoiceSettingsWords.laneStatusText(.refused(failure)), "Refused: \(word)")
        }
    }

    func testPermissionLocaleAndLaneTables() {
        XCTAssertEqual(VoiceSettingsWords.permissionText(.authorized), "Allowed")
        XCTAssertEqual(VoiceSettingsWords.permissionText(.notDetermined), "Not asked yet")
        XCTAssertEqual(VoiceSettingsWords.permissionText(.denied), "Not allowed")
        XCTAssertEqual(VoiceSettingsWords.permissionText(.restricted), "Restricted by this Mac")
        XCTAssertEqual(VoiceSettingsWords.permissionText(.unknown), "Unknown")
        XCTAssertEqual(VoiceSettingsWords.localeLabel("en-US"), "English (US)")
        XCTAssertEqual(VoiceSettingsWords.localeLabel("id-ID"), "Bahasa Indonesia")
        XCTAssertEqual(VoiceSettingsWords.localeLabel("fr-FR"), "fr-FR")
        XCTAssertEqual(VoiceSettingsWords.laneStatusText(.off), "Off")
        XCTAssertEqual(VoiceSettingsWords.laneStatusText(.checking), "Checking…")
        XCTAssertEqual(VoiceSettingsWords.laneStatusText(.ready), "Ready")
    }

    func testShortcutShadowNoteText() {
        XCTAssertEqual(
            VoiceSettingsWords.shortcutShadowNote,
            "⌥⌘V also moves items in Finder; choose another shortcut if you use that."
        )
    }

    func testHotkeyLabelsUseTheAppleModifierOrder() {
        XCTAssertEqual(VoiceSettingsWords.hotkeyLabel(.optionCommandV), "⌥⌘V")
        XCTAssertEqual(VoiceSettingsWords.hotkeyLabel(.shiftOptionCommandV), "⌥⇧⌘V")
        XCTAssertEqual(VoiceSettingsWords.hotkeyLabel(.optionCommandJ), "⌥⌘J")
    }

    func testUpdateNoteNoLongerClaimsToBeTheOnlyNetworkRequest() {
        let note = VoiceSettingsWords.updateCheckNote
        XCTAssertTrue(note.contains("on its own"))
        XCTAssertTrue(note.contains("Hermes agent lane"))
        XCTAssertFalse(note.contains("That is the only network request"))
    }

    private func present(
        _ snapshot: VoiceSectionSnapshot, privacyMode: Bool = false
    ) -> VoiceSectionPresentation {
        VoiceSectionPresentation(snapshot, privacyMode: privacyMode, now: now)
    }

    private func card(
        source: VoiceLane,
        summary: String,
        literal: String,
        tier: VoiceTier = .t2,
        risk: RiskFlags = [],
        nonce: String = "nonce-1",
        isTruncated: Bool = false
    ) -> ConfirmationRequest {
        ConfirmationRequest(
            nonce: nonce,
            tier: tier,
            source: source,
            summary: summary,
            literal: literal,
            risk: risk,
            isTruncated: isTruncated
        )
    }

    private func button(
        _ role: VoiceButtonRole, _ presentation: VoiceSectionPresentation
    ) throws -> VoiceButtonSpec {
        try XCTUnwrap(presentation.buttons.first { $0.role == role })
    }

    private func joinedText(_ presentation: VoiceSectionPresentation) -> String {
        var parts = [presentation.title, presentation.accessibilityLabel]
        parts.append(contentsOf: presentation.bodyLines.map(\.text))
        parts.append(contentsOf: presentation.chips.map(\.text))
        parts.append(contentsOf: presentation.buttons.map(\.title))
        if let card = presentation.card {
            parts.append(contentsOf: [
                card.tierLabel, card.summary, card.literal, card.note ?? "", card.hint ?? "", card.nonce
            ])
            parts.append(contentsOf: card.riskWords)
        }
        return parts.joined(separator: "\n")
    }
}
