import AppKit
import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceCoordinatorLocalTests: XCTestCase {
    private var retained: [CoordParts] = []

    nonisolated override func tearDown() {
        MainActor.assumeIsolated {
            for parts in retained {
                parts.coordinator.stop()
                parts.defaults.removePersistentDomain(forName: parts.suiteName)
            }
            retained.removeAll()
        }
        super.tearDown()
    }

    func testTypedVolumeCommandRunsThroughReviewAndExecutes() async {
        let parts = makeParts()
        parts.coordinator.submitTyped("volume thirty")
        XCTAssertEqual(parts.coordinator.context.state, .review)
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: {
            parts.executor.executed.contains(.volumeSet(percent: 30))
                && parts.coordinator.context.state == .idle
        })
    }

    func testHoldFlowWithScriptedRecognizer() async {
        let recognizer = ScriptedRecognizer(script: [
            .captureStarted, .partial("volume"), .final("volume thirty")
        ])
        let parts = makeParts(recognizer: recognizer)
        parts.coordinator.dispatch(.talkPressed)
        await CoordTestSupport.settle(self, until: {
            let state = parts.coordinator.context.state
            return state == .listening || state == .review
        })
        parts.coordinator.dispatch(.talkReleased(heldSeconds: 1))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .review })
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: {
            parts.executor.executed.contains(.volumeSet(percent: 30))
                && parts.coordinator.context.state == .idle
        })
    }

    func testReviewWindowCancelByEscapeNeverExecutes() async {
        let parts = makeParts()
        parts.coordinator.submitTyped("volume thirty")
        XCTAssertEqual(parts.coordinator.context.state, .review)
        parts.model.cancelReview()
        XCTAssertEqual(parts.coordinator.context.state, .idle)
        XCTAssertTrue(parts.executor.executed.isEmpty)
    }

    func testStopKeyAlwaysStopsAndReturnsIdle() async {
        let parts = makeParts()
        await reachListening(parts)
        parts.keys.made[0].send(.stopKey)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .idle })
        XCTAssertNotEqual(parts.coordinator.context.state, .paused)
    }

    func testLockedScreenRefusesToStart() async {
        let parts = makeParts()
        parts.lock.locked = true
        parts.coordinator.dispatch(.talkPressed)
        XCTAssertEqual(parts.coordinator.context.state, .error)
        XCTAssertEqual(parts.coordinator.context.failure, .screenLocked)
        XCTAssertEqual(parts.held.startCount, 0)
    }

    func testScreenLockedWhileListeningCancelsCapture() async {
        let parts = makeParts()
        await reachListening(parts)
        parts.lock.set(locked: true)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .idle })
        XCTAssertGreaterThanOrEqual(parts.held.cancelCalls, 1)
    }

    func testFeatureDisabledStopsCaptureAndReleasesKeys() async {
        let parts = makeParts()
        await reachListening(parts)
        parts.settings.voiceEnabled = false
        await CoordTestSupport.settle(self, until: {
            parts.coordinator.context.state == .idle
                && parts.keys.made[0].stopCount >= 1
                && parts.model.hotkeyStatus == .unavailable
        })
    }

    func testCancelKeyIsArmedOnlyWhileActive() async {
        let parts = makeParts()
        parts.coordinator.dispatch(.talkPressed)
        XCTAssertEqual(parts.keys.made[0].cancelArmedHistory.last, true)
        parts.coordinator.dispatch(.cancelRequested)
        XCTAssertEqual(parts.coordinator.context.state, .idle)
        XCTAssertEqual(parts.keys.made[0].cancelArmedHistory.last, false)
    }

    func testCancelKeyIsDisarmedInIdleAndPaused() async {
        let parts = makeParts(laneOn: true)
        XCTAssertNotEqual(parts.keys.made[0].cancelArmedHistory.last, true)
        await reachReady(parts)
        parts.coordinator.submitTyped("what is the weather")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .thinking })
        XCTAssertEqual(parts.keys.made[0].cancelArmedHistory.last, true)
        parts.coordinator.dispatch(.stopAllRequested)
        XCTAssertEqual(parts.coordinator.context.state, .paused)
        XCTAssertEqual(parts.keys.made[0].cancelArmedHistory.last, false)
    }

    func testDuckingIsBalanced() async {
        let held = await duckedCapture()
        held.coordinator.dispatch(.talkReleased(heldSeconds: 1))
        XCTAssertEqual(held.ducker.duckCount, 1)
        XCTAssertEqual(held.ducker.restoreCount, 1)

        let cancelled = await duckedCapture()
        cancelled.coordinator.dispatch(.cancelRequested)
        XCTAssertEqual(cancelled.ducker.duckCount, 1)
        XCTAssertEqual(cancelled.ducker.restoreCount, 1)
        XCTAssertEqual(cancelled.coordinator.context.state, .idle)

        let finalized = await duckedCapture()
        finalized.coordinator.dispatch(.talkReleased(heldSeconds: 1))
        finalized.held.emit(.final("volume thirty"))
        await CoordTestSupport.settle(self, until: { finalized.coordinator.context.state == .review })
        XCTAssertEqual(finalized.ducker.duckCount, 1)
        XCTAssertEqual(finalized.ducker.restoreCount, 1)

        let early = makeParts()
        early.coordinator.dispatch(.talkPressed)
        early.coordinator.dispatch(.cancelRequested)
        await CoordTestSupport.settle(self, until: { early.coordinator.context.state == .idle })
        XCTAssertEqual(early.ducker.duckCount, 0)
        XCTAssertEqual(early.ducker.restoreCount, 0)
    }

    func testDuckerRestoredWhenTheRecognizerFinalizesByItself() async {
        let recognizer = ScriptedRecognizer(script: [.captureStarted, .final("volume thirty")])
        let parts = makeParts(recognizer: recognizer)
        parts.coordinator.dispatch(.talkPressed)
        await CoordTestSupport.settle(self, until: {
            parts.ducker.duckCount == 1 && parts.ducker.restoreCount == 1
        })
        parts.coordinator.dispatch(.talkReleased(heldSeconds: 1))
        XCTAssertEqual(parts.ducker.duckCount, 1)
        XCTAssertEqual(parts.ducker.restoreCount, 1)
    }

    func testT2VolumeNeedsApprovalAndWrongNonceDoesNothing() async {
        let parts = makeParts()
        parts.coordinator.submitTyped("volume ninety")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        XCTAssertEqual(parts.coordinator.context.state, .awaitingApproval)
        parts.model.approve(nonce: "zzz")
        XCTAssertEqual(parts.coordinator.context.state, .awaitingApproval)
        XCTAssertTrue(parts.executor.executed.isEmpty)
        let nonce = parts.model.pendingConfirmation?.nonce
        XCTAssertEqual(nonce, "nonce-1")
        if let nonce {
            parts.model.approve(nonce: nonce)
        }
        await CoordTestSupport.settle(self, until: {
            parts.executor.executed.contains(.volumeSet(percent: 90))
        })
    }

    func testApproveExecutesAndDenyDoesNot() async {
        let denied = makeParts()
        denied.coordinator.submitTyped("volume ninety")
        fire(denied, seconds: VoiceTiming.reviewWindow)
        let denyNonce = denied.model.pendingConfirmation?.nonce ?? ""
        denied.model.deny(nonce: denyNonce)
        XCTAssertEqual(denied.coordinator.context.state, .idle)
        XCTAssertTrue(denied.executor.executed.isEmpty)

        let approved = makeParts()
        approved.coordinator.submitTyped("volume ninety")
        fire(approved, seconds: VoiceTiming.reviewWindow)
        let allowNonce = approved.model.pendingConfirmation?.nonce ?? ""
        approved.model.approve(nonce: allowNonce)
        await CoordTestSupport.settle(self, until: {
            approved.executor.executed.contains(.volumeSet(percent: 90))
        })
    }

    func testAuditUnwritableRefusesT2ButNotT0() async {
        let parts = makeParts()
        parts.audit.failing = true
        parts.coordinator.submitTyped("volume thirty")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: {
            parts.executor.executed.contains(.volumeSet(percent: 30)) && !parts.audit.drafts.isEmpty
        })
        await CoordTestSupport.drainMainRound()
        parts.coordinator.submitTyped("volume ninety")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        XCTAssertEqual(parts.coordinator.context.state, .awaitingApproval)
        let nonce = parts.model.pendingConfirmation?.nonce ?? ""
        parts.model.approve(nonce: nonce)
        XCTAssertFalse(parts.executor.executed.contains(.volumeSet(percent: 90)))
        XCTAssertEqual(parts.coordinator.context.failure, .executionFailed("audit_unwritable"))
    }

    func testRepliesAreSpokenOnlyWhenAllowed() async {
        let parts = makeParts()
        parts.executor.result = .success(spoken: "Volume 30")
        parts.coordinator.submitTyped("volume thirty")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .idle })
        XCTAssertTrue(parts.synth.spoken.isEmpty)

        parts.settings.voiceTTSEnabled = true
        parts.settings.privacyModeEnabled = false
        parts.coordinator.submitTyped("volume thirty")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: {
            parts.synth.spoken.contains { $0.text == "Volume 30" }
        })

        let spoken = parts.synth.spoken.count
        parts.settings.privacyModeEnabled = true
        parts.coordinator.submitTyped("volume thirty")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .idle })
        XCTAssertEqual(parts.synth.spoken.count, spoken)
    }

    func testNoCloudSubmitWithoutUserRelease() async {
        let parts = makeParts(laneOn: true)
        await reachReady(parts)
        parts.coordinator.dispatch(.talkPressed)
        parts.held.emit(.captureStarted)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .listening })
        parts.held.emit(.final("what is the weather"))
        await CoordTestSupport.settle(self, until: {
            parts.coordinator.context.failure == .rejected(.needsUserRelease)
        })
        XCTAssertTrue(parts.gated.submitted.isEmpty)
    }

    func testDailyCapRefusesTheTurn() async {
        let parts = makeParts(laneOn: true, exhaustTurns: true)
        await reachReady(parts)
        parts.coordinator.submitTyped("what is the weather")
        XCTAssertEqual(parts.coordinator.context.failure, .dailyCapReached)
        XCTAssertTrue(parts.gated.submitted.isEmpty)
    }

    func testDisabledVoiceStartsNothing() {
        let parts = makeParts(voiceOn: false)
        XCTAssertTrue(parts.keys.made.isEmpty)
        XCTAssertEqual(parts.held.startCount, 0)
        XCTAssertTrue(parts.timers.scheduled.isEmpty)
    }

    func testLockIsReadOnlyForTheEventsThatConsultIt() {
        let parts = makeParts()
        let generation = parts.coordinator.context.generation
        parts.coordinator.dispatch(.partialTranscript("hi", generation: generation))
        XCTAssertEqual(parts.lock.isLockedReadCount, 0)
        parts.coordinator.dispatch(.talkPressed)
        parts.coordinator.dispatch(.toggleTalk)
        parts.coordinator.dispatch(.finalTranscript("volume thirty", generation: parts.coordinator.context.generation))
        parts.coordinator.dispatch(.approveRequested(nonce: "nope"))
        XCTAssertEqual(parts.lock.isLockedReadCount, 4)
    }

    func testHotkeyLabelsMatchTheBindingDisplayStrings() {
        for choice in VoiceHotkeyChoice.allCases {
            XCTAssertEqual(
                VoiceSettingsWords.hotkeyLabel(choice),
                VoiceHotkeyMap.binding(for: choice).displayString
            )
        }
    }

    func testModelActionsDispatchEvents() async {
        let toggled = makeParts()
        toggled.model.toggleTalk()
        XCTAssertEqual(toggled.coordinator.context.state, .armed)
        toggled.model.cancelReview()
        XCTAssertEqual(toggled.coordinator.context.state, .idle)

        let reviewed = makeParts()
        reviewed.model.submitTyped("volume thirty")
        XCTAssertEqual(reviewed.coordinator.context.state, .review)
        reviewed.model.cancelReview()
        XCTAssertEqual(reviewed.coordinator.context.state, .idle)
        XCTAssertTrue(reviewed.executor.executed.isEmpty)

        let permissions = makeParts()
        let granted = VoicePermissionStatus(microphone: .authorized, speech: .authorized)
        permissions.permissions.requestResult = granted
        permissions.model.requestPermissions()
        await CoordTestSupport.settle(self, until: { permissions.model.permissions == granted })

        let paused = makeParts(laneOn: true)
        await reachReady(paused)
        paused.coordinator.submitTyped("what is the weather")
        fire(paused, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { paused.coordinator.context.state == .thinking })
        paused.model.stopAll()
        XCTAssertEqual(paused.coordinator.context.state, .paused)
        paused.model.resume()
        XCTAssertEqual(paused.coordinator.context.state, .idle)

        let denied = makeParts()
        denied.coordinator.submitTyped("volume ninety")
        fire(denied, seconds: VoiceTiming.reviewWindow)
        denied.model.deny(nonce: denied.model.pendingConfirmation?.nonce ?? "")
        XCTAssertEqual(denied.coordinator.context.state, .idle)
        XCTAssertTrue(denied.executor.executed.isEmpty)

        let approved = makeParts()
        approved.coordinator.submitTyped("volume ninety")
        fire(approved, seconds: VoiceTiming.reviewWindow)
        approved.model.approve(nonce: approved.model.pendingConfirmation?.nonce ?? "")
        await CoordTestSupport.settle(self, until: {
            approved.executor.executed.contains(.volumeSet(percent: 90))
        })
    }

    func testStaleTimerFromOldFlowIsIgnored() async {
        let parts = makeParts()
        parts.coordinator.submitTyped("volume thirty")
        let generation = parts.coordinator.context.generation
        XCTAssertEqual(parts.coordinator.context.state, .review)
        parts.model.cancelReview()
        XCTAssertEqual(parts.coordinator.context.state, .idle)
        XCTAssertNotEqual(parts.coordinator.context.generation, generation)
        parts.coordinator.dispatch(.timerElapsed(.review, generation: generation))
        XCTAssertEqual(parts.coordinator.context.state, .idle)
        XCTAssertTrue(parts.executor.executed.isEmpty)
    }

    func testInterruptCaptureDoesNotCancelTurnBudgetOrApprovalTimers() async {
        let parts = makeParts(laneOn: true)
        await reachAgentCard(parts)
        XCTAssertTrue(parts.timers.scheduled.contains(VoiceTiming.agentTurnBudget))
        XCTAssertTrue(parts.timers.scheduled.contains(VoiceTiming.approvalTimeout))
        let cancelled = parts.timers.cancelledCount
        parts.keys.made[0].send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.held.startCount == 1 })
        XCTAssertEqual(parts.timers.cancelledCount, cancelled)
        fire(parts, seconds: VoiceTiming.agentTurnBudget)
        XCTAssertEqual(parts.coordinator.context.state, .error)
        XCTAssertEqual(parts.coordinator.context.failure, .timeout)
    }

    func testSilentRecognizerStreamEndFailsTheCaptureInsteadOfHanging() async {
        let parts = makeParts(recognizer: ScriptedRecognizer(script: []))
        parts.coordinator.dispatch(.talkPressed)
        await CoordTestSupport.settle(self, until: {
            parts.coordinator.context.failure == .unavailable(.recognizer)
        })
    }

    func testNoAuditRecordContainsTheTranscript() async {
        let parts = makeParts()
        parts.coordinator.submitTyped("volume thirty")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: {
            parts.executor.executed.contains(.volumeSet(percent: 30)) && !parts.audit.drafts.isEmpty
        })
        let spoken = "volume thirty"
        for draft in parts.audit.drafts {
            XCTAssertFalse(draft.decision?.contains(spoken) ?? false)
            XCTAssertFalse(draft.outcome?.contains(spoken) ?? false)
            XCTAssertFalse(draft.kind.rawValue.contains(spoken))
            XCTAssertFalse(draft.lane?.rawValue.contains(spoken) ?? false)
        }
    }

    func testSettingsFlipOnARealSettingsStoreStartsAndStopsVoice() async {
        let parts = makeParts(voiceOn: false)
        XCTAssertEqual(parts.keys.made.count, 0)
        parts.settings.voiceEnabled = true
        await CoordTestSupport.settle(self, until: {
            parts.keys.made.count == 1 && parts.keys.made[0].startCount == 1
        })
        parts.settings.voiceEnabled = false
        await CoordTestSupport.settle(self, until: {
            parts.keys.made[0].stopCount == 1 && parts.model.hotkeyStatus == .unavailable
        })
        parts.settings.voiceEnabled = true
        await CoordTestSupport.settle(self, until: {
            parts.keys.made.count == 2
                && parts.keys.made[1].startCount == 1
                && parts.keys.made[1].stopCount == 0
                && parts.model.hotkeyStatus == .active
                && parts.lock.changesAccessCount == 2
        })
        XCTAssertFalse(parts.keys.made[0] === parts.keys.made[1])
        parts.keys.made[1].send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state != .idle })
    }

    func testHotkeyChangeWhileEnabledBuildsANewSource() async {
        let parts = makeParts()
        XCTAssertEqual(parts.keys.made.count, 1)
        parts.settings.voiceHotkey = .optionCommandJ
        await CoordTestSupport.settle(self, until: { parts.keys.made.count == 2 })
        XCTAssertEqual(parts.keys.made[0].stopCount, 1)
        XCTAssertEqual(parts.keys.choices.last, .optionCommandJ)
        XCTAssertEqual(parts.keys.made[1].startCount, 1)
        XCTAssertEqual(parts.keys.made[1].cancelArmedHistory.last, false)

        let disabled = makeParts(voiceOn: false)
        disabled.settings.voiceHotkey = .optionCommandJ
        for _ in 0..<4 {
            await CoordTestSupport.drainMainRound()
        }
        XCTAssertEqual(disabled.keys.made.count, 0)
    }

    func testHermesLaneFlipOnARealSettingsStoreBecomesReadyOrRefused() async {
        let readyBackend = CoordGatedBackend()
        let ready = makeParts(voiceOn: false, backend: readyBackend)
        ready.settings.voiceEnabled = true
        await CoordTestSupport.settle(self, until: { ready.model.hotkeyStatus == .active })
        ready.settings.voiceHermesLane = true
        await CoordTestSupport.settle(self, until: { ready.model.hermesLaneStatus == .ready })
        ready.settings.voiceHermesLane = false
        await CoordTestSupport.settle(self, until: { ready.model.hermesLaneStatus == .off })

        let refusedBackend = CoordGatedBackend()
        refusedBackend.preflightResult = .refused(.profileMissing)
        let refused = makeParts(voiceOn: false, backend: refusedBackend)
        refused.settings.voiceEnabled = true
        await CoordTestSupport.settle(self, until: { refused.model.hotkeyStatus == .active })
        refused.settings.voiceHermesLane = true
        await CoordTestSupport.settle(self, until: {
            refused.model.hermesLaneStatus == .refused(.profileMissing)
        })
        refused.settings.voiceHermesLane = false
        await CoordTestSupport.settle(self, until: { refused.model.hermesLaneStatus == .off })
    }

    func testNullBackendLaneCheckRefusesWithNotImplemented() async {
        let parts = makeParts(laneOn: true, backend: NullBackend())
        await CoordTestSupport.settle(self, until: {
            parts.model.hermesLaneStatus == .refused(.notImplemented)
        })
        parts.coordinator.submitTyped("what is the weather")
        XCTAssertEqual(parts.coordinator.context.failure, .rejected(.notLocalCommand))
    }

    func testHermesLaneNotReadyWhileHotkeyUnavailable() async {
        let backend = CoordGatedBackend()
        let parts = makeParts(laneOn: true, hotkeyStatus: .unavailable, backend: backend)
        await CoordTestSupport.settle(self, until: {
            parts.model.hermesLaneStatus == .ready && parts.model.hotkeyStatus == .unavailable
        })
        parts.coordinator.submitTyped("what is the weather")
        XCTAssertEqual(parts.coordinator.context.failure, .rejected(.notLocalCommand))
        XCTAssertNotEqual(parts.coordinator.context.state, .thinking)
        XCTAssertTrue(backend.submitted.isEmpty)
    }

    func testLaneCheckIsAudited() async {
        let parts = makeParts(laneOn: true)
        await CoordTestSupport.settle(self, until: {
            parts.audit.drafts.contains { $0.kind == .preflight && $0.decision == "ready" }
        })
        parts.coordinator.submitTyped("what is the weather")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .thinking })
        parts.gated.emit(.failed(.preflightRefused(.approvalsOff)))
        await CoordTestSupport.settle(self, until: {
            parts.audit.drafts.filter { $0.kind == .preflight }.count >= 2
                && parts.model.hermesLaneStatus == .refused(.approvalsOff)
        })
    }

    func testSubmitToAgentWithScriptedBackendCountsTheTurnOncePerSubmit() async {
        let open = ScriptedBackend(script: [.status("started")])
        let first = makeParts(laneOn: true, backend: open)
        await reachReady(first)
        XCTAssertEqual(turnsLeft(first), VoiceLimits.hermesTurnsPerDay)
        first.coordinator.submitTyped("what is the weather")
        fire(first, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: {
            first.coordinator.context.failure == .agentFailed("stream_ended")
        })
        XCTAssertEqual(turnsLeft(first), VoiceLimits.hermesTurnsPerDay - 1)

        let refused = ScriptedBackend(script: [
            .status("started"), .failed(.preflightRefused(.approvalsOff))
        ])
        let second = makeParts(laneOn: true, backend: refused)
        await reachReady(second)
        second.coordinator.submitTyped("what is the weather")
        fire(second, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: {
            second.model.hermesLaneStatus == .refused(.approvalsOff)
                && second.coordinator.context.failure == .preflightRefused(.approvalsOff)
        })
        XCTAssertEqual(turnsLeft(second), VoiceLimits.hermesTurnsPerDay - 1)
        XCTAssertNotEqual(second.coordinator.context.failure, .agentFailed("stream_ended"))
    }

    func testCancelRightAfterPressLeavesTheRecognizerCancelledAfterStart() async {
        let cancelled = makeParts()
        cancelled.coordinator.dispatch(.talkPressed)
        cancelled.coordinator.dispatch(.cancelRequested)
        XCTAssertEqual(cancelled.held.startCount, 1)
        XCTAssertGreaterThanOrEqual(cancelled.held.cancelCalls, 1)
        XCTAssertEqual(cancelled.coordinator.context.state, .idle)
        cancelled.held.emit(.captureStarted)
        cancelled.held.emit(.final("x"))
        await CoordTestSupport.drainMainRound()
        XCTAssertEqual(cancelled.coordinator.context.state, .idle)

        let locked = makeParts()
        locked.coordinator.dispatch(.talkPressed)
        XCTAssertEqual(locked.held.startCount, 1)
        locked.lock.set(locked: true)
        await CoordTestSupport.settle(self, until: {
            locked.coordinator.context.state == .idle && locked.held.cancelCalls >= 1
        })
        locked.held.emit(.captureStarted)
        locked.held.emit(.final("x"))
        await CoordTestSupport.drainMainRound()
        XCTAssertEqual(locked.coordinator.context.state, .idle)

        let released = makeParts()
        released.coordinator.dispatch(.talkPressed)
        released.coordinator.dispatch(.talkReleased(heldSeconds: 0.5))
        XCTAssertEqual(released.held.startCount, 1)
        XCTAssertGreaterThanOrEqual(released.held.cancelCalls, 1)
        XCTAssertEqual(released.coordinator.context.state, .idle)
        released.held.emit(.captureStarted)
        released.held.emit(.final("x"))
        await CoordTestSupport.drainMainRound()
        XCTAssertEqual(released.coordinator.context.state, .idle)
    }

    func testAuditUnwritableConvertsAgentApprovalToDeny() async {
        let denied = makeParts(laneOn: true)
        await reachAgentCard(denied)
        let before = denied.audit.drafts.count
        denied.audit.failing = true
        denied.model.approve(nonce: "zzz")
        await CoordTestSupport.settle(self, until: { denied.audit.drafts.count > before })
        await CoordTestSupport.drainMainRound()
        denied.model.approve(nonce: "c1")
        await CoordTestSupport.settle(self, until: { denied.gated.responses.count == 1 })
        XCTAssertEqual(denied.gated.responses.first?.nonce, "c1")
        XCTAssertEqual(denied.gated.responses.first?.allow, false)
        XCTAssertEqual(denied.coordinator.context.state, .acting)

        let allowed = makeParts(laneOn: true)
        await reachAgentCard(allowed)
        allowed.model.approve(nonce: "c1")
        await CoordTestSupport.settle(self, until: { allowed.gated.responses.count == 1 })
        XCTAssertEqual(allowed.gated.responses.first?.nonce, "c1")
        XCTAssertEqual(allowed.gated.responses.first?.allow, true)
        XCTAssertEqual(allowed.coordinator.context.state, .acting)
    }

    func testInterruptCaptureStartsTheRecognizerEvenAfterATypedSubmit() async {
        let parts = makeParts(laneOn: true)
        await reachReady(parts)
        parts.coordinator.submitTyped("what is the weather")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .thinking })
        XCTAssertEqual(parts.held.startCount, 0)
        parts.keys.made[0].send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.held.startCount == 1 })
    }

    func testVoiceOffResetsTheLaneStatus() async {
        let backend = CoordGatedBackend()
        let parts = makeParts(laneOn: true, backend: backend)
        await reachReady(parts)
        parts.settings.voiceEnabled = false
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .off })

        backend.preflightGated = true
        let calls = backend.preflightCalls
        parts.settings.voiceEnabled = true
        await CoordTestSupport.settle(self, until: {
            parts.model.hermesLaneStatus == .checking && backend.preflightCalls > calls
        })
        parts.settings.voiceEnabled = false
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .off })
        backend.releasePreflight()
        for _ in 0..<6 {
            await CoordTestSupport.drainMainRound()
        }
        XCTAssertEqual(parts.model.hermesLaneStatus, .off)
    }

    func testAppCompositionConstructsTheVoiceCoordinatorOnlyInsideTheNotSmokeTestBranch() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<12 {
            let candidate = directory.appendingPathComponent("Sources/DesnotchCore/App/AppComposition.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            directory.deleteLastPathComponent()
        }
        let url = try XCTUnwrap(found)
        let text = try String(contentsOf: url, encoding: .utf8)
        let sourceLines = text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let coordinatorLines = sourceLines.enumerated().filter { $0.element.contains("VoiceCoordinator(") }
        let guardLines = sourceLines.enumerated().filter { $0.element.contains("if !smokeTestMode {") }
        XCTAssertEqual(coordinatorLines.count, 1)
        XCTAssertEqual(guardLines.count, 1)
        let guardIndex = guardLines[0].offset
        let coordinatorIndex = coordinatorLines[0].offset
        XCTAssertLessThan(guardIndex, coordinatorIndex)
        var balance = 0
        for line in sourceLines[guardIndex...coordinatorIndex] {
            balance += line.filter { $0 == "{" }.count
            balance -= line.filter { $0 == "}" }.count
        }
        XCTAssertGreaterThanOrEqual(balance, 1)
    }

    func testStopTwiceIsIdempotent() {
        let parts = makeParts()
        let keys = parts.keys.made[0]
        parts.coordinator.stop()
        parts.coordinator.stop()
        XCTAssertEqual(keys.stopCount, 1)
        XCTAssertEqual(parts.terminator.count, 1)
    }

    func testDidBecomeActiveRerunsARefusedLaneCheck() async {
        let backend = CoordGatedBackend()
        backend.preflightResult = .refused(.profileMissing)
        let parts = makeParts(laneOn: true, backend: backend)
        await CoordTestSupport.settle(self, until: {
            parts.model.hermesLaneStatus == .refused(.profileMissing)
        })
        let calls = backend.preflightCalls
        backend.preflightResult = .ready(profile: "voice")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .ready })
        XCTAssertGreaterThan(backend.preflightCalls, calls)
        let after = backend.preflightCalls
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<6 {
            await CoordTestSupport.drainMainRound()
        }
        XCTAssertEqual(backend.preflightCalls, after)
    }

    func testStartVoiceAppendsAChainBrokenRecordWhenVerifyFails() async {
        let broken = makeParts(laneOn: false, chainBroken: true)
        await CoordTestSupport.settle(self, until: {
            broken.audit.drafts.contains { $0.kind == .error && $0.decision == "audit_chain_broken" }
        })

        let valid = makeParts(laneOn: false)
        for _ in 0..<8 {
            await CoordTestSupport.drainMainRound()
        }
        XCTAssertFalse(valid.audit.drafts.contains {
            $0.kind == .error && $0.decision == "audit_chain_broken"
        })
    }

    private func makeParts(
        voiceOn: Bool = true,
        laneOn: Bool = false,
        debug: Bool = true,
        hotkeyStatus: PushToTalkStatus = .active,
        recognizer overrideRecognizer: SpeechRecognizing? = nil,
        backend overrideBackend: AgentBackend? = nil,
        nonce: String = "nonce-1",
        chainBroken: Bool = false,
        exhaustTurns: Bool = false
    ) -> CoordParts {
        let suiteName = "desnotch.voice.coord.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if voiceOn { defaults.set(true, forKey: SettingsStore.Key.voiceEnabled.rawValue) }
        if laneOn { defaults.set(true, forKey: SettingsStore.Key.voiceHermesLane.rawValue) }
        let settings = SettingsStore(defaults: defaults)
        let clock = FakeVoiceClock()
        if exhaustTurns {
            var seeding = DailyTurnCounter(defaults: defaults)
            for _ in 0..<VoiceLimits.hermesTurnsPerDay {
                seeding.increment(now: clock.now())
            }
        }
        let model = VoiceSessionModel()
        let keys = CoordKeyBox()
        keys.startResult = hotkeyStatus
        let lock = CoordFakeLock()
        let ducker = CoordRecordingDucker()
        let synth = CoordRecordingSynth()
        synth.gated = false
        let audit = CoordRecordingAudit()
        audit.failing = false
        if chainBroken {
            audit.verification = AuditVerification(
                isValid: false, recordCount: 0, firstBrokenSeq: 1, headHash: "broken"
            )
        }
        let permissions = CoordFakePermissions()
        let timers = CoordManualTimerScheduler()
        let cues = RecordingCuePlayer()
        let executor = RecordingExecutor()
        let held = CoordHeldRecognizer()
        let recognizer = overrideRecognizer ?? held
        let gated = CoordGatedBackend()
        let backend = overrideBackend ?? gated
        let terminator = CoordTerminateCounter()
        let coordinator = VoiceCoordinator(
            model: model,
            settings: settings,
            clock: clock,
            recognizer: recognizer,
            synthesizer: synth,
            executor: executor,
            backend: backend,
            terminateAgentNow: { terminator.invoke() },
            audit: audit,
            makeKeys: { keys.make($0) },
            lock: lock,
            ducker: ducker,
            permissions: permissions,
            cues: cues,
            timers: timers,
            dailyTurns: DailyTurnCounter(defaults: defaults),
            isPrivacyMode: { settings.privacyModeEnabled },
            makeNonce: { nonce },
            debugTypingEnabled: debug
        )
        coordinator.start()
        let parts = CoordParts(
            suiteName: suiteName,
            defaults: defaults,
            settings: settings,
            model: model,
            clock: clock,
            keys: keys,
            lock: lock,
            ducker: ducker,
            synth: synth,
            audit: audit,
            permissions: permissions,
            timers: timers,
            cues: cues,
            executor: executor,
            held: held,
            gated: gated,
            backend: backend,
            terminator: terminator,
            coordinator: coordinator
        )
        retained.append(parts)
        return parts
    }

    private func fire(_ parts: CoordParts, seconds: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let index = parts.timers.scheduled.lastIndex(of: seconds) else {
            XCTFail("missing timer \(seconds)", file: file, line: line)
            return
        }
        parts.timers.fire(index: index)
    }

    private func turnsLeft(_ parts: CoordParts) -> Int {
        DailyTurnCounter(defaults: parts.defaults).remaining(now: parts.clock.now())
    }

    private func reachListening(_ parts: CoordParts) async {
        parts.coordinator.dispatch(.talkPressed)
        parts.held.emit(.captureStarted)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .listening })
    }

    private func reachReady(_ parts: CoordParts) async {
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .ready })
    }

    private func reachAgentCard(_ parts: CoordParts) async {
        await reachReady(parts)
        parts.coordinator.submitTyped("what is the weather")
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .thinking })
        parts.gated.emit(.toolActivity(kind: "clock"))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .acting })
        parts.gated.emit(.approvalNeeded(ConfirmationRequest(
            nonce: "c1", tier: .t2, source: .hermes, summary: "Run the clock", literal: "clock"
        )))
        await CoordTestSupport.settle(self, until: {
            parts.coordinator.context.state == .awaitingApproval
                && parts.model.pendingConfirmation?.nonce == "c1"
        })
    }

    private func duckedCapture() async -> CoordParts {
        let parts = makeParts()
        parts.coordinator.dispatch(.talkPressed)
        parts.held.emit(.captureStarted)
        await CoordTestSupport.settle(self, until: { parts.ducker.duckCount == 1 })
        return parts
    }
}

