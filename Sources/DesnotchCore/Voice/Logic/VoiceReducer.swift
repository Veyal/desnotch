import Foundation

// WP-LOGIC owns this file. Base commit: fail-closed stub with the final signature.

/// The session state machine as a pure function. No clocks, no I/O, no randomness: time and
/// nonces come in through `VoiceReducerEnv`.
enum VoiceReducer {
    static func reduce(_ context: VoiceContext, _ event: VoiceEvent,
                       env: VoiceReducerEnv) -> VoiceTransition {
        // R88: cost accounting survives every state and a stale generation.
        if case .agent(.usage(let input, let output, let cost), _) = event {
            return VoiceTransition(context: context, effects: [
                .audit(AuditDraft(kind: .cost, lane: .hermes,
                                  counters: ["input_tokens": input, "output_tokens": output,
                                             "cost_micros": cost]))
            ])
        }
        // R01: an event whose generation is not current is a no-op.
        if let generation = generation(of: event), !isCurrent(generation, in: context) {
            return VoiceTransition(context: context)
        }

        var b = Builder(context: context)
        if reduceInterrupt(&b, event, env: env) { return b.transition }
        if reduceGlobal(&b, event, env: env) { return b.transition }
        switch b.context.state {
        case .idle: reduceIdle(&b, event, env: env)
        case .armed: reduceArmed(&b, event)
        case .listening: reduceListening(&b, event, env: env)
        case .transcribing: reduceTranscribing(&b, event, env: env)
        case .review: reduceReview(&b, event, env: env)
        case .awaitingApproval: reduceAwaitingApproval(&b, event, env: env)
        case .thinking, .acting: reduceAgentBusy(&b, event, env: env)
        case .speaking: reduceSpeaking(&b, event, env: env)
        case .error: reduceError(&b, event, env: env)
        case .paused: reducePaused(&b, event)
        }
        return b.transition
    }

    // MARK: - Global rules

