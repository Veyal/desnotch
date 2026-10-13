import AppKit
import Combine
import Foundation

/// Owns the reducer's context, runs its effects, and publishes presentation to `VoiceSessionModel`.
/// One backend instance for the process lifetime: Part A passes `NullBackend`.
@MainActor
final class VoiceCoordinator {
    private let model: VoiceSessionModel
    private let settings: SettingsStore
    private let clock: VoiceClock
    private let recognizer: SpeechRecognizing
    private let synthesizer: SpeechSynthesizing
    private let executor: LocalExecuting
    private let backend: AgentBackend
    private let terminateAgentNow: @Sendable () -> Void
    private let audit: AuditLogging
    private let makeKeys: @MainActor (VoiceHotkeyChoice) -> PushToTalkSource
    private let lock: LockStateProviding
    private let ducker: MediaDucking
    private let permissions: VoicePermissionProviding
    private let cues: VoiceCuePlaying
    private let timers: VoiceTimerScheduling
    private var dailyTurns: DailyTurnCounter
    private let isPrivacyMode: @MainActor () -> Bool
    private let makeNonce: () -> String
    private let debugTypingEnabled: Bool
    /// Opt-in AI providers (OpenAI-compatible speech-to-text and reply voice, and the
    /// OpenAI-compatible or Anthropic answers backend). Nil: on-device and Hermes only.
    private let ai: VoiceAIProviders?

    private(set) var context = VoiceContext()

    private var started = false
    private var stopped = false
    private var voiceEnabledState: Bool
    private var laneEnabled: Bool
    private var hotkeyChoice: VoiceHotkeyChoice
    /// Fail closed until an event that consults the lock reads a fresh value.
    private var lastScreenLocked = true
    private var auditWritable = true
    private var reviewDeadline: Date?
    private var appliedCancelArmed: Bool?

    private var keys: PushToTalkSource?
    private var keyTask: Task<Void, Never>?
    private var lockTask: Task<Void, Never>?
    private var laneCheckTask: Task<Void, Never>?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    private var captureGeneration = 0
    /// The recognizer of the newest capture (on-device or cloud), chosen at capture start.
    private var activeRecognizer: SpeechRecognizing
    /// Generations whose capture uses the cloud recognizer (its final watchdog is stretched,
    /// and its audio is only uploaded when the user ended the capture).
    private var cloudCaptures: Set<Int> = []
    /// The backend that owns the current agent turn, so Stop/Cancel reach it even if the
    /// answers provider is switched mid-turn.
    private var turnBackend: AgentBackend?
    private var levelHistory: [Float] = []
    private var duckedThisCapture = false
    private var typedFlow = false
    private var typedStartPending = false

    private var pendingEvents: [VoiceEvent] = []
    private var isDispatching = false

    private var timerHandles: [TimerKey: VoiceTimerHandle] = [:]
    private var recognitionTasks: [RecognitionTaskBox] = []
    private var auditChain: Task<Void, Never>?
    private var stopChain: Task<Void, Never>?
    private var laneCheckGeneration = 0

    init(
        model: VoiceSessionModel,
        settings: SettingsStore,
        clock: VoiceClock,
        recognizer: SpeechRecognizing,
        synthesizer: SpeechSynthesizing,
        executor: LocalExecuting,
        backend: AgentBackend,
        terminateAgentNow: @escaping @Sendable () -> Void = {},
        audit: AuditLogging,
        makeKeys: @escaping @MainActor (VoiceHotkeyChoice) -> PushToTalkSource,
        lock: LockStateProviding,
        ducker: MediaDucking,
        permissions: VoicePermissionProviding,
        cues: VoiceCuePlaying,
        timers: VoiceTimerScheduling,
        dailyTurns: DailyTurnCounter,
        isPrivacyMode: @escaping @MainActor () -> Bool,
        makeNonce: @escaping () -> String = { UUID().uuidString },
        ai: VoiceAIProviders? = nil,
        debugTypingEnabled: Bool
    ) {
        self.model = model
        self.settings = settings
        self.clock = clock
        self.recognizer = recognizer
        self.synthesizer = synthesizer
        self.executor = executor
        self.backend = backend
        self.terminateAgentNow = terminateAgentNow
        self.audit = audit
        self.makeKeys = makeKeys
        self.lock = lock
        self.ducker = ducker
        self.permissions = permissions
        self.cues = cues
        self.timers = timers
        self.dailyTurns = dailyTurns
        self.isPrivacyMode = isPrivacyMode
        self.makeNonce = makeNonce
        self.debugTypingEnabled = debugTypingEnabled
        self.ai = ai
        activeRecognizer = recognizer
        voiceEnabledState = settings.voiceEnabled
        laneEnabled = settings.voiceHermesLane
        hotkeyChoice = settings.voiceHotkey
    }