@MainActor
final class CoordParts {
    let suiteName: String
    let defaults: UserDefaults
    let settings: SettingsStore
    let model: VoiceSessionModel
    let clock: FakeVoiceClock
    let keys: CoordKeyBox
    let lock: CoordFakeLock
    let ducker: CoordRecordingDucker
    let synth: CoordRecordingSynth
    let audit: CoordRecordingAudit
    let permissions: CoordFakePermissions
    let timers: CoordManualTimerScheduler
    let cues: RecordingCuePlayer
    let executor: RecordingExecutor
    let held: CoordHeldRecognizer
    let gated: CoordGatedBackend
    let backend: AgentBackend
    let terminator: CoordTerminateCounter
    let coordinator: VoiceCoordinator

    init(
        suiteName: String,
        defaults: UserDefaults,
        settings: SettingsStore,
        model: VoiceSessionModel,
        clock: FakeVoiceClock,
        keys: CoordKeyBox,
        lock: CoordFakeLock,
        ducker: CoordRecordingDucker,
        synth: CoordRecordingSynth,
        audit: CoordRecordingAudit,
        permissions: CoordFakePermissions,
        timers: CoordManualTimerScheduler,
        cues: RecordingCuePlayer,
        executor: RecordingExecutor,
        held: CoordHeldRecognizer,
        gated: CoordGatedBackend,
        backend: AgentBackend,
        terminator: CoordTerminateCounter,
        coordinator: VoiceCoordinator
    ) {
        self.suiteName = suiteName
        self.defaults = defaults
        self.settings = settings
        self.model = model
        self.clock = clock
        self.keys = keys
        self.lock = lock
        self.ducker = ducker
        self.synth = synth
        self.audit = audit
        self.permissions = permissions
        self.timers = timers
        self.cues = cues
        self.executor = executor
        self.held = held
        self.gated = gated
        self.backend = backend
        self.terminator = terminator
        self.coordinator = coordinator
    }
}

