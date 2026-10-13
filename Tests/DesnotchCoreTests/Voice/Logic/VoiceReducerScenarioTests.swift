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

private func ctx(_ state: VoiceState, _ edit: (inout VoiceContext) -> Void = { _ in }) -> VoiceContext {
    var c = VoiceContext()
    c.state = state
    c.counter = 1
    c.generation = 1
    edit(&c)
    return c
}

private func runScript(_ script: [(VoiceEvent, VoiceReducerEnv)],
                       from start: VoiceContext = VoiceContext()) -> [VoiceTransition] {
    var c = start
    return script.map {
        let transition = VoiceReducer.reduce(c, $0.0, env: $0.1)
        c = transition.context
        return transition
    }
}

final class VoiceReducerScenarioTests: XCTestCase {
    func testScenarioS1_localHold() {
        let results = runScript([
            (.talkPressed, env()),
            (.captureStarted(generation: 1), env()),
            (.partialTranscript("volume", generation: 1), env()),
            (.talkReleased(heldSeconds: 0.9), env()),
            (.finalTranscript("volume thirty", generation: 1), env()),
            (.timerElapsed(.review, generation: 1), env()),
            (.localExecutionFinished(.success(spoken: "Volume 30"), generation: 1), env())
        ])
        XCTAssertEqual(results.map { $0.context.state },
                       [.armed, .listening, .listening, .transcribing, .review, .acting, .idle])
        XCTAssertEqual(results[4].context.route, .local(.volumeSet(percent: 30)))
        XCTAssertEqual(results[5].effects, [
            .execute(.volumeSet(percent: 30), generation: 1),
            .audit(AuditDraft(kind: .execute, lane: .local, tier: .t0, decision: "allow")),
            .startTimer(.localExecutionBudget, generation: 1,
                        seconds: VoiceTiming.localExecutionBudget)
        ])
        XCTAssertEqual(results[6].context.generation, 2)
        XCTAssertEqual(results[6].effects, [
            .cue(.done),
            .audit(AuditDraft(kind: .execute, lane: .local, decision: "finished", outcome: "ok"))
        ])
    }

    func testScenarioS2_tapLatch() {
        let results = runScript([
            (.talkPressed, env()),
            (.talkReleased(heldSeconds: 0.1), env()),
            (.captureStarted(generation: 1), env()),
            (.talkPressed, env()),
            (.finalTranscript("mute", generation: 1), env()),
            (.timerElapsed(.review, generation: 1), env())
        ])
        XCTAssertEqual(results.map { $0.context.state },
                       [.armed, .armed, .listening, .transcribing, .review, .acting])
        XCTAssertEqual(results[1].context.captureMode, .toggle)
        XCTAssertEqual(results[2].effects, [.cue(.captureStart),
                                            .startTimer(.listenCap, generation: 1, seconds: 10.0)])
        XCTAssertEqual(results[5].effects, [
            .execute(.mute, generation: 1),
            .audit(AuditDraft(kind: .execute, lane: .local, tier: .t0, decision: "allow")),
            .startTimer(.localExecutionBudget, generation: 1,
                        seconds: VoiceTiming.localExecutionBudget)
        ])
    }

    func testScenarioS3_cloudAgentWithApproval() {
        let ready = env(hermes: true)
        let card = ConfirmationRequest(nonce: "c1", tier: .t2, source: .hermes, summary: "clock",
                                       literal: "clock", risk: [])
        let results = runScript([
            (.talkPressed, ready),
            (.captureStarted(generation: 1), ready),
            (.talkReleased(heldSeconds: 1.2), ready),
            (.finalTranscript("what is the weather in Jakarta", generation: 1), ready),
            (.timerElapsed(.review, generation: 1), ready),
            (.agent(.toolActivity(kind: "clock"), generation: 1), ready),
            (.agent(.approvalNeeded(card), generation: 1), ready),
            (.approveRequested(nonce: "c1"), ready),
            (.agent(.finished(summary: "It is sunny"), generation: 1), ready),
            (.timerElapsed(.replyDisplay, generation: 1), ready)
        ])
        XCTAssertEqual(results.map { $0.context.state },
                       [.armed, .listening, .transcribing, .review, .thinking, .acting,
                        .awaitingApproval, .acting, .speaking, .idle])
        XCTAssertEqual(results[3].context.lane, .hermes)
        XCTAssertEqual(results[4].effects.first,
                       VoiceEffect.submitToAgent(utterance: "what is the weather in Jakarta",
                                                 generation: 1))
        XCTAssertEqual(results[5].context.steps, [VoiceStep(id: 0, kind: "clock")])
        XCTAssertTrue(results[7].effects.contains(.respondToApproval(nonce: "c1", allow: true)))
        XCTAssertEqual(results[8].effects.first,
                       VoiceEffect.startTimer(.replyDisplay, generation: 1, seconds: 6.0))
    }