    /// Idempotent. Applies the current settings once, then observes later changes.
    func start() {
        guard !started, !stopped else { return }
        started = true
        voiceEnabledState = settings.voiceEnabled
        laneEnabled = settings.voiceHermesLane
        hotkeyChoice = settings.voiceHotkey
        installActions()
        if voiceEnabledState {
            startVoice()
        }
        subscribeToSettings()
    }

    /// App termination. Synchronous and idempotent: no reducer pass and no async work.
    func stop() {
        if stopped { return }
        stopped = true
        cancellables.removeAll()
        for box in recognitionTasks {
            box.task?.cancel()
        }
        recognitionTasks.removeAll()
        cancelAllTimers()
        keyTask?.cancel()
        keyTask = nil
        lockTask?.cancel()
        lockTask = nil
        laneCheckTask?.cancel()
        laneCheckTask = nil
        removeActivityObserver()
        keys?.stop()
        recognizer.cancel()
        synthesizer.stop()
        ai?.recognizer.cancel()
        ai?.synthesizer.stop()
        ducker.restore()
        duckedThisCapture = false
        terminateAgentNow()
    }

    func dispatch(_ event: VoiceEvent) {
        if stopped { return }
        pendingEvents.append(event)
        if isDispatching { return }
        isDispatching = true
        while !pendingEvents.isEmpty {
            if stopped {
                pendingEvents.removeAll()
                break
            }
            let event = pendingEvents.removeFirst()
            step(event)
        }
        isDispatching = false
    }

    func submitTyped(_ text: String) {
        guard debugTypingEnabled, context.state == .idle, voiceEnabledState, !stopped else { return }
        typedFlow = true
        typedStartPending = true
        dispatch(.talkPressed)
        typedStartPending = false
        guard keepsTypedFlow else { return }
        let generation = context.generation
        dispatch(.captureStarted(generation: generation))
        guard keepsTypedFlow else { return }
        dispatch(.talkReleased(heldSeconds: 1.0))
        guard keepsTypedFlow else { return }
        dispatch(.finalTranscript(text, generation: generation))
    }

    /// The reducer reads the lock only for these four events.
    static func consultsLock(_ event: VoiceEvent) -> Bool {
        switch event {
        case .talkPressed, .toggleTalk, .finalTranscript, .approveRequested:
            return true
        default:
            return false
        }
    }

    private var keepsTypedFlow: Bool {
        context.state != .idle && context.state != .error && context.state != .paused
    }

    private struct TimerKey: Hashable {
        var kind: VoiceTimerKind
        var generation: Int
    }

    // MARK: - Dispatch

    private func step(_ event: VoiceEvent) {
        let reapIdle = shouldReapOnIdleStop(event)
        let transition = VoiceReducer.reduce(context, event, env: makeEnvironment(for: event))
        context = transition.context
        // Write this transition's audit records before any action they authorize.
        let audits = transition.effects.filter { if case .audit = $0 { return true }; return false }
        let rest = transition.effects.filter { if case .audit = $0 { return false }; return true }
        for effect in audits { perform(effect) }
        for effect in rest { perform(effect) }
        if reapIdle { reapIdleAgent() }
        if !keepsTypedFlow {
            typedFlow = false
            typedStartPending = false
        }
        publish()
        cancelStaleTimers()
    }

    private func makeEnvironment(for event: VoiceEvent) -> VoiceReducerEnv {
        if Self.consultsLock(event) {
            lastScreenLocked = lock.isLocked
        }
        let laneReady = laneEnabled
            && model.hermesLaneStatus == .ready
            && model.hotkeyStatus == .active
        return VoiceReducerEnv(
            now: clock.now(),
            voiceEnabled: voiceEnabledState,
            screenLocked: lastScreenLocked,
            hermesLaneReady: laneReady,
            hermesTurnsRemainingToday: dailyTurns.remaining(now: clock.now()),
            speechAllowed: settings.voiceTTSEnabled && !isPrivacyMode(),
            secondFactorAvailable: false,
            freshNonce: makeNonce()
        )
    }