@MainActor
final class CoordKeyBox {
    var made: [CoordFakeKeys] = []
    var choices: [VoiceHotkeyChoice] = []
    var startResult: PushToTalkStatus = .active

    func make(_ choice: VoiceHotkeyChoice) -> PushToTalkSource {
        choices.append(choice)
        let keys = CoordFakeKeys()
        keys.startResult = startResult
        made.append(keys)
        return keys
    }
}

@MainActor
final class CoordFakeKeys: PushToTalkSource {
    private var continuation: AsyncStream<PushToTalkEvent>.Continuation?
    private var stopped = false
    let events: AsyncStream<PushToTalkEvent>
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelArmedHistory: [Bool] = []
    var startResult: PushToTalkStatus = .active

    init() {
        let pair = AsyncStream<PushToTalkEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start() -> PushToTalkStatus {
        if stopped { return .unavailable }
        startCount += 1
        return startResult
    }

    func stop() {
        stopCount += 1
        stopped = true
        continuation?.finish()
        continuation = nil
    }

    func setCancelKeyArmed(_ armed: Bool) {
        cancelArmedHistory.append(armed)
    }

    func send(_ event: PushToTalkEvent) {
        continuation?.yield(event)
    }
}

@MainActor
final class CoordFakeLock: LockStateProviding {
    var locked = false
    private(set) var isLockedReadCount = 0
    private(set) var changesAccessCount = 0
    private var continuations: [AsyncStream<Bool>.Continuation] = []