    private static func reduceGlobal(_ b: inout Builder, _ event: VoiceEvent,
                                     env: VoiceReducerEnv) -> Bool {
        switch event {
        case .featureDisabled: // R02 (two overrides on STOP_ALL)
            if b.context.state == .idle && b.context.interrupt == nil { return true }
            b.stopAll(.userStop, forceIdle: true, auditDecision: "disabled")
            return true
        case .stopAllRequested:
            if b.context.state == .paused { return true } // R03
            if b.context.state == .idle && b.context.interrupt == nil { // R03a
                b.effects.append(.audit(AuditDraft(kind: .stop, decision: "user_stop", outcome: "idle")))
                return true
            }
            b.stopAll(.userStop) // R03b
            return true
        case .screenLocked:
            switch b.context.state {
            case .armed, .listening, .transcribing:
                b.cancelCapture("locked") // R04
            case .review:
                b.toIdle([.audit(AuditDraft(kind: .cancel, lane: b.context.lane,
                                            decision: "locked"))]) // R04
            case .awaitingApproval:
                b.expireApproval(decision: "locked") // R04a
            default:
                break // R04b: a running agent turn is not killed by a lock
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Interrupt capture (R100-R104)

    private static func reduceInterrupt(_ b: inout Builder, _ event: VoiceEvent,
                                        env: VoiceReducerEnv) -> Bool {
        if case .talkPressed = event { // R100
            if b.context.state.isAgentBusy, b.context.lane == .hermes,
               b.context.interrupt == nil, env.voiceEnabled, !env.screenLocked {
                b.context.counter += 1
                let generation = b.context.counter
                b.context.interrupt = InterruptCapture(generation: generation, endedByUser: false)
                b.effects.append(.startCapture(generation: generation, mode: .hold))
                return true
            }
        }
        guard let interrupt = b.context.interrupt else { return false }
        switch event {
        case .captureStarted(let generation): // R101
            guard generation == interrupt.generation else { return false }
            b.effects.append(.cue(.captureStart))
            b.effects.append(.startTimer(.listenCap, generation: generation,
                                         seconds: VoiceTiming.toggleListenCap))
            return true
        case .talkReleased(let held): // R102
            if held >= VoiceTiming.holdThreshold {
                b.context.interrupt?.endedByUser = true
                b.effects.append(.endCapture(generation: interrupt.generation))
                b.effects.append(.cue(.captureEnd))
            } else {
                b.effects.append(.cancelCapture(generation: interrupt.generation))
                b.context.interrupt = nil
            }
            return true
        case .finalTranscript(let text, let generation): // R103
            guard generation == interrupt.generation else { return false }
            b.context.interrupt = nil
            let route = IntentRouter.route(text, context: RouterContext(hermesLaneAvailable: false,
                                                                        agentBusy: true))
            switch route {
            case .emergencyStop:
                b.stopAll(.spokenAbort)
            case .cancelTurn:
                b.toIdle([.cancelAgentTurn,
                          .audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "spoken"))])
            default:
                break // any other transcript is ignored
            }
            return true
        case .captureFailed(_, let generation): // R104
            guard generation == interrupt.generation else { return false }
            b.context.interrupt = nil
            b.effects.append(.cancelCapture(generation: generation))
            return true
        case .timerElapsed(.listenCap, let generation): // R104
            guard generation == interrupt.generation else { return false }
            b.effects.append(.endCapture(generation: generation))
            return true
        default:
            return false
        }
    }

    // MARK: - Per-state rules

    private static func reduceIdle(_ b: inout Builder, _ event: VoiceEvent, env: VoiceReducerEnv) {
        switch event {
        case .talkPressed, .toggleTalk:
            if !env.voiceEnabled { return } // R12
            if env.screenLocked { // R13
                b.newID()
                b.clearFlow()
                b.toError(.screenLocked, [.audit(AuditDraft(kind: .lock, decision: "blocked"))])
                return
            }
            b.newFlow(event == .talkPressed ? .hold : .toggle, []) // R10 / R11
        default:
            return // R14
        }
    }

    private static func reduceArmed(_ b: inout Builder, _ event: VoiceEvent) {
        switch event {
        case .captureStarted: // R20
            b.context.state = .listening
            b.effects.append(.cue(.captureStart))
            b.effects.append(.startTimer(.listenCap, generation: b.context.generation,
                                         seconds: b.context.captureMode == .hold
                                             ? VoiceTiming.holdListenCap : VoiceTiming.toggleListenCap))
        case .talkReleased(let held): // R21 / R22
            guard b.context.captureMode == .hold else { return }
            if held >= VoiceTiming.holdThreshold {
                b.cancelCapture("released_early")
            } else {
                b.context.captureMode = .toggle
            }
        case .captureFailed(let failure, _): // R23
            b.toError(failure, [.cancelCapture(generation: b.context.generation)])
        case .cancelRequested: // R24
            b.cancelCapture("cancel")
        case .partialTranscript(let text, _): // R30 (also armed)
            b.context.partialTranscript = bounded(text)
        default:
            return
        }
    }

    private static func reduceListening(_ b: inout Builder, _ event: VoiceEvent,
                                        env: VoiceReducerEnv) {
        switch event {
        case .partialTranscript(let text, _): // R30
            b.context.partialTranscript = bounded(text)
        case .talkReleased(let held): // R31 / R32
            guard b.context.captureMode == .hold else { return }
            if held >= VoiceTiming.holdThreshold {
                b.endByUser()
            } else {
                b.context.captureMode = .toggle
                b.effects.append(.startTimer(.listenCap, generation: b.context.generation,
                                             seconds: VoiceTiming.toggleListenCap))
            }
        case .toggleTalk: // R33
            b.endByUser()
        case .talkPressed: // R33 (only in toggle mode; hold mode is key repeat)
            if b.context.captureMode == .toggle { b.endByUser() }
        case .timerElapsed(.listenCap, _): // R34
            b.endByCap()
        case .finalTranscript(let text, _): // R35
            b.handleFinal(text,
                          prefix: [.endCapture(generation: b.context.generation), .cue(.captureEnd)],
                          env: env)
        case .captureFailed(let failure, _): // R36
            b.toError(failure, [.cancelCapture(generation: b.context.generation)])
        case .cancelRequested: // R37
            b.cancelCapture("cancel")
        default:
            return
        }
    }

    private static func reduceTranscribing(_ b: inout Builder, _ event: VoiceEvent,
                                           env: VoiceReducerEnv) {
        switch event {
        case .partialTranscript(let text, _): // R30 (also transcribing)
            b.context.partialTranscript = bounded(text)
        case .finalTranscript(let text, _): // R40
            b.handleFinal(text, prefix: [], env: env)
        case .timerElapsed(.finalWatchdog, _): // R41
            b.toError(.timeout, [.cancelCapture(generation: b.context.generation)])
        case .captureFailed(let failure, _): // R42
            b.toError(failure, [.cancelCapture(generation: b.context.generation)])
        case .cancelRequested: // R43
            b.cancelCapture("cancel")
        default:
            return
        }
    }

    private static func reduceReview(_ b: inout Builder, _ event: VoiceEvent,
                                     env: VoiceReducerEnv) {
        switch event {
        case .timerElapsed(.review, _): // R60-R64
            b.reviewElapsed(env: env)
        case .cancelRequested: // R65
            b.toIdle([.audit(AuditDraft(kind: .cancel, lane: b.context.lane, decision: "review"))])
        default:
            return
        }
    }

    private static func reduceAwaitingApproval(_ b: inout Builder, _ event: VoiceEvent,
                                               env: VoiceReducerEnv) {
        switch event {
        case .approveRequested(let nonce): // R70-R74
            b.approve(nonce, env: env)
        case .denyRequested(let nonce): // R75-R77
            b.deny(nonce)
        case .timerElapsed(.approval, _): // R78
            b.expireApproval(decision: "expired")
        case .timerElapsed(.turnBudget, _): // R89
            b.toError(.timeout, [.cancelAgentTurn])
        case .cancelRequested: // R79
            b.cancelApproval()
        case .agent(let agentEvent, _):
            guard b.context.lane == .hermes else { return }
            switch agentEvent {
            case .approvalNeeded(let request): // R91
                b.effects.append(.respondToApproval(nonce: request.nonce, allow: false))
                b.effects.append(.audit(AuditDraft(kind: .denial, lane: .hermes,
                                                   tier: request.tier, decision: "second_request")))
            case .toolActivity(let kind): // R92
                b.tripwire(kind)
            case .finished(let summary): // R86
                b.finish(summary, env: env)
            case .failed(let failure): // R87
                b.toError(failure)
            case .partial, .status, .usage:
                return
            }
        default:
            return
        }
    }

    private static func reduceAgentBusy(_ b: inout Builder, _ event: VoiceEvent,
                                        env: VoiceReducerEnv) {
        switch event {
        case .timerElapsed(.turnBudget, _): // R89
            b.toError(.timeout, [.cancelAgentTurn])
        case .cancelRequested: // R90 (thinking/acting); R97 is a no-op for local
            if b.context.lane == .hermes {
                b.toIdle([.cancelAgentTurn,
                          .audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "turn"))])
            }
        case .localExecutionFinished(let result, _): // R95 / R96
            guard b.context.state == .acting, b.context.lane == .local else { return }
            switch result {
            case .success(let spoken):
                if env.speechAllowed, let spoken, !spoken.isEmpty {
                    b.finish(spoken, env: env)
                } else {
                    b.toIdle([.cue(.done),
                              .audit(AuditDraft(kind: .execute, lane: .local,
                                                decision: "finished", outcome: "ok"))])
                }
            case .failure(let failure):
                b.toError(failure, [.audit(AuditDraft(kind: .execute, lane: .local,
                                                      decision: "finished",
                                                      outcome: failure.code))])
            }
        case .agent(let agentEvent, _): // R80-R88
            guard b.context.lane == .hermes else { return }
            switch agentEvent {
            case .partial(let text): // R80
                b.context.reply = String(text.prefix(VoiceLimits.maxReplyCharacters))
            case .toolActivity(let kind): // R82 / R83
                b.toolActivity(kind)
            case .approvalNeeded(let request): // R84 / R85
                b.approvalNeeded(request, env: env)
            case .finished(let summary): // R86
                b.finish(summary, env: env)
            case .failed(let failure): // R87
                b.toError(failure)
            case .status, .usage: // R81 / R88 (usage handled globally)
                return
            }
        default:
            return
        }
    }

    private static func reduceSpeaking(_ b: inout Builder, _ event: VoiceEvent,
                                       env: VoiceReducerEnv) {
        switch event {
        case .speechFinished, .timerElapsed(.replyDisplay, _): // R110
            b.toIdle([])
        case .talkPressed: // R111
            if b.canStartFlow(env: env) { b.newFlow(.hold, [.stopSpeaking]) }
        case .toggleTalk: // R111
            if b.canStartFlow(env: env) { b.newFlow(.toggle, [.stopSpeaking]) }
        case .cancelRequested: // R112
            b.toIdle([.stopSpeaking])
        default:
            return
        }
    }

    private static func reduceError(_ b: inout Builder, _ event: VoiceEvent,
                                    env: VoiceReducerEnv) {
        switch event {
        case .timerElapsed(.errorDisplay, _): // R120
            b.toIdle([])
        case .talkPressed: // R121
            if b.canStartFlow(env: env) { b.newFlow(.hold, []) }
        case .toggleTalk: // R121
            if b.canStartFlow(env: env) { b.newFlow(.toggle, []) }
        case .cancelRequested: // R122
            b.toIdle([])
        default:
            return
        }
    }

    private static func reducePaused(_ b: inout Builder, _ event: VoiceEvent) {
        switch event {
        case .resumeRequested: // R130
            b.toIdle([.audit(AuditDraft(kind: .resume, decision: "resume"))])
        default:
            return // R131 / R132
        }
    }

    // MARK: - Generation helpers

    private static func generation(of event: VoiceEvent) -> Int? {
        switch event {
        case .captureStarted(let generation): return generation
        case .captureFailed(_, let generation): return generation
        case .partialTranscript(_, let generation): return generation
        case .finalTranscript(_, let generation): return generation
        case .timerElapsed(_, let generation): return generation
        case .localExecutionFinished(_, let generation): return generation
        case .speechFinished(let generation): return generation
        case .agent(_, let generation): return generation
        default: return nil
        }
    }

    private static func isCurrent(_ generation: Int, in context: VoiceContext) -> Bool {
        if generation == context.generation { return true }
        if let interrupt = context.interrupt, interrupt.generation == generation { return true }
        return false
    }

    // MARK: - Procedures

    private struct Builder {
        var context: VoiceContext
        var effects: [VoiceEffect] = []

        init(context: VoiceContext) { self.context = context }

        var transition: VoiceTransition {
            VoiceTransition(context: context, effects: effects)
        }

        func canStartFlow(env: VoiceReducerEnv) -> Bool {
            env.voiceEnabled && !env.screenLocked
        }

        mutating func newID() {
            context.counter += 1
            context.generation = context.counter
        }

        mutating func clearFlow() {
            context.partialTranscript = ""
            context.finalTranscript = ""
            context.route = nil
            context.pending = nil
            context.pendingIntent = nil
            context.failure = nil
            context.pauseReason = nil
            context.reply = ""
            context.steps = []
            context.stepsStarted = 0
            context.approvedToolStarts = 0
            context.lane = nil
            context.captureEndedByUser = false
        }

        mutating func dropInterrupt() {
            if let interrupt = context.interrupt {
                effects.append(.cancelCapture(generation: interrupt.generation))
                context.interrupt = nil
            }
        }

        mutating func toIdle(_ extra: [VoiceEffect] = []) {
            effects = extra
            dropInterrupt()
            newID()
            clearFlow()
            context.state = .idle
        }

        mutating func toError(_ failure: VoiceFailure, _ extra: [VoiceEffect] = []) {
            effects = extra
            dropInterrupt()
            context.state = .error
            context.failure = failure
            context.pending = nil
            context.pendingIntent = nil
            context.partialTranscript = ""
            effects.append(.cue(.error))
            effects.append(.startTimer(.errorDisplay, generation: context.generation,
                                       seconds: VoiceTiming.errorDisplay))
            effects.append(.audit(AuditDraft(kind: .error, lane: context.lane,
                                             decision: "failure", outcome: failure.code)))
        }

        mutating func stopAll(_ reason: PauseReason, forceIdle: Bool = false,
                              auditDecision: String? = nil) {
            let wasBusy = context.state.isAgentBusy && context.lane == .hermes
            if context.state == .armed || context.state == .listening
                || context.state == .transcribing {
                effects.append(.cancelCapture(generation: context.generation))
            }
            if let interrupt = context.interrupt {
                effects.append(.cancelCapture(generation: interrupt.generation))
            }
            if context.state == .speaking { effects.append(.stopSpeaking) }
            if wasBusy { effects.append(.stopAgentHard) }
            effects.append(.audit(AuditDraft(kind: .stop, lane: context.lane,
                                             decision: auditDecision ?? auditName(reason),
                                             outcome: wasBusy ? "hard" : "soft")))
            context.interrupt = nil
            newID()
            clearFlow()
            if wasBusy && !forceIdle {
                context.state = .paused
                context.pauseReason = reason
            } else {
                context.state = .idle
                context.pauseReason = nil
            }
        }

        mutating func cancelCapture(_ auditDecision: String) {
            let generation = context.generation
            let lane = context.lane
            toIdle([.cancelCapture(generation: generation),
                    .audit(AuditDraft(kind: .cancel, lane: lane, decision: auditDecision))])
        }

        mutating func endByUser() {
            context.state = .transcribing
            context.captureEndedByUser = true
            appendEndCapture()
        }

        mutating func endByCap() {
            context.state = .transcribing
            appendEndCapture()
        }

        private mutating func appendEndCapture() {
            effects.append(.endCapture(generation: context.generation))
            effects.append(.cue(.captureEnd))
            effects.append(.startTimer(.finalWatchdog, generation: context.generation,
                                       seconds: VoiceTiming.finalWatchdog))
        }

        mutating func newFlow(_ mode: CaptureMode, _ extra: [VoiceEffect]) {
            effects = extra
            newID()
            clearFlow()
            context.captureMode = mode
            context.state = .armed
            effects.append(.startCapture(generation: context.generation, mode: mode))
        }

        mutating func enterReview(_ route: RouteDecision, _ lane: VoiceLane,
                                  _ prefix: [VoiceEffect]) {
            let generation = context.generation
            effects = prefix
            context.state = .review
            context.route = route
            context.lane = lane
            effects.append(.cue(.commit))
            effects.append(.startTimer(.review, generation: generation,
                                       seconds: VoiceTiming.reviewWindow))
            effects.append(.audit(AuditDraft(kind: .route, lane: lane, decision: "pending",
                                             transcript: context.finalTranscript)))
        }

        mutating func finish(_ text: String, env: VoiceReducerEnv) {
            let generation = context.generation
            let lane = context.lane
            context.reply = String(text.prefix(VoiceLimits.maxReplyCharacters))
            context.pending = nil
            context.pendingIntent = nil
            dropInterrupt()
            context.state = .speaking
            if env.speechAllowed && !context.reply.isEmpty {
                effects.append(.speak(context.reply, generation: generation))
            } else {
                effects.append(.startTimer(.replyDisplay, generation: generation,
                                           seconds: VoiceTiming.replyDisplay))
            }
            effects.append(.cue(.done))
            effects.append(.audit(AuditDraft(kind: .execute, lane: lane, decision: "finished",
                                             outcome: "ok")))
        }

        mutating func handleFinal(_ text: String, prefix: [VoiceEffect], env: VoiceReducerEnv) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            context.finalTranscript = bounded(trimmed)
            context.partialTranscript = ""
            if trimmed.isEmpty { // R50
                toError(.noSpeech, prefix)
                return
            }
            if env.screenLocked { // R51
                toError(.screenLocked, prefix + [.audit(AuditDraft(kind: .lock, decision: "blocked"))])
                return
            }
            let route = IntentRouter.route(trimmed, context: RouterContext(
                hermesLaneAvailable: env.hermesLaneReady, agentBusy: false))
            switch route {
            case .emergencyStop: // R52
                effects = prefix
                stopAll(.spokenAbort)
            case .reject(let reason): // R53
                toError(.rejected(reason), prefix + [.audit(AuditDraft(kind: .route, decision: "reject",
                                                                      outcome: reason.rawValue,
                                                                      transcript: trimmed))])
            case .remote: // R54 / R55 / R56
                if !context.captureEndedByUser {
                    toError(.rejected(.needsUserRelease), prefix)
                    return
                }
                if env.hermesTurnsRemainingToday <= 0 {
                    toError(.dailyCapReached, prefix)
                    return
                }
                enterReview(route, .hermes, prefix)
            case .local: // R57
                enterReview(route, .local, prefix)
            case .cancelTurn: // R58 (defensive)
                toIdle(prefix)
            }
        }

        mutating func reviewElapsed(env: VoiceReducerEnv) {
            guard let route = context.route else { // R64
                toIdle([])
                return
            }
            switch route {
            case .local(let intent): // R60 / R61 / R62
                reviewLocal(intent, env: env)
            case .remote(let utterance): // R63
                if case .limited = context.rate.tryConsume(tier: .t1, now: env.now) {
                    toError(.rateLimited)
                    return
                }
                context.lane = .hermes
                context.state = .thinking
                context.steps = []
                context.stepsStarted = 0
                effects.append(.submitToAgent(utterance: utterance, generation: context.generation))
                effects.append(.startTimer(.turnBudget, generation: context.generation,
                                           seconds: VoiceTiming.agentTurnBudget))
                effects.append(.audit(AuditDraft(kind: .submit, lane: .hermes, tier: .t1,
                                                 decision: "allow")))
            default: // R64
                toIdle([])
            }
        }

        private mutating func reviewLocal(_ intent: LocalIntent, env: VoiceReducerEnv) {
            let tier = ConfirmationPolicy.tier(of: intent)
            switch ConfirmationPolicy.decide(tier: tier,
                                             secondFactorAvailable: env.secondFactorAvailable) {
            case .allow: // R60
                if tier >= .t1, case .limited = context.rate.tryConsume(tier: tier, now: env.now) {
                    toError(.rateLimited, [.audit(AuditDraft(kind: .denial, lane: .local,
                                                             tier: tier, decision: "rate_limited"))])
                    return
                }
                context.state = .acting
                effects.append(.execute(intent, generation: context.generation))
                effects.append(.audit(AuditDraft(kind: .execute, lane: .local, tier: tier,
                                                 decision: "allow")))
            case .confirm: // R61
                let request = ConfirmationRequest(nonce: env.freshNonce, tier: tier, source: .local,
                                                  summary: intent.summary, literal: intent.summary)
                context.pending = request
                context.pendingIntent = intent
                context.state = .awaitingApproval
                effects.append(.cue(.needsConfirmation))
                effects.append(.startTimer(.approval, generation: context.generation,
                                           seconds: VoiceTiming.approvalTimeout))
                effects.append(.audit(AuditDraft(kind: .approval, lane: .local, tier: tier,
                                                 decision: "requested")))
            case .deny(let reason): // R62
                toError(.denied(reason), [.audit(AuditDraft(kind: .denial, lane: .local, tier: tier,
                                                            decision: reason.rawValue))])
            }
        }

        // R70-R74
        mutating func approve(_ nonce: String, env: VoiceReducerEnv) {
            if env.screenLocked { return } // R70
            guard let pending = context.pending, nonce == pending.nonce else { // R71
                effects.append(.audit(AuditDraft(kind: .approval, decision: "nonce_mismatch")))
                return
            }
            guard pending.canApprove else { // R72
                effects.append(.audit(AuditDraft(kind: .approval, tier: pending.tier,
                                                 decision: "blocked")))
                return
            }
            if let intent = context.pendingIntent { // R73 local
                let tier = pending.tier
                if case .limited = context.rate.tryConsume(tier: tier, now: env.now) {
                    toError(.rateLimited)
                    return
                }
                context.pending = nil
                context.pendingIntent = nil
                context.state = .acting
                effects.append(.cue(.approved))
                effects.append(.execute(intent, generation: context.generation))
                effects.append(.audit(AuditDraft(kind: .approval, lane: .local, tier: tier,
                                                 decision: "approved")))
            } else { // R74 agent card
                let tier = pending.tier
                if tier >= .t2, case .limited = context.rate.tryConsume(tier: tier, now: env.now) {
                    effects.append(.respondToApproval(nonce: nonce, allow: false))
                    effects.append(.audit(AuditDraft(kind: .denial, lane: .hermes, tier: tier,
                                                     decision: "rate_limited")))
                    context.pending = nil
                    context.state = .acting
                    return
                }
                if tier >= .t2 { context.approvedToolStarts += 1 }
                effects.append(.respondToApproval(nonce: nonce, allow: true))
                effects.append(.cue(.approved))
                effects.append(.audit(AuditDraft(kind: .approval, lane: .hermes, tier: tier,
                                                 decision: "approved")))
                context.pending = nil
                context.state = .acting
            }
        }

        // R75-R77
        mutating func deny(_ nonce: String) {
            guard let pending = context.pending, nonce == pending.nonce else {
                effects.append(.audit(AuditDraft(kind: .approval, decision: "nonce_mismatch")))
                return
            }
            if context.pendingIntent != nil { // R76
                toIdle([.audit(AuditDraft(kind: .denial, lane: .local, tier: pending.tier,
                                          decision: "denied"))])
            } else { // R77
                effects.append(.respondToApproval(nonce: nonce, allow: false))
                effects.append(.audit(AuditDraft(kind: .denial, lane: .hermes, tier: pending.tier,
                                                 decision: "denied")))
                context.pending = nil
                context.state = .acting
            }
        }

        // R78 (timer "expired" / lock "locked"); also R04a
        mutating func expireApproval(decision: String) {
            guard let pending = context.pending else {
                toIdle([])
                return
            }
            if context.pendingIntent != nil {
                toIdle([.audit(AuditDraft(kind: .denial, lane: .local, tier: pending.tier,
                                          decision: decision))])
            } else {
                effects.append(.respondToApproval(nonce: pending.nonce, allow: false))
                effects.append(.audit(AuditDraft(kind: .denial, lane: .hermes, tier: pending.tier,
                                                 decision: decision)))
                context.pending = nil
                context.state = .acting
            }
        }

        // R79
        mutating func cancelApproval() {
            guard let pending = context.pending else {
                toIdle([])
                return
            }
            if context.pendingIntent != nil {
                toIdle([.audit(AuditDraft(kind: .denial, lane: .local, tier: pending.tier,
                                          decision: "cancel"))])
            } else {
                toIdle([.respondToApproval(nonce: pending.nonce, allow: false),
                        .cancelAgentTurn,
                        .audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "approval"))])
            }
        }

        // R82 / R83
        mutating func toolActivity(_ kind: String) {
            let tier = ToolTierTable.tier(forTool: kind)
            if tier <= .t1 || (tier == .t2 && context.approvedToolStarts > 0) {
                if tier == .t2 { context.approvedToolStarts -= 1 }
                context.steps.append(VoiceStep(id: context.stepsStarted,
                                               kind: String(kind.prefix(40))))
                context.stepsStarted += 1
                context.state = .acting
                if context.stepsStarted > VoiceLimits.maxAgentSteps {
                    toError(.stepBudgetExceeded, [.cancelAgentTurn])
                }
            } else {
                tripwire(kind)
            }
        }

        // R83 / R92
        mutating func tripwire(_ kind: String) {
            let tier = ToolTierTable.tier(forTool: kind)
            let label = String(kind.prefix(40))
            effects.append(.stopAgentHard)
            effects.append(.cue(.error))
            effects.append(.audit(AuditDraft(kind: .tripwire, lane: .hermes, tier: tier,
                                             decision: "tripwire", outcome: label)))
            dropInterrupt()
            newID()
            clearFlow()
            context.state = .paused
            context.pauseReason = .tripwire(label)
            context.failure = .tripwire(tool: label)
        }

        // R84 / R85
        mutating func approvalNeeded(_ request: ConfirmationRequest, env: VoiceReducerEnv) {
            let autoDeny = !request.risk.intersection(.autoDeny).isEmpty
                || request.tier >= .t4
                || (request.tier == .t3 && !env.secondFactorAvailable)
            if autoDeny {
                effects.append(.respondToApproval(nonce: request.nonce, allow: false))
                effects.append(.audit(AuditDraft(kind: .denial, lane: .hermes, tier: request.tier,
                                                 decision: "auto_deny")))
            } else {
                context.pending = request
                context.pendingIntent = nil
                context.state = .awaitingApproval
                effects.append(.cue(.needsConfirmation))
                effects.append(.startTimer(.approval, generation: context.generation,
                                           seconds: VoiceTiming.approvalTimeout))
                effects.append(.audit(AuditDraft(kind: .approval, lane: .hermes, tier: request.tier,
                                                 decision: "requested")))
            }
        }
    }
}

private func auditName(_ reason: PauseReason) -> String {
    switch reason {
    case .userStop: return "user_stop"
    case .spokenAbort: return "spoken_abort"
    case .tripwire: return "tripwire"
    }
}

private func bounded(_ text: String) -> String {
    String(text.prefix(VoiceLimits.maxTranscriptDisplayCharacters))
}