    private func publish() {
        let deadline = context.state == .review ? reviewDeadline : nil
        if context.state == .idle {
            model.setCloudActivity(false)
            cloudCaptures.removeAll()
        }
        if context.state == .idle || context.lane == nil {
            model.setAgentName(agentName)
        }
        model.apply(context, reviewDeadline: deadline)
        let armed = context.state != .idle && context.state != .paused
        guard let keys else {
            appliedCancelArmed = nil
            return
        }
        if appliedCancelArmed != armed {
            appliedCancelArmed = armed
            keys.setCancelKeyArmed(armed)
        }
    }

    // MARK: - Effects

    private func perform(_ effect: VoiceEffect) {
        switch effect {
        case .startCapture(let generation, _):
            startCapture(generation)
        case .endCapture(let generation):
            endCapture(generation)
        case .cancelCapture:
            cancelCapture()
        case .startTimer(let kind, let generation, let seconds):
            startTimer(kind, generation: generation, seconds: seconds)
        case .cue(let cue):
            cues.play(cue)
        case .execute(let intent, let generation):
            execute(intent, generation: generation)
        case .submitToAgent(let text, let generation):
            submitToAgent(text, generation: generation)
        case .respondToApproval(let nonce, let allow):
            respondToApproval(nonce: nonce, allow: allow)
        case .cancelAgentTurn:
            cancelAgentTurn()
        case .stopAgentHard:
            stopAgentHard()
        case .speak(let text, let generation):
            speak(text, generation: generation)
        case .stopSpeaking:
            synthesizer.stop()
            ai?.synthesizer.stop()
        case .audit(let draft):
            appendAudit(draft)
        }
    }

    private func startCapture(_ generation: Int) {
        let typed = typedStartPending
        typedStartPending = false
        typedFlow = typed
        rememberCapture(generation)
        duckedThisCapture = false
        if typed { return }
        let recognizer = recognizerForNewCapture(generation)
        let stream = recognizer.start(
            localeIdentifier: settings.voiceLocale,
            contextualStrings: VoiceLexicon.contextualStrings
        )
        let box = RecognitionTaskBox()
        let task = Task { @MainActor [weak self] in
            defer { self?.recognitionTasks.removeAll { $0 === box } }
            var sawTerminal = false
            for await event in stream {
                guard let self, !self.stopped else { return }
                if self.handleSpeech(event, generation: generation) {
                    sawTerminal = true
                }
            }
            guard let self, !self.stopped else { return }
            self.finishSpeech(generation: generation, sawTerminal: sawTerminal)
        }
        box.task = task
        recognitionTasks.append(box)
    }

    /// `captureGeneration` is the stale check for the newest main-flow capture. An interrupt
    /// capture must not rewrite it while that capture is still live, or the main consumer
    /// would drop its own events.
    private func rememberCapture(_ generation: Int) {
        let mainCaptureLive = context.state == .armed
            || context.state == .listening
            || context.state == .transcribing
        if !(generation == context.interrupt?.generation && mainCaptureLive) {
            captureGeneration = generation
        }
        levelHistory.removeAll()
    }

    private func acceptsSpeech(generation: Int) -> Bool {
        if context.interrupt?.generation == generation { return true }
        return generation == context.generation && generation == captureGeneration
    }

    /// Returns whether the event ended the capture (final or failure).
    private func handleSpeech(_ event: SpeechEvent, generation: Int) -> Bool {
        guard acceptsSpeech(generation: generation) else { return false }
        switch event {
        case .captureStarted:
            dispatch(.captureStarted(generation: generation))
            if settings.voiceDuckMedia && !duckedThisCapture {
                ducker.duck()
                duckedThisCapture = true
            }
            return false
        case .level(let level):
            levelHistory.append(level)
            if levelHistory.count > VoiceLimits.meterBars {
                levelHistory.removeFirst(levelHistory.count - VoiceLimits.meterBars)
            }
            model.setLevels(LevelMeter.bars(from: levelHistory))
            return false
        case .partial(let text):
            dispatch(.partialTranscript(text, generation: generation))
            return false
        case .final(let text):
            dispatch(.finalTranscript(text, generation: generation))
            restoreDuckIfNeeded()
            return true
        case .failed(let failure):
            dispatch(.captureFailed(failure, generation: generation))
            restoreDuckIfNeeded()
            return true
        }
    }