    var isLocked: Bool {
        isLockedReadCount += 1
        return locked
    }

    var changes: AsyncStream<Bool> {
        changesAccessCount += 1
        let pair = AsyncStream<Bool>.makeStream()
        continuations.append(pair.continuation)
        return pair.stream
    }

    func set(locked: Bool) {
        self.locked = locked
        for continuation in continuations {
            continuation.yield(locked)
        }
    }
}

@MainActor
final class CoordRecordingDucker: MediaDucking {
    private(set) var duckCount = 0
    private(set) var restoreCount = 0

    func duck() { duckCount += 1 }
    func restore() { restoreCount += 1 }
}

final class CoordRecordingSynth: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [(text: String, locale: String)] = []
    private var stops = 0
    private var waits = true
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    var gated: Bool {
        get { lock.lock(); defer { lock.unlock() }; return waits }
        set { lock.lock(); waits = newValue; lock.unlock() }
    }

    var spoken: [(text: String, locale: String)] {
        lock.lock(); defer { lock.unlock() }; return texts
    }

    var stopCount: Int {
        lock.lock(); defer { lock.unlock() }; return stops
    }

    func speak(_ text: String, localeIdentifier: String) async -> Bool {
        let shouldWait = beginSpeak(text: text, locale: localeIdentifier)
        if !shouldWait { return true }
        return await withCheckedContinuation { continuation in
            park(continuation)
        }
    }