    func testScenarioS4_tripwire() {
        let start = ctx(.thinking) { $0.lane = .hermes }
        let results = runScript([
            (.agent(.toolActivity(kind: "terminal"), generation: 1), env()),
            (.resumeRequested, env()),
            (.talkPressed, env())
        ], from: start)
        XCTAssertEqual(results.map { $0.context.state }, [.paused, .idle, .armed])
        XCTAssertEqual(results[0].context.failure, .tripwire(tool: "terminal"))
        XCTAssertEqual(results[0].effects, [
            .stopAgentHard, .cue(.error),
            .audit(AuditDraft(kind: .tripwire, lane: .hermes, tier: .t3, decision: "tripwire",
                              outcome: "tool.t3"))
        ])
    }

    func testScenarioS5_spokenAbortDuringAgentTurn() {
        let start = ctx(.acting) { $0.lane = .hermes }
        let results = runScript([
            (.talkPressed, env()),
            (.captureStarted(generation: 2), env()),
            (.talkReleased(heldSeconds: 0.8), env()),
            (.finalTranscript("abort agent", generation: 2), env())
        ], from: start)
        XCTAssertEqual(results.map { $0.context.state }, [.acting, .acting, .acting, .paused])
        XCTAssertEqual(results[0].effects, [.startCapture(generation: 2, mode: .hold)])
        XCTAssertEqual(results[2].effects, [.endCapture(generation: 2), .cue(.captureEnd),
                                            .startTimer(.finalWatchdog, generation: 2, seconds: 5.0)])
        XCTAssertEqual(results[3].effects, [
            .stopAgentHard,
            .audit(AuditDraft(kind: .stop, lane: .hermes, decision: "spoken_abort",
                              outcome: "hard"))
        ])
    }

    func testScenarioS6_staleEvents() {
        let results = runScript([
            (.talkPressed, env()),
            (.captureStarted(generation: 99), env()),
            (.finalTranscript("volume 10", generation: 99), env()),
            (.timerElapsed(.review, generation: 99), env())
        ])
        XCTAssertEqual(results.map { $0.context.state }, [.armed, .armed, .armed, .armed])
        XCTAssertTrue(results[1].effects.isEmpty)
        XCTAssertTrue(results[2].effects.isEmpty)
        XCTAssertTrue(results[3].effects.isEmpty)
    }

    func testScenarioS7_reviewCancel() {
        let results = runScript([
            (.talkPressed, env()),
            (.captureStarted(generation: 1), env()),
            (.talkReleased(heldSeconds: 0.9), env()),
            (.finalTranscript("volume thirty", generation: 1), env()),
            (.cancelRequested, env()),
            (.timerElapsed(.review, generation: 1), env())
        ])
        XCTAssertEqual(results.map { $0.context.state },
                       [.armed, .listening, .transcribing, .review, .idle, .idle])
        XCTAssertTrue(results[5].effects.isEmpty)
    }

    func testScenarioS8_lock() {
        let results = runScript([
            (.talkPressed, env()),
            (.captureStarted(generation: 1), env()),
            (.screenLocked, env())
        ])
        XCTAssertEqual(results.map { $0.context.state }, [.armed, .listening, .idle])
        XCTAssertEqual(results[2].effects, [.cancelCapture(generation: 1),
                                            .audit(AuditDraft(kind: .cancel, decision: "locked"))])
    }

    func testScenarioS9_capEndedNeverReachesTheCloud() {
        let ready = env(hermes: true)
        let results = runScript([
            (.talkPressed, ready),
            (.captureStarted(generation: 1), ready),
            (.timerElapsed(.listenCap, generation: 1), ready),
            (.finalTranscript("what is the weather", generation: 1), ready)
        ])
        XCTAssertEqual(results.map { $0.context.state },
                       [.armed, .listening, .transcribing, .error])
        XCTAssertEqual(results[3].context.failure, .rejected(.needsUserRelease))
    }

    func testScenarioS10_localConfirmCard() {
        let start = ctx(.transcribing) { $0.captureEndedByUser = true }
        let results = runScript([
            (.finalTranscript("volume ninety", generation: 1), env(nonce: "n1")),
            (.timerElapsed(.review, generation: 1), env(nonce: "n1")),
            (.denyRequested(nonce: "n1"), env(nonce: "n1"))
        ], from: start)
        XCTAssertEqual(results.map { $0.context.state }, [.review, .awaitingApproval, .idle])
        XCTAssertEqual(results[1].context.pending?.nonce, "n1")
        XCTAssertEqual(results[1].context.pendingIntent, .volumeSet(percent: 90))
        XCTAssertEqual(results[2].effects, [
            .audit(AuditDraft(kind: .denial, lane: .local, tier: .t2, decision: "denied"))
        ])
    }
}