    private func finishSpeech(generation: Int, sawTerminal: Bool) {
        if !sawTerminal {
            let liveInterrupt = context.interrupt?.generation == generation
            let liveMain = context.generation == generation
                && (context.state == .armed || context.state == .listening)
            if liveMain || liveInterrupt {
                dispatch(.captureFailed(.unavailable(.recognizer), generation: generation))
            }
        }
        restoreDuckIfNeeded()
    }

    private func endCapture(_ generation: Int) {
        if typedFlow { return }
        if cloudCaptures.contains(generation) && !captureEndedByUser(generation) {
            // R54 applied to audio: a capture the cap timer ended is never uploaded.
            activeRecognizer.cancel()
            restoreDuckIfNeeded()
            dispatch(.captureFailed(.rejected(.needsUserRelease), generation: generation))
            return
        }
        activeRecognizer.endAudio()
        restoreDuckIfNeeded()
    }

    private func captureEndedByUser(_ generation: Int) -> Bool {
        if let interrupt = context.interrupt, interrupt.generation == generation {
            return interrupt.endedByUser
        }
        return context.captureEndedByUser
    }

    /// On-device by default; the cloud recognizer only when the user opted in.
    private func recognizerForNewCapture(_ generation: Int) -> SpeechRecognizing {
        if let ai, settings.voiceSpeechProvider == .openAICompatible {
            ai.config.update(VoiceAIConfig(settings: settings))
            cloudCaptures.insert(generation)
            model.setCloudActivity(true)
            activeRecognizer = ai.recognizer
        } else {
            activeRecognizer = recognizer
        }
        return activeRecognizer
    }

    private func cancelCapture() {
        if typedFlow { return }
        activeRecognizer.cancel()
        restoreDuckIfNeeded()
        levelHistory.removeAll()
        model.setLevels([])
    }

    private func restoreDuckIfNeeded() {
        if duckedThisCapture {
            duckedThisCapture = false
            ducker.restore()
        }
    }

    private func startTimer(_ kind: VoiceTimerKind, generation: Int, seconds: Double) {
        let key = TimerKey(kind: kind, generation: generation)
        if let existing = timerHandles.removeValue(forKey: key) {
            existing.cancel()
        }
        var seconds = seconds
        if kind == .finalWatchdog && cloudCaptures.contains(generation) {
            // The reducer's 5 s wait covers on-device recognition; an upload needs longer.
            seconds = max(seconds, VoiceAILimits.transcriptionWatchdog)
        }
        let handle = timers.schedule(after: seconds) { [weak self] in
            self?.dispatch(.timerElapsed(kind, generation: generation))
        }
        timerHandles[key] = handle
        if kind == .review {
            reviewDeadline = clock.now().addingTimeInterval(seconds)
        }
    }

    private func cancelStaleTimers() {
        let generation = context.generation
        let interrupt = context.interrupt?.generation
        let stale = timerHandles.keys.filter { key in
            key.generation != generation && key.generation != interrupt
        }
        for key in stale {
            timerHandles[key]?.cancel()
            timerHandles.removeValue(forKey: key)
        }
    }

    private func cancelAllTimers() {
        for handle in timerHandles.values {
            handle.cancel()
        }
        timerHandles.removeAll()
    }

    private func execute(_ intent: LocalIntent, generation: Int) {
        let needsAudit = ConfirmationPolicy.tier(of: intent) >= .t2
        if needsAudit && !auditWritable {
            dispatch(.localExecutionFinished(
                .failure(.executionFailed("audit_unwritable")),
                generation: generation
            ))
            return
        }
        let executor = self.executor
        let pendingAudit = auditChain
        Task { @MainActor [weak self] in
            await pendingAudit?.value
            guard let self, !self.stopped else { return }
            if needsAudit && !self.auditWritable {
                self.dispatch(.localExecutionFinished(
                    .failure(.executionFailed("audit_unwritable")),
                    generation: generation
                ))
                return
            }
            let result = await executor.execute(intent)
            guard !self.stopped else { return }
            self.dispatch(.localExecutionFinished(result, generation: generation))
        }
    }