    func finishSpeaking(_ result: Bool = true) {
        let waiter = takeWaiter()
        waiter?.resume(returning: result)
    }

    func stop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

    private func beginSpeak(text: String, locale: String) -> Bool {
        lock.lock()
        texts.append((text: text, locale: locale))
        let shouldWait = waits
        lock.unlock()
        return shouldWait
    }

    private func park(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        waiters.append(continuation)
        lock.unlock()
    }

    private func takeWaiter() -> CheckedContinuation<Bool, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard !waiters.isEmpty else { return nil }
        return waiters.removeFirst()
    }
}

final class CoordRecordingAudit: AuditLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AuditDraft] = []
    private var refuses = true
    private var storedVerification = AuditVerification.empty

    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return refuses }
        set { lock.lock(); refuses = newValue; lock.unlock() }
    }

    var drafts: [AuditDraft] {
        lock.lock(); defer { lock.unlock() }; return stored
    }

    var verification: AuditVerification {
        get { lock.lock(); defer { lock.unlock() }; return storedVerification }
        set { lock.lock(); storedVerification = newValue; lock.unlock() }
    }

    func append(_ draft: AuditDraft) async -> Bool {
        record(draft)
    }

    func verify() async -> AuditVerification {
        currentVerification()
    }

    private func record(_ draft: AuditDraft) -> Bool {
        lock.lock()
        stored.append(draft)
        let ok = !refuses
        lock.unlock()
        return ok
    }

    private func currentVerification() -> AuditVerification {
        lock.lock()
        defer { lock.unlock() }
        return storedVerification
    }
}

