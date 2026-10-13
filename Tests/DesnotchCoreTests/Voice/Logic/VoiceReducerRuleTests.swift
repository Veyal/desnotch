import XCTest
@testable import DesnotchCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func env(
    voiceEnabled: Bool = true, locked: Bool = false, hermes: Bool = false, turns: Int = 40,
    speech: Bool = false, secondFactor: Bool = false, nonce: String = "n1", now: Date = t0
) -> VoiceReducerEnv {
    VoiceReducerEnv(now: now, voiceEnabled: voiceEnabled, screenLocked: locked, hermesLaneReady: hermes,
                    hermesTurnsRemainingToday: turns, speechAllowed: speech,
                    secondFactorAvailable: secondFactor, freshNonce: nonce)
}

/// A context already in `state`, with generation 1 / counter 1 unless changed by `edit`.
private func ctx(_ state: VoiceState, _ edit: (inout VoiceContext) -> Void = { _ in }) -> VoiceContext {
    var c = VoiceContext()
    c.state = state
    c.counter = 1
    c.generation = 1
    edit(&c)
    return c
}

private func step(_ c: VoiceContext, _ e: VoiceEvent,
                  _ env: VoiceReducerEnv = env()) -> VoiceTransition {
    VoiceReducer.reduce(c, e, env: env)
}

private func timerEffect(_ effects: [VoiceEffect])
    -> (kind: VoiceTimerKind, generation: Int, seconds: Double)? {
    for effect in effects {
        if case .startTimer(let kind, let generation, let seconds) = effect {
            return (kind, generation, seconds)
        }
    }
    return nil
}

private func localCard(nonce: String = "n1", tier: VoiceTier = .t2) -> ConfirmationRequest {
    ConfirmationRequest(nonce: nonce, tier: tier, source: .local, summary: "Set volume to 90%",
                        literal: "Set volume to 90%")
}

private func agentCard(nonce: String = "c1", tier: VoiceTier = .t2,
                       risk: RiskFlags = []) -> ConfirmationRequest {
    ConfirmationRequest(nonce: nonce, tier: tier, source: .hermes, summary: "run", literal: "run",
                        risk: risk)
}

final class VoiceReducerRuleTests: XCTestCase {
    // MARK: Global