    private func submitToAgent(_ text: String, generation: Int) {
        if !auditWritable {
            dispatch(.agent(.failed(.executionFailed("audit_unwritable")), generation: generation))
            return
        }
        if !laneEnabled {
            dispatch(.agent(.failed(.agentFailed("lane_off")), generation: generation))
            return
        }
        let backend = currentAgentBackend()
        turnBackend = backend
        let clock = self.clock
        let pendingAudit = auditChain
        Task { @MainActor [weak self] in
            await pendingAudit?.value
            guard let self, !self.stopped else { return }
            if !self.auditWritable {
                self.dispatch(.agent(.failed(.executionFailed("audit_unwritable")), generation: generation))
                return
            }
            if !self.laneEnabled {
                self.dispatch(.agent(.failed(.agentFailed("lane_off")), generation: generation))
                return
            }
            let stream = backend.submit(text)
            var sawTerminal = false
            for await event in stream {
                guard !self.stopped else { return }
                if case .status("started") = event {
                    self.dailyTurns.increment(now: clock.now())
                }
                if case .failed(.preflightRefused(let reason)) = event {
                    self.model.setHermesLaneStatus(.refused(reason))
                    self.appendAudit(AuditDraft(
                        kind: .preflight,
                        lane: .hermes,
                        decision: "refused",
                        outcome: reason.rawValue
                    ))
                }
                if case .finished = event { sawTerminal = true }
                if case .failed = event { sawTerminal = true }
                self.dispatch(.agent(event, generation: generation))
            }
            guard !self.stopped, !sawTerminal else { return }
            self.dispatch(.agent(.failed(.agentFailed("stream_ended")), generation: generation))
        }
    }

    private func respondToApproval(nonce: String, allow: Bool) {
        let backend = turnBackend ?? self.backend
        let pendingAudit = auditChain
        if !allow || !auditWritable {
            Task { @MainActor in
                await backend.respond(nonce: nonce, allow: false)
            }
            return
        }
        Task { @MainActor [weak self] in
            await pendingAudit?.value
            let writable = self?.auditWritable ?? false
            let effectiveAllow = allow && writable && self?.stopped != true
            await backend.respond(nonce: nonce, allow: effectiveAllow)
        }
    }

    private func cancelAgentTurn() {
        let backend = turnBackend ?? currentAgentBackend()
        Task { @MainActor in
            await backend.cancelTurn()
        }
    }

    private func stopAgentHard() {
        let generation = context.generation
        let backend = turnBackend ?? currentAgentBackend()
        let previous = stopChain
        stopChain = Task { @MainActor [weak self] in
            await previous?.value
            let report = await backend.emergencyStop()
            guard let self, self.context.state == .paused, self.context.generation == generation else { return }
            self.model.setSurvivors(report.survivors)
        }
    }

    private func speak(_ text: String, generation: Int) {
        var synthesizer = self.synthesizer
        if let ai, settings.voiceReplyProvider == .openAICompatible {
            ai.config.update(VoiceAIConfig(settings: settings))
            model.setCloudActivity(true)
            synthesizer = ai.synthesizer
        }
        let locale = settings.voiceLocale
        Task { @MainActor [weak self] in
            _ = await synthesizer.speak(text, localeIdentifier: locale)
            guard let self, !self.stopped else { return }
            self.dispatch(.speechFinished(generation: generation))
        }
    }

    private func appendAudit(_ draft: AuditDraft) {
        let previous = auditChain
        let audit = self.audit
        auditChain = Task { @MainActor [weak self] in
            await previous?.value
            let ok = await audit.append(draft)
            guard let self, !self.stopped else { return }
            self.auditWritable = ok
        }
    }

    // MARK: - Inputs

    private func installActions() {
        model.actions.stopAll = { [weak self] in self?.dispatch(.stopAllRequested) }
        model.actions.resume = { [weak self] in self?.dispatch(.resumeRequested) }
        model.actions.approve = { [weak self] nonce in self?.dispatch(.approveRequested(nonce: nonce)) }
        model.actions.deny = { [weak self] nonce in self?.dispatch(.denyRequested(nonce: nonce)) }
        model.actions.cancelReview = { [weak self] in self?.dispatch(.cancelRequested) }
        model.actions.toggleTalk = { [weak self] in self?.dispatch(.toggleTalk) }
        model.actions.submitTyped = { [weak self] text in
            guard let self, self.debugTypingEnabled else { return }
            self.submitTyped(text)
        }
        model.actions.refreshAgentLane = { [weak self] in
            guard let self, !self.stopped, self.laneEnabled, self.voiceEnabledState else { return }
            self.runLaneCheck()
        }
        model.actions.requestPermissions = { [weak self] in
            guard let self else { return }
            let permissions = self.permissions
            Task { @MainActor [weak self] in
                let status = await permissions.request()
                guard let self, !self.stopped else { return }
                self.model.setPermissions(status)
            }
        }
    }