@MainActor
final class CoordFakePermissions: VoicePermissionProviding {
    var statusResult = VoicePermissionStatus.unknown
    var requestResult = VoicePermissionStatus(microphone: .authorized, speech: .authorized)
    private(set) var requestCount = 0

    func status() -> VoicePermissionStatus { statusResult }

    func request() async -> VoicePermissionStatus {
        requestCount += 1
        return requestResult
    }
}

final class CoordHeldRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var starts = 0
    private var ends = 0
    private var cancels = 0
    private var locales: [String] = []
    private var strings: [[String]] = []

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var endAudioCalls: Int { lock.lock(); defer { lock.unlock() }; return ends }
    var cancelCalls: Int { lock.lock(); defer { lock.unlock() }; return cancels }
    var localeIdentifiers: [String] { lock.lock(); defer { lock.unlock() }; return locales }
    var contextualStrings: [[String]] { lock.lock(); defer { lock.unlock() }; return strings }

    func start(localeIdentifier: String, contextualStrings: [String]) -> AsyncStream<SpeechEvent> {
        let pair = AsyncStream<SpeechEvent>.makeStream()
        let previous = storeStart(
            locale: localeIdentifier, strings: contextualStrings, continuation: pair.continuation
        )
        previous?.finish()
        return pair.stream
    }

    func endAudio() {
        lock.lock()
        ends += 1
        lock.unlock()
    }

    func cancel() {
        let current = takeCancel()
        current?.finish()
    }

    func emit(_ event: SpeechEvent) {
        let current = currentContinuation()
        current?.yield(event)
    }

    func finish() {
        let current = takeFinish()
        current?.finish()
    }

    private func storeStart(
        locale: String,
        strings: [String],
        continuation next: AsyncStream<SpeechEvent>.Continuation
    ) -> AsyncStream<SpeechEvent>.Continuation? {
        lock.lock()
        let previous = continuation
        continuation = next
        starts += 1
        locales.append(locale)
        self.strings.append(strings)
        lock.unlock()
        return previous
    }

    private func takeCancel() -> AsyncStream<SpeechEvent>.Continuation? {
        lock.lock()
        cancels += 1
        let current = continuation
        continuation = nil
        lock.unlock()
        return current
    }

    private func takeFinish() -> AsyncStream<SpeechEvent>.Continuation? {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        return current
    }

    private func currentContinuation() -> AsyncStream<SpeechEvent>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuation
    }
}