    func testR01_staleEventIsNoOp() {
        let c = ctx(.armed)
        let t = step(c, .captureStarted(generation: 99))
        XCTAssertEqual(t.context, c)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR02_featureDisabledStopsEverything() {
        let idle = ctx(.idle)
        let noOp = step(idle, .featureDisabled)
        XCTAssertEqual(noOp.context, idle)
        XCTAssertTrue(noOp.effects.isEmpty)

        let listening = ctx(.listening)
        let t = step(listening, .featureDisabled)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertNil(t.context.pauseReason)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 1),
                                   .audit(AuditDraft(kind: .stop, decision: "disabled",
                                                     outcome: "soft"))])

        let busy = ctx(.thinking) { $0.lane = .hermes }
        let hard = step(busy, .featureDisabled)
        XCTAssertEqual(hard.context.state, .idle)
        XCTAssertNil(hard.context.pauseReason)
        XCTAssertEqual(hard.effects, [.stopAgentHard,
                                      .audit(AuditDraft(kind: .stop, lane: .hermes,
                                                        decision: "disabled", outcome: "hard"))])
    }

    func testR03_pausedStopIsNoOp() {
        let c = ctx(.paused) { $0.pauseReason = .userStop }
        let t = step(c, .stopAllRequested)
        XCTAssertEqual(t.context, c)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR03a_idleStopAuditsIdle() {
        let c = ctx(.idle)
        let t = step(c, .stopAllRequested)
        XCTAssertEqual(t.context, c)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .stop, decision: "user_stop",
                                                     outcome: "idle"))])
    }

    func testR03b_busyStopStopsAll() {
        let c = ctx(.listening)
        let t = step(c, .stopAllRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 1),
                                   .audit(AuditDraft(kind: .stop, decision: "user_stop",
                                                     outcome: "soft"))])
    }

    func testR04_lockedCancel() {
        for state in [VoiceState.armed, .listening, .transcribing] {
            let t = step(ctx(state), .screenLocked)
            XCTAssertEqual(t.context.state, .idle, "\(state)")
            XCTAssertEqual(t.effects, [.cancelCapture(generation: 1),
                                       .audit(AuditDraft(kind: .cancel, decision: "locked"))],
                           "\(state)")
        }
        var review = ctx(.review)
        review.route = .local(.mute)
        review.lane = .local
        let t = step(review, .screenLocked)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .cancel, lane: .local,
                                                     decision: "locked"))])
    }

    func testR04a_lockedApprovalDenies() {
        let local = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let localResult = step(local, .screenLocked)
        XCTAssertEqual(localResult.context.state, .idle)
        XCTAssertEqual(localResult.effects, [.audit(AuditDraft(kind: .denial, lane: .local,
                                                               tier: .t2, decision: "locked"))])

        let agent = ctx(.awaitingApproval) {
            $0.pending = agentCard()
            $0.lane = .hermes
        }
        let agentResult = step(agent, .screenLocked)
        XCTAssertEqual(agentResult.context.state, .acting)
        XCTAssertEqual(agentResult.effects,
                       [.respondToApproval(nonce: "c1", allow: false),
                        .audit(AuditDraft(kind: .denial, lane: .hermes, tier: .t2,
                                          decision: "locked"))])
    }

    func testR04b_lockedBusyIsNoOp() {
        for state in [VoiceState.idle, .thinking, .acting, .speaking, .error, .paused] {
            let c = ctx(state)
            let t = step(c, .screenLocked)
            XCTAssertEqual(t.context, c, "\(state)")
            XCTAssertTrue(t.effects.isEmpty, "\(state)")
        }
    }

    // MARK: idle

    func testR10_talkPressedStartsAHoldCapture() {
        let t = step(VoiceContext(), .talkPressed)
        XCTAssertEqual(t.context.counter, 1)
        XCTAssertEqual(t.context.generation, 1)
        XCTAssertEqual(t.context.state, .armed)
        XCTAssertEqual(t.effects, [.startCapture(generation: 1, mode: .hold)])
    }

    func testR11_toggleTalkStartsAToggleCapture() {
        let t = step(VoiceContext(), .toggleTalk)
        XCTAssertEqual(t.context.state, .armed)
        XCTAssertEqual(t.context.captureMode, .toggle)
        XCTAssertEqual(t.effects, [.startCapture(generation: 1, mode: .toggle)])
    }

    func testR12_disabledTalkIsNoOp() {
        let c = ctx(.idle)
        let pressed = step(c, .talkPressed, env(voiceEnabled: false))
        XCTAssertEqual(pressed.context, c)
        XCTAssertTrue(pressed.effects.isEmpty)
        let toggle = step(c, .toggleTalk, env(voiceEnabled: false))
        XCTAssertEqual(toggle.context, c)
        XCTAssertTrue(toggle.effects.isEmpty)
    }

    func testR13_lockedTalkShowsLockedError() {
        let t = step(ctx(.idle), .talkPressed, env(locked: true))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .screenLocked)
        XCTAssertEqual(t.context.counter, 2)
        XCTAssertEqual(t.context.generation, 2)
        XCTAssertEqual(t.effects, [
            .audit(AuditDraft(kind: .lock, decision: "blocked")),
            .cue(.error),
            .startTimer(.errorDisplay, generation: 2, seconds: 3.0),
            .audit(AuditDraft(kind: .error, decision: "failure", outcome: "locked"))
        ])
    }

    func testR14_otherEventsAreNoOp() {
        let c = ctx(.idle)
        let events: [VoiceEvent] = [.talkReleased(heldSeconds: 0.5), .cancelRequested,
                                    .resumeRequested, .approveRequested(nonce: "x"),
                                    .denyRequested(nonce: "x"),
                                    .timerElapsed(.review, generation: 1)]
        for event in events {
            let t = step(c, event)
            XCTAssertEqual(t.context, c, "\(event)")
            XCTAssertTrue(t.effects.isEmpty, "\(event)")
        }
    }

    // MARK: armed

    func testR20_captureStartedMovesToListening() {
        var hold = ctx(.armed)
        hold.captureMode = .hold
        let holdResult = step(hold, .captureStarted(generation: 1))
        XCTAssertEqual(holdResult.context.state, .listening)
        XCTAssertEqual(holdResult.effects, [.cue(.captureStart),
                                            .startTimer(.listenCap, generation: 1, seconds: 30.0)])

        var toggle = ctx(.armed)
        toggle.captureMode = .toggle
        let toggleResult = step(toggle, .captureStarted(generation: 1))
        XCTAssertEqual(toggleResult.effects, [.cue(.captureStart),
                                              .startTimer(.listenCap, generation: 1, seconds: 10.0)])
    }

    func testR21_releasedEarlyCancels() {
        var c = ctx(.armed)
        c.captureMode = .hold
        let t = step(c, .talkReleased(heldSeconds: 0.35))
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 1),
                                   .audit(AuditDraft(kind: .cancel, decision: "released_early"))])
    }

    func testR22_tapLatchesToggle() {
        var c = ctx(.armed)
        c.captureMode = .hold
        let t = step(c, .talkReleased(heldSeconds: 0.1))
        XCTAssertEqual(t.context.state, .armed)
        XCTAssertEqual(t.context.captureMode, .toggle)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR23_captureFailed() {
        let t = step(ctx(.armed), .captureFailed(.unavailable(.recognizer), generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .unavailable(.recognizer))
        XCTAssertEqual(t.effects, [
            .cancelCapture(generation: 1),
            .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, decision: "failure",
                              outcome: "unavailable.recognizer"))
        ])
    }

    func testR24_cancel() {
        let t = step(ctx(.armed), .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 1),
                                   .audit(AuditDraft(kind: .cancel, decision: "cancel"))])
    }

    // MARK: listening

    func testR30_partialTranscriptIsBounded() {
        let long = String(repeating: "a", count: 600)
        let t = step(ctx(.listening), .partialTranscript(long, generation: 1))
        XCTAssertEqual(t.context.partialTranscript.count, 500)
        XCTAssertTrue(t.effects.isEmpty)

        let armed = step(ctx(.armed), .partialTranscript("hi", generation: 1))
        XCTAssertEqual(armed.context.partialTranscript, "hi")
        let transcribing = step(ctx(.transcribing), .partialTranscript("yo", generation: 1))
        XCTAssertEqual(transcribing.context.partialTranscript, "yo")
    }

    func testR31_talkReleasedEndsByUser() {
        var c = ctx(.listening)
        c.captureMode = .hold
        let t = step(c, .talkReleased(heldSeconds: 0.9))
        XCTAssertEqual(t.context.state, .transcribing)
        XCTAssertTrue(t.context.captureEndedByUser)
        XCTAssertEqual(t.effects, [.endCapture(generation: 1), .cue(.captureEnd),
                                   .startTimer(.finalWatchdog, generation: 1, seconds: 5.0)])
    }

    func testR31_boundary_exactThresholdIsAHold() {
        var c = ctx(.listening)
        c.captureMode = .hold
        let t = step(c, .talkReleased(heldSeconds: 0.35))
        XCTAssertEqual(t.context.state, .transcribing)
        XCTAssertTrue(t.context.captureEndedByUser)
    }

    func testR32_tapLatchesToggleAndRestartsCap() {
        var c = ctx(.listening)
        c.captureMode = .hold
        let t = step(c, .talkReleased(heldSeconds: 0.1))
        XCTAssertEqual(t.context.state, .listening)
        XCTAssertEqual(t.context.captureMode, .toggle)
        XCTAssertEqual(t.effects, [.startTimer(.listenCap, generation: 1, seconds: 10.0)])
    }

    func testR32_boundary_justUnderThresholdIsATap() {
        var c = ctx(.listening)
        c.captureMode = .hold
        let t = step(c, .talkReleased(heldSeconds: 0.3499))
        XCTAssertEqual(t.context.state, .listening)
        XCTAssertEqual(t.context.captureMode, .toggle)
    }

    func testR33_toggleTalkEndsByUser() {
        var c = ctx(.listening)
        c.captureMode = .hold
        let toggle = step(c, .toggleTalk)
        XCTAssertEqual(toggle.context.state, .transcribing)
        XCTAssertTrue(toggle.context.captureEndedByUser)

        var latch = ctx(.listening)
        latch.captureMode = .toggle
        let pressed = step(latch, .talkPressed)
        XCTAssertEqual(pressed.context.state, .transcribing)

        var hold = ctx(.listening)
        hold.captureMode = .hold
        let repeatPress = step(hold, .talkPressed)
        XCTAssertEqual(repeatPress.context, hold)
        XCTAssertTrue(repeatPress.effects.isEmpty)
    }

    func testR34_listenCapEndsByCap() {
        var c = ctx(.listening)
        c.captureMode = .hold
        let t = step(c, .timerElapsed(.listenCap, generation: 1))
        XCTAssertEqual(t.context.state, .transcribing)
        XCTAssertFalse(t.context.captureEndedByUser)
        XCTAssertEqual(t.effects, [.endCapture(generation: 1), .cue(.captureEnd),
                                   .startTimer(.finalWatchdog, generation: 1, seconds: 5.0)])
    }

    func testR35_finalTranscriptHandlesFinal() {
        let t = step(ctx(.listening), .finalTranscript("mute", generation: 1))
        XCTAssertEqual(t.context.state, .review)
        XCTAssertEqual(t.context.route, .local(.mute))
        XCTAssertEqual(t.context.lane, .local)
        XCTAssertEqual(t.context.finalTranscript, "mute")
        XCTAssertFalse(t.context.captureEndedByUser)
        XCTAssertEqual(t.effects, [
            .endCapture(generation: 1), .cue(.captureEnd), .cue(.commit),
            .startTimer(.review, generation: 1, seconds: 1.5),
            .audit(AuditDraft(kind: .route, lane: .local, decision: "pending", transcript: "mute"))
        ])
    }

    func testR36_captureFailed() {
        let t = step(ctx(.listening), .captureFailed(.noSpeech, generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .noSpeech)
        XCTAssertEqual(t.effects, [
            .cancelCapture(generation: 1), .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, decision: "failure", outcome: "no_speech"))
        ])
    }

    func testR37_cancel() {
        let t = step(ctx(.listening), .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 1),
                                   .audit(AuditDraft(kind: .cancel, decision: "cancel"))])
    }

    // MARK: transcribing

    func testR40_finalTranscriptEntersReview() {
        var c = ctx(.transcribing)
        c.captureEndedByUser = true
        let t = step(c, .finalTranscript("mute", generation: 1))
        XCTAssertEqual(t.context.state, .review)
        XCTAssertEqual(t.effects, [
            .cue(.commit), .startTimer(.review, generation: 1, seconds: 1.5),
            .audit(AuditDraft(kind: .route, lane: .local, decision: "pending", transcript: "mute"))
        ])
    }

    func testR41_finalWatchdogTimesOut() {
        let t = step(ctx(.transcribing), .timerElapsed(.finalWatchdog, generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .timeout)
        XCTAssertEqual(t.effects, [
            .cancelCapture(generation: 1), .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, decision: "failure", outcome: "timeout"))
        ])
    }

    func testR42_captureFailed() {
        let t = step(ctx(.transcribing), .captureFailed(.noSpeech, generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .noSpeech)
        XCTAssertEqual(t.effects.first, VoiceEffect.cancelCapture(generation: 1))
    }

    func testR43_cancel() {
        let t = step(ctx(.transcribing), .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 1),
                                   .audit(AuditDraft(kind: .cancel, decision: "cancel"))])
    }

    // MARK: final handling

    func testR50_emptyFinalIsNoSpeech() {
        let t = step(ctx(.listening), .finalTranscript("   ", generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .noSpeech)
        XCTAssertEqual(t.effects, [
            .endCapture(generation: 1), .cue(.captureEnd), .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, decision: "failure", outcome: "no_speech"))
        ])
    }

    func testR51_lockedFinalIsLockedError() {
        let t = step(ctx(.listening), .finalTranscript("mute", generation: 1), env(locked: true))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .screenLocked)
        XCTAssertEqual(t.effects, [
            .endCapture(generation: 1), .cue(.captureEnd),
            .audit(AuditDraft(kind: .lock, decision: "blocked")),
            .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, decision: "failure", outcome: "locked"))
        ])
    }

    func testR52_emergencyStopStopsAll() {
        let t = step(ctx(.listening), .finalTranscript("abort agent", generation: 1))
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [
            .endCapture(generation: 1), .cue(.captureEnd),
            .cancelCapture(generation: 1),
            .audit(AuditDraft(kind: .stop, decision: "spoken_abort", outcome: "soft"))
        ])
    }

    func testR53_rejectedFinalIsError() {
        let t = step(ctx(.listening), .finalTranscript("volume 150", generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .rejected(.invalidArgument))
        XCTAssertEqual(t.effects, [
            .endCapture(generation: 1), .cue(.captureEnd),
            .audit(AuditDraft(kind: .route, decision: "reject", outcome: "invalidArgument",
                              transcript: "volume 150")),
            .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, decision: "failure",
                              outcome: "rejected.invalidArgument"))
        ])
    }

    func testR54_remoteNeedsUserRelease() {
        let t = step(ctx(.transcribing), .finalTranscript("what is the weather", generation: 1),
                     env(hermes: true))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .rejected(.needsUserRelease))
        for effect in t.effects {
            if case .submitToAgent = effect { XCTFail("must not submit") }
        }
    }

    func testR55_remoteDailyCap() {
        var c = ctx(.transcribing)
        c.captureEndedByUser = true
        let t = step(c, .finalTranscript("what is the weather", generation: 1),
                     env(hermes: true, turns: 0))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .dailyCapReached)
    }

    func testR56_remoteEntersReviewHermes() {
        var c = ctx(.transcribing)
        c.captureEndedByUser = true
        let t = step(c, .finalTranscript("what is the weather", generation: 1), env(hermes: true))
        XCTAssertEqual(t.context.state, .review)
        XCTAssertEqual(t.context.lane, .hermes)
        XCTAssertEqual(t.context.route, .remote(utterance: "what is the weather"))
        XCTAssertEqual(t.effects, [
            .cue(.commit), .startTimer(.review, generation: 1, seconds: 1.5),
            .audit(AuditDraft(kind: .route, lane: .hermes, decision: "pending",
                              transcript: "what is the weather"))
        ])
    }

    func testR57_localEntersReviewLocal() {
        var c = ctx(.transcribing)
        c.captureEndedByUser = true
        let t = step(c, .finalTranscript("mute", generation: 1))
        XCTAssertEqual(t.context.state, .review)
        XCTAssertEqual(t.context.lane, .local)
        XCTAssertEqual(t.context.route, .local(.mute))
    }

    func testR58_cancelTurnIsUnreachableFromHandleFinal() {
        var c = ctx(.transcribing)
        c.captureEndedByUser = true
        let stop = step(c, .finalTranscript("stop", generation: 1))
        XCTAssertEqual(stop.context.state, .review)
        XCTAssertEqual(stop.context.route, .local(.mediaPause))
        XCTAssertEqual(stop.context.lane, .local)
        let cancel = step(c, .finalTranscript("cancel", generation: 1))
        XCTAssertEqual(cancel.context.state, .error)
        XCTAssertEqual(cancel.context.failure, .rejected(.ambiguous))
        XCTAssertFalse(stop.effects.contains(.cancelAgentTurn))
        XCTAssertFalse(cancel.effects.contains(.cancelAgentTurn))
    }

    // MARK: review

    func testR60_a_localAllowExecutes() {
        var c = ctx(.review)
        c.route = .local(.volumeSet(percent: 30))
        c.lane = .local
        let t = step(c, .timerElapsed(.review, generation: 1))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertEqual(t.effects, [
            .execute(.volumeSet(percent: 30), generation: 1),
            .audit(AuditDraft(kind: .execute, lane: .local, tier: .t0, decision: "allow")),
            .startTimer(.localExecutionBudget, generation: 1,
                        seconds: VoiceTiming.localExecutionBudget)
        ])
    }

    func testR61_localConfirmShowsCard() {
        var c = ctx(.review)
        c.route = .local(.volumeSet(percent: 90))
        c.lane = .local
        let t = step(c, .timerElapsed(.review, generation: 1), env(nonce: "n1"))
        XCTAssertEqual(t.context.state, .awaitingApproval)
        XCTAssertEqual(t.context.pending?.nonce, "n1")
        XCTAssertEqual(t.context.pending?.tier, .t2)
        XCTAssertEqual(t.context.pendingIntent, .volumeSet(percent: 90))
        XCTAssertEqual(t.effects, [
            .cue(.needsConfirmation),
            .startTimer(.approval, generation: 1, seconds: 60.0),
            .audit(AuditDraft(kind: .approval, lane: .local, tier: .t2, decision: "requested"))
        ])
    }

    func testR62_localDenyIsError() {
        var c = ctx(.review)
        c.route = .local(.volumeSet(percent: 150))
        c.lane = .local
        let t = step(c, .timerElapsed(.review, generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .denied(.tierT4))
        XCTAssertEqual(t.effects, [
            .audit(AuditDraft(kind: .denial, lane: .local, tier: .t4, decision: "tierT4")),
            .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, lane: .local, decision: "failure",
                              outcome: "denied.tierT4"))
        ])
    }

    func testR63_remoteSubmits() {
        var c = ctx(.review)
        c.route = .remote(utterance: "what is the weather")
        c.lane = .hermes
        let t = step(c, .timerElapsed(.review, generation: 1))
        XCTAssertEqual(t.context.state, .thinking)
        XCTAssertEqual(t.effects, [
            .submitToAgent(utterance: "what is the weather", generation: 1),
            .startTimer(.turnBudget, generation: 1, seconds: 180.0),
            .audit(AuditDraft(kind: .submit, lane: .hermes, tier: .t1, decision: "allow"))
        ])
    }

    func testR63_b_remoteRateLimited() {
        var c = ctx(.review)
        c.route = .remote(utterance: "x")
        c.lane = .hermes
        for _ in 0..<10 { _ = c.rate.tryConsume(tier: .t1, now: t0) }
        let t = step(c, .timerElapsed(.review, generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .rateLimited)
    }

    func testR64_nilRouteGoesIdle() {
        var c = ctx(.review)
        c.route = .cancelTurn
        let t = step(c, .timerElapsed(.review, generation: 1))
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR65_cancelReview() {
        var c = ctx(.review)
        c.route = .local(.mute)
        c.lane = .local
        let t = step(c, .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .cancel, lane: .local,
                                                     decision: "review"))])
    }

    // MARK: awaitingApproval

    func testR70_lockedApproveIsNoOp() {
        let c = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let t = step(c, .approveRequested(nonce: "n1"), env(locked: true))
        XCTAssertEqual(t.context, c)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR71_nonceMismatchAuditsOnly() {
        let c = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let t = step(c, .approveRequested(nonce: "wrong"))
        XCTAssertEqual(t.context, c)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .approval,
                                                     decision: "nonce_mismatch"))])
    }

    func testR72_blockedApproveIsNoOp() {
        let c = ctx(.awaitingApproval) {
            $0.pending = ConfirmationRequest(nonce: "n1", tier: .t2, source: .local,
                                             summary: "s", literal: "s", isTruncated: true)
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let t = step(c, .approveRequested(nonce: "n1"))
        XCTAssertEqual(t.context, c)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .approval, tier: .t2,
                                                     decision: "blocked"))])
    }

    func testR73_a_localApproveExecutes() {
        let c = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let t = step(c, .approveRequested(nonce: "n1"))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertNil(t.context.pending)
        XCTAssertNil(t.context.pendingIntent)
        XCTAssertEqual(t.effects, [
            .cue(.approved),
            .execute(.volumeSet(percent: 90), generation: 1),
            .audit(AuditDraft(kind: .approval, lane: .local, tier: .t2, decision: "approved")),
            .startTimer(.localExecutionBudget, generation: 1,
                        seconds: VoiceTiming.localExecutionBudget)
        ])
    }

    func testR73_b_localApproveRateLimited() {
        var c = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        for _ in 0..<3 { _ = c.rate.tryConsume(tier: .t2, now: t0) }
        let t = step(c, .approveRequested(nonce: "n1"))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .rateLimited)
    }

    func testR74_a_agentApproveRespondsAllow() {
        let c = ctx(.awaitingApproval) {
            $0.pending = agentCard(tier: .t0)
            $0.lane = .hermes
        }
        let t = step(c, .approveRequested(nonce: "c1"))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertEqual(t.context.approvedToolStarts, 0)
        XCTAssertEqual(t.effects, [
            .respondToApproval(nonce: "c1", allow: true),
            .cue(.approved),
            .audit(AuditDraft(kind: .approval, lane: .hermes, tier: .t0, decision: "approved"))
        ])
    }

    func testR74_b_agentApproveT2IncrementsToolStarts() {
        let c = ctx(.awaitingApproval) {
            $0.pending = agentCard(tier: .t2)
            $0.lane = .hermes
        }
        let t = step(c, .approveRequested(nonce: "c1"))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertEqual(t.context.approvedToolStarts, 1)
        XCTAssertEqual(t.effects.first, VoiceEffect.respondToApproval(nonce: "c1", allow: true))
    }

    func testR74_c_agentApproveRateLimitedDenies() {
        var c = ctx(.awaitingApproval) {
            $0.pending = agentCard(tier: .t2)
            $0.lane = .hermes
        }
        for _ in 0..<3 { _ = c.rate.tryConsume(tier: .t2, now: t0) }
        let t = step(c, .approveRequested(nonce: "c1"))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertEqual(t.context.approvedToolStarts, 0)
        XCTAssertEqual(t.effects, [
            .respondToApproval(nonce: "c1", allow: false),
            .audit(AuditDraft(kind: .denial, lane: .hermes, tier: .t2,
                              decision: "rate_limited"))
        ])
    }

    func testR75_denyNonceMismatch() {
        let c = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let t = step(c, .denyRequested(nonce: "wrong"))
        XCTAssertEqual(t.context, c)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .approval,
                                                     decision: "nonce_mismatch"))])
    }

    func testR76_localDenyGoesIdle() {
        let c = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let t = step(c, .denyRequested(nonce: "n1"))
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .denial, lane: .local, tier: .t2,
                                                     decision: "denied"))])
    }

    func testR77_agentDenyRespondsFalse() {
        let c = ctx(.awaitingApproval) {
            $0.pending = agentCard()
            $0.lane = .hermes
        }
        let t = step(c, .denyRequested(nonce: "c1"))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertEqual(t.effects, [
            .respondToApproval(nonce: "c1", allow: false),
            .audit(AuditDraft(kind: .denial, lane: .hermes, tier: .t2, decision: "denied"))
        ])
    }

    func testR78_a_approvalTimerExpiresLocal() {
        let c = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let t = step(c, .timerElapsed(.approval, generation: 1))
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .denial, lane: .local, tier: .t2,
                                                     decision: "expired"))])
    }

    func testR78_b_approvalTimerExpiresAgent() {
        let c = ctx(.awaitingApproval) {
            $0.pending = agentCard()
            $0.lane = .hermes
        }
        let t = step(c, .timerElapsed(.approval, generation: 1))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertEqual(t.effects, [
            .respondToApproval(nonce: "c1", allow: false),
            .audit(AuditDraft(kind: .denial, lane: .hermes, tier: .t2, decision: "expired"))
        ])
    }

    func testR79_a_cancelLocalCard() {
        let c = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        let t = step(c, .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .denial, lane: .local, tier: .t2,
                                                     decision: "cancel"))])
    }

    func testR79_b_cancelAgentCard() {
        let c = ctx(.awaitingApproval) {
            $0.pending = agentCard()
            $0.lane = .hermes
        }
        let t = step(c, .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [
            .respondToApproval(nonce: "c1", allow: false),
            .cancelAgentTurn,
            .audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "approval"))
        ])
    }

    // MARK: agent busy

    func testR80_partialUpdatesReply() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let t = step(c, .agent(.partial("hello"), generation: 1))
        XCTAssertEqual(t.context.reply, "hello")
        XCTAssertTrue(t.effects.isEmpty)

        let long = String(repeating: "a", count: 500)
        let boundedResult = step(c, .agent(.partial(long), generation: 1))
        XCTAssertEqual(boundedResult.context.reply.count, 400)
    }

    func testR81_statusIsNoOp() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let t = step(c, .agent(.status("working"), generation: 1))
        XCTAssertEqual(t.context, c)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR82_a_allowedToolAppendsStep() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let t = step(c, .agent(.toolActivity(kind: "clock"), generation: 1))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertEqual(t.context.steps, [VoiceStep(id: 0, kind: "clock")])
        XCTAssertEqual(t.context.stepsStarted, 1)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR82_b_stepBudgetExceeded() {
        var c = ctx(.acting)
        c.lane = .hermes
        c.stepsStarted = 12
        let t = step(c, .agent(.toolActivity(kind: "clock"), generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .stepBudgetExceeded)
        XCTAssertEqual(t.context.stepsStarted, 13)
        XCTAssertEqual(t.context.steps.count, 1)
        XCTAssertEqual(t.effects, [
            .cancelAgentTurn, .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, lane: .hermes, decision: "failure",
                              outcome: "step_budget"))
        ])
    }

    func testR83_a_tripwireOnT3Tool() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let t = step(c, .agent(.toolActivity(kind: "terminal"), generation: 1))
        XCTAssertEqual(t.context.state, .paused)
        XCTAssertEqual(t.context.pauseReason, .tripwire("terminal"))
        XCTAssertEqual(t.context.failure, .tripwire(tool: "terminal"))
        XCTAssertEqual(t.effects, [
            .stopAgentHard, .cue(.error),
            .audit(AuditDraft(kind: .tripwire, lane: .hermes, tier: .t3,
                              decision: "tripwire", outcome: "tool.t3"))
        ])
    }

    /// The tool label comes from the model (ACP `tool_call.title`); the persisted audit record must
    /// carry only a desnotch-authored code, while the in-memory pause card keeps the label.
    func testR83_e_auditOutcomeNeverCarriesTheToolLabel() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let label = "send_mail.to-alice"
        let t = step(c, .agent(.toolActivity(kind: label), generation: 1))
        XCTAssertEqual(t.context.pauseReason, .tripwire(label))
        let outcomes = t.effects.compactMap { effect -> String? in
            if case .audit(let draft) = effect { return draft.outcome }
            return nil
        }
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes.contains { $0.contains("send_mail") })
        XCTAssertEqual(outcomes.first, "tool.t3")
    }

    func testR83_b_tripwireOnUnknownTool() {
        var c = ctx(.acting)
        c.lane = .hermes
        let t = step(c, .agent(.toolActivity(kind: "zzz"), generation: 1))
        XCTAssertEqual(t.context.state, .paused)
        XCTAssertEqual(t.context.failure, .tripwire(tool: "zzz"))
        XCTAssertEqual(t.effects.first, VoiceEffect.stopAgentHard)
    }

    func testR83_c_tripwireOnUnapprovedT2() {
        var c = ctx(.acting)
        c.lane = .hermes
        c.approvedToolStarts = 0
        let t = step(c, .agent(.toolActivity(kind: "write_file"), generation: 1))
        XCTAssertEqual(t.context.state, .paused)
        XCTAssertEqual(t.context.failure, .tripwire(tool: "write_file"))
    }

    func testR83_d_t2WithApprovalIsAllowed() {
        var c = ctx(.acting)
        c.lane = .hermes
        c.approvedToolStarts = 1
        let t = step(c, .agent(.toolActivity(kind: "write_file"), generation: 1))
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertEqual(t.context.approvedToolStarts, 0)
        XCTAssertEqual(t.context.steps.count, 1)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR84_a_autoDenyPipe() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let request = agentCard(nonce: "r1", tier: .t2, risk: [.pipeToInterpreter])
        let t = step(c, .agent(.approvalNeeded(request), generation: 1))
        XCTAssertEqual(t.context.state, .thinking)
        XCTAssertNil(t.context.pending)
        XCTAssertEqual(t.effects, [
            .respondToApproval(nonce: "r1", allow: false),
            .audit(AuditDraft(kind: .denial, lane: .hermes, tier: .t2, decision: "auto_deny"))
        ])
    }

    func testR84_b_autoDenyT4() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let t = step(c, .agent(.approvalNeeded(agentCard(nonce: "r1", tier: .t4)), generation: 1))
        XCTAssertEqual(t.effects.first, VoiceEffect.respondToApproval(nonce: "r1", allow: false))
    }

    func testR84_c_autoDenyT3NoSecondFactor() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let request = agentCard(nonce: "r1", tier: .t3)
        let t = step(c, .agent(.approvalNeeded(request), generation: 1), env(secondFactor: false))
        XCTAssertNil(t.context.pending)
        XCTAssertEqual(t.effects.first, VoiceEffect.respondToApproval(nonce: "r1", allow: false))

        let card = step(c, .agent(.approvalNeeded(request), generation: 1), env(secondFactor: true))
        XCTAssertEqual(card.context.state, .awaitingApproval)
    }

    func testR85_approvalNeededShowsCard() {
        var c = ctx(.acting)
        c.lane = .hermes
        let request = agentCard(nonce: "r1", tier: .t2)
        let t = step(c, .agent(.approvalNeeded(request), generation: 1))
        XCTAssertEqual(t.context.state, .awaitingApproval)
        XCTAssertEqual(t.context.pending, request)
        XCTAssertNil(t.context.pendingIntent)
        XCTAssertEqual(t.effects, [
            .cue(.needsConfirmation),
            .startTimer(.approval, generation: 1, seconds: 60.0),
            .audit(AuditDraft(kind: .approval, lane: .hermes, tier: .t2, decision: "requested"))
        ])
    }

    func testR86_finishedSpeaks() {
        var c = ctx(.acting)
        c.lane = .hermes
        let t = step(c, .agent(.finished(summary: "It is sunny"), generation: 1), env(speech: true))
        XCTAssertEqual(t.context.state, .speaking)
        XCTAssertEqual(t.context.reply, "It is sunny")
        XCTAssertEqual(t.effects, [
            .speak("It is sunny", generation: 1),
            .startTimer(.replyDisplay, generation: 1, seconds: 6.0 + Double("It is sunny".count) / 10),
            .cue(.done),
            .audit(AuditDraft(kind: .execute, lane: .hermes, decision: "finished", outcome: "ok"))
        ])
    }

    func testR87_failedIsError() {
        var c = ctx(.thinking)
        c.lane = .hermes
        let t = step(c, .agent(.failed(.agentFailed("boom")), generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .agentFailed("boom"))
        XCTAssertEqual(t.effects, [
            .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, lane: .hermes, decision: "failure",
                              outcome: "agent_failed"))
        ])
    }

    func testR88_usageAuditsCost() {
        let c = ctx(.idle)
        let t = step(c, .agent(.usage(inputTokens: 10, outputTokens: 20, costMicros: 30),
                               generation: 1))
        XCTAssertEqual(t.context, c)
        XCTAssertEqual(t.effects, [
            .audit(AuditDraft(kind: .cost, lane: .hermes,
                              counters: ["input_tokens": 10, "output_tokens": 20,
                                         "cost_micros": 30]))
        ])
        let stale = step(c, .agent(.usage(inputTokens: 1, outputTokens: 2, costMicros: 3),
                                   generation: 99))
        XCTAssertEqual(stale.effects.count, 1)
    }

    func testR89_turnBudgetTimesOut() {
        for state in [VoiceState.thinking, .acting] {
            var c = ctx(state)
            c.lane = .hermes
            let t = step(c, .timerElapsed(.turnBudget, generation: 1))
            XCTAssertEqual(t.context.state, .error, "\(state)")
            XCTAssertEqual(t.context.failure, .timeout, "\(state)")
        }
        let card = ctx(.awaitingApproval) {
            $0.pending = agentCard()
            $0.lane = .hermes
        }
        let t = step(card, .timerElapsed(.turnBudget, generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.effects.first, VoiceEffect.cancelAgentTurn)
    }

    func testR90_cancelAgentTurn() {
        var c = ctx(.acting)
        c.lane = .hermes
        let t = step(c, .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.cancelAgentTurn,
                                   .audit(AuditDraft(kind: .cancel, lane: .hermes,
                                                     decision: "turn"))])
    }

    func testR91_secondApprovalIsAutoDenied() {
        let c = ctx(.awaitingApproval) {
            $0.pending = agentCard(nonce: "first")
            $0.lane = .hermes
        }
        let t = step(c, .agent(.approvalNeeded(agentCard(nonce: "second")), generation: 1))
        XCTAssertEqual(t.context.pending?.nonce, "first")
        XCTAssertEqual(t.effects, [
            .respondToApproval(nonce: "second", allow: false),
            .audit(AuditDraft(kind: .denial, lane: .hermes, tier: .t2,
                              decision: "second_request"))
        ])
    }

    func testR92_toolActivityWhileCardTripsWire() {
        let c = ctx(.awaitingApproval) {
            $0.pending = agentCard()
            $0.lane = .hermes
        }
        let t = step(c, .agent(.toolActivity(kind: "clock"), generation: 1))
        XCTAssertEqual(t.context.state, .paused)
        XCTAssertEqual(t.context.failure, .tripwire(tool: "clock"))
    }

    // MARK: local execution

    func testR95_a_successWithSpeechFinishes() {
        var c = ctx(.acting)
        c.lane = .local
        let t = step(c, .localExecutionFinished(.success(spoken: "Volume 30"), generation: 1),
                     env(speech: true))
        XCTAssertEqual(t.context.state, .speaking)
        XCTAssertEqual(t.effects, [
            .speak("Volume 30", generation: 1),
            .startTimer(.replyDisplay, generation: 1, seconds: 6.0 + Double("Volume 30".count) / 10),
            .cue(.done),
            .audit(AuditDraft(kind: .execute, lane: .local, decision: "finished", outcome: "ok"))
        ])
    }

    func testR95_b_successSilentGoesIdle() {
        var c = ctx(.acting)
        c.lane = .local
        let t = step(c, .localExecutionFinished(.success(spoken: "Volume 30"), generation: 1))
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [
            .cue(.done),
            .audit(AuditDraft(kind: .execute, lane: .local, decision: "finished", outcome: "ok"))
        ])
        let silent = step(c, .localExecutionFinished(.success(spoken: nil), generation: 1),
                          env(speech: true))
        XCTAssertEqual(silent.context.state, .idle)
    }

    func testR96_failureIsError() {
        var c = ctx(.acting)
        c.lane = .local
        let t = step(c, .localExecutionFinished(.failure(.executionFailed("x")), generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.effects, [
            .audit(AuditDraft(kind: .execute, lane: .local, decision: "finished",
                              outcome: "execution_failed")),
            .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, lane: .local, decision: "failure",
                              outcome: "execution_failed"))
        ])
    }

    func testR97_cancelLocalIsNoOp() {
        var c = ctx(.acting)
        c.lane = .local
        let t = step(c, .cancelRequested)
        XCTAssertEqual(t.context, c)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR98_localWatchdogTimesOut() {
        var c = ctx(.acting)
        c.lane = .local
        let t = step(c, .timerElapsed(.localExecutionBudget, generation: 1))
        XCTAssertEqual(t.context.state, .error)
        XCTAssertEqual(t.context.failure, .timeout)
        XCTAssertFalse(t.effects.contains(.cancelAgentTurn), "a local execution has no turn to cancel")
        XCTAssertEqual(t.effects, [
            .cue(.error),
            .startTimer(.errorDisplay, generation: 1, seconds: 3.0),
            .audit(AuditDraft(kind: .error, lane: .local, decision: "failure", outcome: "timeout"))
        ])

        // The watchdog only fires in local acting; a Hermes lane or another state is a no-op.
        var hermes = ctx(.acting)
        hermes.lane = .hermes
        let wrongLane = step(hermes, .timerElapsed(.localExecutionBudget, generation: 1))
        XCTAssertEqual(wrongLane.context, hermes)
        XCTAssertTrue(wrongLane.effects.isEmpty)

        let thinking = step(ctx(.thinking), .timerElapsed(.localExecutionBudget, generation: 1))
        XCTAssertEqual(thinking.context, ctx(.thinking))
        XCTAssertTrue(thinking.effects.isEmpty)
    }

    func testR98_lateLocalFinishAfterWatchdogIsNoOp() {
        var c = ctx(.acting)
        c.lane = .local
        let timedOut = step(c, .timerElapsed(.localExecutionBudget, generation: 1))
        XCTAssertEqual(timedOut.context.state, .error)
        let late = step(timedOut.context,
                        .localExecutionFinished(.success(spoken: "Volume 30"), generation: 1))
        XCTAssertEqual(late.context, timedOut.context)
        XCTAssertTrue(late.effects.isEmpty)
    }

    // MARK: interrupt capture

    private func interruptContext() -> VoiceContext {
        ctx(.acting) {
            $0.lane = .hermes
            $0.counter = 2
            $0.interrupt = InterruptCapture(generation: 2, endedByUser: false)
        }
    }

    func testR100_talkPressedStartsInterruptCapture() {
        var c = ctx(.acting)
        c.lane = .hermes
        let t = step(c, .talkPressed)
        XCTAssertEqual(t.context.counter, 2)
        XCTAssertEqual(t.context.generation, 1)
        XCTAssertEqual(t.context.interrupt, InterruptCapture(generation: 2, endedByUser: false))
        XCTAssertEqual(t.effects, [.startCapture(generation: 2, mode: .hold)])
    }

    func testR101_captureStartedCuesStart() {
        let t = step(interruptContext(), .captureStarted(generation: 2))
        XCTAssertEqual(t.effects, [.cue(.captureStart),
                                   .startTimer(.listenCap, generation: 2, seconds: 10.0)])
    }

    func testR102_a_releaseEndsInterrupt() {
        let t = step(interruptContext(), .talkReleased(heldSeconds: 0.8))
        XCTAssertEqual(t.context.interrupt?.endedByUser, true)
        XCTAssertEqual(t.effects, [.endCapture(generation: 2), .cue(.captureEnd),
                                   .startTimer(.finalWatchdog, generation: 2, seconds: 5.0)])
    }

    func testR102_b_shortReleaseCancelsInterrupt() {
        let t = step(interruptContext(), .talkReleased(heldSeconds: 0.1))
        XCTAssertNil(t.context.interrupt)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 2)])
    }

    func testR103_a_emergencyStopPauses() {
        let t = step(interruptContext(), .finalTranscript("abort agent", generation: 2))
        XCTAssertEqual(t.context.state, .paused)
        XCTAssertEqual(t.context.pauseReason, .spokenAbort)
        XCTAssertEqual(t.effects, [
            .stopAgentHard,
            .audit(AuditDraft(kind: .stop, lane: .hermes, decision: "spoken_abort",
                              outcome: "hard"))
        ])
    }

    func testR103_b_cancelTurnGoesIdle() {
        let t = step(interruptContext(), .finalTranscript("stop", generation: 2))
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [
            .cancelAgentTurn,
            .audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "spoken"))
        ])
    }

    func testR103_c_otherTranscriptIsIgnored() {
        let t = step(interruptContext(), .finalTranscript("hello there", generation: 2))
        XCTAssertNil(t.context.interrupt)
        XCTAssertEqual(t.context.state, .acting)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR104_a_captureFailedClearsInterrupt() {
        let t = step(interruptContext(), .captureFailed(.noSpeech, generation: 2))
        XCTAssertNil(t.context.interrupt)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 2)])
    }

    func testR104_b_listenCapEndsInterrupt() {
        let t = step(interruptContext(), .timerElapsed(.listenCap, generation: 2))
        XCTAssertNotNil(t.context.interrupt)
        XCTAssertEqual(t.effects, [.endCapture(generation: 2),
                                   .startTimer(.finalWatchdog, generation: 2, seconds: 5.0)])
    }

    /// An interrupt capture whose final transcript never arrives must not stay open for the rest of
    /// the turn (R100 needs `interrupt == nil` to start another one).
    func testR104_c_finalWatchdogClearsInterrupt() {
        let released = step(interruptContext(), .talkReleased(heldSeconds: 0.8))
        let t = step(released.context, .timerElapsed(.finalWatchdog, generation: 2))
        XCTAssertNil(t.context.interrupt)
        XCTAssertEqual(t.context.state, released.context.state)
        XCTAssertEqual(t.effects, [.cancelCapture(generation: 2)])
        let stale = step(released.context, .timerElapsed(.finalWatchdog, generation: 1))
        XCTAssertNotNil(stale.context.interrupt)
    }

    func testR105_a_finishDropsTheInterruptCapture() {
        let t = step(interruptContext(), .agent(.finished(summary: "ok"), generation: 1))
        XCTAssertNil(t.context.interrupt)
        XCTAssertEqual(t.context.state, .speaking)
        XCTAssertEqual(t.effects, [
            .cancelCapture(generation: 2),
            .startTimer(.replyDisplay, generation: 1, seconds: 6.0),
            .cue(.done),
            .audit(AuditDraft(kind: .execute, lane: .hermes, decision: "finished", outcome: "ok"))
        ])
    }

    func testR105_b_cancelDropsTheInterruptCapture() {
        let t = step(interruptContext(), .cancelRequested)
        XCTAssertNil(t.context.interrupt)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [
            .cancelAgentTurn,
            .audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "turn")),
            .cancelCapture(generation: 2)
        ])
    }

    // MARK: speaking / error / paused

    func testR110_speechFinishedGoesIdle() {
        let c = ctx(.speaking)
        let finished = step(c, .speechFinished(generation: 1))
        XCTAssertEqual(finished.context.state, .idle)
        XCTAssertTrue(finished.effects.isEmpty)
        let timer = step(c, .timerElapsed(.replyDisplay, generation: 1))
        XCTAssertEqual(timer.context.state, .idle)
        XCTAssertEqual(timer.effects, [.stopSpeaking])
    }

    func testR111_talkPressedStopsSpeakingAndStartsFlow() {
        let t = step(ctx(.speaking), .talkPressed)
        XCTAssertEqual(t.context.state, .armed)
        XCTAssertEqual(t.effects, [.stopSpeaking, .startCapture(generation: 2, mode: .hold)])
    }

    func testR112_cancelStopsSpeaking() {
        let t = step(ctx(.speaking), .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertEqual(t.effects, [.stopSpeaking])
    }

    func testR120_errorDisplayGoesIdle() {
        let t = step(ctx(.error), .timerElapsed(.errorDisplay, generation: 1))
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR121_talkRestartsFromError() {
        let t = step(ctx(.error), .talkPressed)
        XCTAssertEqual(t.context.state, .armed)
        XCTAssertEqual(t.effects, [.startCapture(generation: 2, mode: .hold)])
    }

    func testR122_cancelErrorGoesIdle() {
        let t = step(ctx(.error), .cancelRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertTrue(t.effects.isEmpty)
    }

    func testR130_resumeGoesIdle() {
        let c = ctx(.paused) { $0.pauseReason = .tripwire("terminal") }
        let t = step(c, .resumeRequested)
        XCTAssertEqual(t.context.state, .idle)
        XCTAssertNil(t.context.pauseReason)
        XCTAssertEqual(t.effects, [.audit(AuditDraft(kind: .resume, decision: "resume"))])
    }

    func testR131_talkWhilePausedIsNoOp() {
        let c = ctx(.paused)
        let pressed = step(c, .talkPressed)
        XCTAssertEqual(pressed.context, c)
        XCTAssertTrue(pressed.effects.isEmpty)
        let toggle = step(c, .toggleTalk)
        XCTAssertEqual(toggle.context, c)
        XCTAssertTrue(toggle.effects.isEmpty)
    }

    func testR132_otherPausedEventsAreNoOp() {
        let c = ctx(.paused)
        let t = step(c, .timerElapsed(.turnBudget, generation: 1))
        XCTAssertEqual(t.context, c)
        XCTAssertTrue(t.effects.isEmpty)
    }

    // MARK: cross-cutting checks

    func testTimerSecondsMatchVoiceTimingConstants() throws {
        XCTAssertEqual(VoiceTiming.holdThreshold, 0.35)

        var hold = ctx(.armed)
        hold.captureMode = .hold
        let holdCap = try XCTUnwrap(timerEffect(step(hold, .captureStarted(generation: 1)).effects))
        XCTAssertEqual(holdCap.kind, .listenCap)
        XCTAssertEqual(holdCap.seconds, VoiceTiming.holdListenCap)

        var toggle = ctx(.armed)
        toggle.captureMode = .toggle
        let toggleCap = try XCTUnwrap(timerEffect(step(toggle, .captureStarted(generation: 1)).effects))
        XCTAssertEqual(toggleCap.seconds, VoiceTiming.toggleListenCap)

        var tap = ctx(.listening)
        tap.captureMode = .hold
        let tapCap = try XCTUnwrap(timerEffect(step(tap, .talkReleased(heldSeconds: 0.1)).effects))
        XCTAssertEqual(tapCap.seconds, VoiceTiming.toggleListenCap)

        var end = ctx(.listening)
        end.captureMode = .hold
        let watchdog = try XCTUnwrap(timerEffect(step(end, .talkReleased(heldSeconds: 0.9)).effects))
        XCTAssertEqual(watchdog.kind, .finalWatchdog)
        XCTAssertEqual(watchdog.seconds, VoiceTiming.finalWatchdog)

        let review = step(ctx(.listening), .finalTranscript("mute", generation: 1))
        let reviewTimer = try XCTUnwrap(timerEffect(review.effects))
        XCTAssertEqual(reviewTimer.kind, .review)
        XCTAssertEqual(reviewTimer.seconds, VoiceTiming.reviewWindow)

        var confirm = ctx(.review)
        confirm.route = .local(.volumeSet(percent: 90))
        confirm.lane = .local
        let approval = try XCTUnwrap(timerEffect(step(confirm, .timerElapsed(.review,
                                                                            generation: 1)).effects))
        XCTAssertEqual(approval.kind, .approval)
        XCTAssertEqual(approval.seconds, VoiceTiming.approvalTimeout)

        var remote = ctx(.review)
        remote.route = .remote(utterance: "x")
        remote.lane = .hermes
        let budget = try XCTUnwrap(timerEffect(step(remote, .timerElapsed(.review,
                                                                          generation: 1)).effects))
        XCTAssertEqual(budget.kind, .turnBudget)
        XCTAssertEqual(budget.seconds, VoiceTiming.agentTurnBudget)

        var localAllow = ctx(.review)
        localAllow.route = .local(.mute)
        localAllow.lane = .local
        let localWatchdog = try XCTUnwrap(timerEffect(step(localAllow, .timerElapsed(.review,
                                                                                    generation: 1)).effects))
        XCTAssertEqual(localWatchdog.kind, .localExecutionBudget)
        XCTAssertEqual(localWatchdog.seconds, VoiceTiming.localExecutionBudget)

        var card = ctx(.acting)
        card.lane = .hermes
        let cardTimer = try XCTUnwrap(timerEffect(step(card, .agent(.approvalNeeded(agentCard()),
                                                                    generation: 1)).effects))
        XCTAssertEqual(cardTimer.kind, .approval)
        XCTAssertEqual(cardTimer.seconds, VoiceTiming.approvalTimeout)

        let interruptTimer = try XCTUnwrap(timerEffect(step(interruptContext(),
                                                            .captureStarted(generation: 2)).effects))
        XCTAssertEqual(interruptTimer.kind, .listenCap)
        XCTAssertEqual(interruptTimer.seconds, VoiceTiming.toggleListenCap)

        var finish = ctx(.acting)
        finish.lane = .hermes
        let reply = try XCTUnwrap(timerEffect(step(finish, .agent(.finished(summary: "ok"),
                                                                   generation: 1)).effects))
        XCTAssertEqual(reply.kind, .replyDisplay)
        XCTAssertEqual(reply.seconds, VoiceTiming.replyDisplay)

        let error = try XCTUnwrap(timerEffect(step(ctx(.listening),
                                                   .captureFailed(.noSpeech, generation: 1)).effects))
        XCTAssertEqual(error.kind, .errorDisplay)
        XCTAssertEqual(error.seconds, VoiceTiming.errorDisplay)
    }

    func testNoSpokenWordApprovesAnything() {
        let phrases = ["yes", "approve", "approve it", "ok go ahead"]

        let local = ctx(.awaitingApproval) {
            $0.pending = localCard()
            $0.pendingIntent = .volumeSet(percent: 90)
            $0.lane = .local
        }
        for phrase in phrases {
            let t = step(local, .finalTranscript(phrase, generation: 1))
            XCTAssertEqual(t.context, local, phrase)
            XCTAssertTrue(t.effects.isEmpty, phrase)
        }

        let agent = ctx(.awaitingApproval) {
            $0.pending = agentCard()
            $0.lane = .hermes
        }
        for phrase in phrases {
            let t = step(agent, .finalTranscript(phrase, generation: 1))
            XCTAssertEqual(t.context, agent, phrase)
            XCTAssertTrue(t.effects.isEmpty, phrase)
        }

        let card = ctx(.awaitingApproval) {
            $0.pending = agentCard()
            $0.lane = .hermes
            $0.counter = 2
            $0.interrupt = InterruptCapture(generation: 2, endedByUser: false)
        }
        for phrase in phrases {
            let t = step(card, .finalTranscript(phrase, generation: 2))
            XCTAssertEqual(t.context.state, .awaitingApproval, phrase)
            XCTAssertNil(t.context.interrupt, phrase)
            XCTAssertEqual(t.context.pending, card.pending, phrase)
            XCTAssertTrue(t.effects.isEmpty, phrase)
        }
    }
}