    private func subscribeToSettings() {
        settings.$voiceEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.applyVoiceEnabled(value)
                }
            }
            .store(in: &cancellables)
        settings.$voiceHermesLane
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.applyHermesLane(value)
                }
            }
            .store(in: &cancellables)
        settings.$voiceAnswersProvider
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.applyAnswersProvider(value)
                }
            }
            .store(in: &cancellables)
        settings.$voiceAgentToolsEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.applyAgentTools(value)
                }
            }
            .store(in: &cancellables)
        settings.$voiceHotkey
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.applyHotkey(value)
                }
            }
            .store(in: &cancellables)
    }

    private func applyVoiceEnabled(_ enabled: Bool) {
        guard !stopped else { return }
        voiceEnabledState = enabled
        if enabled {
            startVoice()
        } else {
            dispatch(.featureDisabled)
            stopVoice()
        }
    }

    private func applyHermesLane(_ enabled: Bool) {
        guard !stopped else { return }
        if enabled {
            laneEnabled = true
            if voiceEnabledState {
                runLaneCheck()
            }
        } else {
            laneEnabled = false
            laneCheckGeneration += 1
            laneCheckTask?.cancel()
            laneCheckTask = nil
            model.setHermesLaneStatus(.off)
            let cloudSession = context.lane == .hermes
                && (context.state.isAgentBusy || context.state == .review)
            if cloudSession {
                dispatch(.stopAllRequested)
            }
            enqueueShutdown()
        }
    }

    /// Switching who answers ends any cloud turn in flight (it belongs to the old backend) and
    /// re-checks the lane against the new one.
    private func applyAnswersProvider(_ provider: VoiceAnswersProvider) {
        guard !stopped else { return }
        let cloudSession = context.lane == .hermes
            && (context.state.isAgentBusy || context.state == .review)
        if cloudSession {
            dispatch(.stopAllRequested)
        }
        model.setAgentName(agentName)
        if laneEnabled && voiceEnabledState {
            runLaneCheck()
        }
    }

    /// Turning "Let the agent control this Mac" off ends a provider turn in flight, so a turn
    /// that started with tools cannot keep using them (it hard-stops any running tool).
    private func applyAgentTools(_ enabled: Bool) {
        guard !stopped, !enabled else { return }
        let providerTurn = settings.voiceAnswersProvider != .hermes && context.lane == .hermes
            && (context.state.isAgentBusy || context.state == .review)
        if providerTurn {
            dispatch(.stopAllRequested)
        }
    }

    /// The backend behind the agent lane right now: Hermes unless the user picked an AI provider.
    private func currentAgentBackend() -> AgentBackend {
        guard let ai, settings.voiceAnswersProvider != .hermes else { return backend }
        ai.config.update(VoiceAIConfig(settings: settings))
        return ai.chatBackend
    }

    private var agentName: String {
        guard ai != nil else { return VoiceSessionModel.hermesAgentName }
        switch settings.voiceAnswersProvider {
        case .hermes: return VoiceSessionModel.hermesAgentName
        case .openAICompatible: return VoiceSessionModel.providerAgentName
        case .anthropic: return "Claude"
        }
    }

    /// R03a leaves an idle Stop as an audit only. A Hermes child that outlived a soft
    /// cancel is still this process's responsibility, so Stop reaps it.
    private func shouldReapOnIdleStop(_ event: VoiceEvent) -> Bool {
        guard case .stopAllRequested = event else { return false }
        return context.state == .idle && context.interrupt == nil
    }

    private func reapIdleAgent() {
        let backend = self.backend
        let chat = ai?.chatBackend
        let previous = stopChain
        stopChain = Task { @MainActor in
            await previous?.value
            _ = await backend.emergencyStop()
            _ = await chat?.emergencyStop()
        }
    }

    private func applyHotkey(_ choice: VoiceHotkeyChoice) {
        guard !stopped else { return }
        hotkeyChoice = choice
        guard voiceEnabledState else { return }
        keys?.stop()
        startKeys()
        reapplyCancelKey()
    }

    private func startVoice() {
        guard !stopped else { return }
        startKeys()
        startLockWatch()
        installActivityObserver()
        model.setPermissions(permissions.status())
        if laneEnabled {
            runLaneCheck()
        }
        verifyAuditChain()
    }

    private func stopVoice() {
        keyTask?.cancel()
        keyTask = nil
        lockTask?.cancel()
        lockTask = nil
        removeActivityObserver()
        keys?.stop()
        keys = nil
        appliedCancelArmed = nil
        model.setHotkeyStatus(.unavailable)
        laneCheckGeneration += 1
        laneCheckTask?.cancel()
        laneCheckTask = nil
        model.setHermesLaneStatus(.off)
        recognizer.cancel()
        ai?.recognizer.cancel()
        ducker.restore()
        duckedThisCapture = false
        cancelAllTimers()
        enqueueShutdown()
    }

    private func startKeys() {
        keyTask?.cancel()
        keyTask = nil
        let source = makeKeys(hotkeyChoice)
        keys = source
        let status = source.start()
        model.setHotkeyStatus(status)
        let stream = source.events
        keyTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, !self.stopped else { return }
                switch event {
                case .pressed:
                    self.dispatch(.talkPressed)
                case .released(let held):
                    self.dispatch(.talkReleased(heldSeconds: held))
                case .cancelKey:
                    self.dispatch(.cancelRequested)
                case .stopKey:
                    self.dispatch(.stopAllRequested)
                }
            }
        }
    }

    private func reapplyCancelKey() {
        guard let keys else { return }
        let armed = context.state != .idle && context.state != .paused
        appliedCancelArmed = armed
        keys.setCancelKeyArmed(armed)
    }

    private func startLockWatch() {
        lockTask?.cancel()
        let changes = lock.changes
        lockTask = Task { @MainActor [weak self] in
            for await locked in changes {
                guard let self, !self.stopped else { return }
                if locked {
                    self.dispatch(.screenLocked)
                }
            }
        }
    }

    private func installActivityObserver() {
        removeActivityObserver()
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidBecomeActive()
            }
        }
    }

    private func removeActivityObserver() {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
    }

    private func handleDidBecomeActive() {
        guard !stopped else { return }
        model.setPermissions(permissions.status())
        guard laneEnabled, voiceEnabledState else { return }
        if case .refused = model.hermesLaneStatus {
            runLaneCheck()
        }
    }

    private func runLaneCheck() {
        laneCheckGeneration += 1
        let token = laneCheckGeneration
        laneCheckTask?.cancel()
        let backend = currentAgentBackend()
        laneCheckTask = Task { @MainActor [weak self] in
            guard let self, !self.stopped, token == self.laneCheckGeneration else { return }
            self.model.setHermesLaneStatus(.checking)
            let result = await backend.preflight()
            guard !self.stopped, token == self.laneCheckGeneration else { return }
            switch result {
            case .ready:
                self.model.setHermesLaneStatus(.ready)
                self.appendAudit(AuditDraft(kind: .preflight, lane: .hermes, decision: "ready"))
            case .refused(let reason):
                self.model.setHermesLaneStatus(.refused(reason))
                self.appendAudit(AuditDraft(
                    kind: .preflight,
                    lane: .hermes,
                    decision: "refused",
                    outcome: reason.rawValue
                ))
            }
        }
    }

    private func verifyAuditChain() {
        let previous = auditChain
        let audit = self.audit
        auditChain = Task { @MainActor [weak self] in
            await previous?.value
            let verification = await audit.verify()
            guard let self, !self.stopped, !verification.isValid else { return }
            self.appendAudit(AuditDraft(kind: .error, decision: "audit_chain_broken"))
        }
    }

    private func enqueueShutdown() {
        let backend = self.backend
        let chat = ai?.chatBackend
        let previous = stopChain
        stopChain = Task { @MainActor in
            await previous?.value
            await backend.shutdown()
            await chat?.shutdown()
        }
    }
}

/// One capture task. The box identity is what the task removes, so a finished capture
/// does not stay in `recognitionTasks` until `stop()`.
private final class RecognitionTaskBox {
    var task: Task<Void, Never>?
}