final class CoordGatedBackend: AgentBackend, @unchecked Sendable {
    let id = "gated"
    private let lock = NSLock()
    private var log: [String] = []
    private var utterances: [String] = []
    private var answers: [(nonce: String, allow: Bool)] = []
    private var cancels = 0
    private var stops = 0
    private var shutdowns = 0
    private var preflights = 0
    private var preflightValue: AgentPreflightResult = .ready(profile: "voice")
    private var report = EmergencyStopReport()
    private var gatePreflight = false
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var preflightWaiters: [CheckedContinuation<AgentPreflightResult, Never>] = []

    var callLog: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var submitted: [String] { lock.lock(); defer { lock.unlock() }; return utterances }
    var responses: [(nonce: String, allow: Bool)] { lock.lock(); defer { lock.unlock() }; return answers }
    var cancelCalls: Int { lock.lock(); defer { lock.unlock() }; return cancels }
    var emergencyStops: Int { lock.lock(); defer { lock.unlock() }; return stops }
    var shutdownCalls: Int { lock.lock(); defer { lock.unlock() }; return shutdowns }
    var preflightCalls: Int { lock.lock(); defer { lock.unlock() }; return preflights }

    var preflightResult: AgentPreflightResult {
        get { lock.lock(); defer { lock.unlock() }; return preflightValue }
        set { lock.lock(); preflightValue = newValue; lock.unlock() }
    }

    var emergencyReport: EmergencyStopReport {
        get { lock.lock(); defer { lock.unlock() }; return report }
        set { lock.lock(); report = newValue; lock.unlock() }
    }

    var preflightGated: Bool {
        get { lock.lock(); defer { lock.unlock() }; return gatePreflight }
        set { lock.lock(); gatePreflight = newValue; lock.unlock() }
    }

    func preflight() async -> AgentPreflightResult {
        let decision = notePreflight()
        if let result = decision { return result }
        return await withCheckedContinuation { continuation in
            parkPreflight(continuation)
        }
    }

    func submit(_ utterance: String) -> AsyncStream<AgentEvent> {
        let pair = AsyncStream<AgentEvent>.makeStream()
        let previous = storeSubmit(utterance, continuation: pair.continuation)
        previous?.finish()
        return pair.stream
    }

    func respond(nonce: String, allow: Bool) async {
        recordResponse(nonce: nonce, allow: allow)
    }

    func cancelTurn() async {
        recordCancel()
    }

    func emergencyStop() async -> EmergencyStopReport {
        recordStop()
    }

    func shutdown() async {
        recordShutdown()
    }

    func emit(_ event: AgentEvent) {
        let current = currentContinuation()
        current?.yield(event)
    }

    func finish() {
        let current = takeFinish()
        current?.finish()
    }

    func releasePreflight() {
        let pending = takePreflightWaiters()
        let result = preflightResult
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    private func notePreflight() -> AgentPreflightResult? {
        lock.lock()
        log.append("preflight")
        preflights += 1
        let gated = gatePreflight
        let result = preflightValue
        lock.unlock()
        return gated ? nil : result
    }

    private func parkPreflight(_ continuation: CheckedContinuation<AgentPreflightResult, Never>) {
        lock.lock()
        preflightWaiters.append(continuation)
        lock.unlock()
    }

    private func takePreflightWaiters() -> [CheckedContinuation<AgentPreflightResult, Never>] {
        lock.lock()
        let pending = preflightWaiters
        preflightWaiters.removeAll()
        lock.unlock()
        return pending
    }

    private func storeSubmit(
        _ utterance: String,
        continuation next: AsyncStream<AgentEvent>.Continuation
    ) -> AsyncStream<AgentEvent>.Continuation? {
        lock.lock()
        log.append("submit")
        utterances.append(utterance)
        let previous = continuation
        continuation = next
        lock.unlock()
        return previous
    }

    private func recordResponse(nonce: String, allow: Bool) {
        lock.lock()
        log.append("respond")
        answers.append((nonce: nonce, allow: allow))
        lock.unlock()
    }

    private func recordCancel() {
        lock.lock()
        log.append("cancelTurn")
        cancels += 1
        lock.unlock()
    }

    private func recordStop() -> EmergencyStopReport {
        lock.lock()
        log.append("emergencyStop")
        stops += 1
        let current = report
        lock.unlock()
        return current
    }

    private func recordShutdown() {
        lock.lock()
        log.append("shutdown")
        shutdowns += 1
        lock.unlock()
    }

    private func currentContinuation() -> AsyncStream<AgentEvent>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuation
    }

    private func takeFinish() -> AsyncStream<AgentEvent>.Continuation? {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        return current
    }
}

final class CoordTerminateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func invoke() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

enum CoordTestSupport {
    @MainActor
    static func drainMainRound() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    static func settle(_ test: XCTestCase, until condition: @MainActor () -> Bool, maxRounds: Int = 500,
                       file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<maxRounds {
            if condition() { return }
            await drainMainRound()
            await Task.yield()
        }
        if !condition() { XCTFail("condition not met after \(maxRounds) rounds", file: file, line: line) }
    }
}
