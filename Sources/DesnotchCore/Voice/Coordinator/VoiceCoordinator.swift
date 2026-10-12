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
    private var levelHistory: [Float] = []
    private var duckedThisCapture = false
    private var typedFlow = false
    private var typedStartPending = false

    private var pendingEvents: [VoiceEvent] = []
    private var isDispatching = false

    private var timerHandles: [TimerKey: VoiceTimerHandle] = [:]
    private var recognitionTasks: [Task<Void, Never>] = []
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
        for task in recognitionTasks {
            task.cancel()
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
        let transition = VoiceReducer.reduce(context, event, env: makeEnvironment(for: event))
        context = transition.context
        for effect in transition.effects {
            perform(effect)
        }
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
        case .endCapture:
            endCapture()
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
        let stream = recognizer.start(
            localeIdentifier: settings.voiceLocale,
            contextualStrings: VoiceLexicon.contextualStrings
        )
        let task = Task { @MainActor [weak self] in
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
        recognitionTasks.append(task)
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

    private func endCapture() {
        if typedFlow { return }
        recognizer.endAudio()
        restoreDuckIfNeeded()
    }

    private func cancelCapture() {
        if typedFlow { return }
        recognizer.cancel()
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
        if ConfirmationPolicy.tier(of: intent) >= .t2 && !auditWritable {
            dispatch(.localExecutionFinished(
                .failure(.executionFailed("audit_unwritable")),
                generation: generation
            ))
            return
        }
        let executor = self.executor
        Task { @MainActor [weak self] in
            let result = await executor.execute(intent)
            guard let self, !self.stopped else { return }
            self.dispatch(.localExecutionFinished(result, generation: generation))
        }
    }

    private func submitToAgent(_ text: String, generation: Int) {
        if !auditWritable {
            dispatch(.agent(.failed(.executionFailed("audit_unwritable")), generation: generation))
            return
        }
        let stream = backend.submit(text)
        let clock = self.clock
        Task { @MainActor [weak self] in
            var sawTerminal = false
            for await event in stream {
                guard let self, !self.stopped else { return }
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
            guard let self, !self.stopped, !sawTerminal else { return }
            self.dispatch(.agent(.failed(.agentFailed("stream_ended")), generation: generation))
        }
    }

    private func respondToApproval(nonce: String, allow: Bool) {
        let effectiveAllow = allow && auditWritable
        let backend = self.backend
        Task { @MainActor in
            await backend.respond(nonce: nonce, allow: effectiveAllow)
        }
    }

    private func cancelAgentTurn() {
        let backend = self.backend
        Task { @MainActor in
            await backend.cancelTurn()
        }
    }

    private func stopAgentHard() {
        let generation = context.generation
        let backend = self.backend
        let previous = stopChain
        stopChain = Task { @MainActor [weak self] in
            await previous?.value
            let report = await backend.emergencyStop()
            guard let self, self.context.state == .paused, self.context.generation == generation else { return }
            self.model.setSurvivors(report.survivors)
        }
    }

    private func speak(_ text: String, generation: Int) {
        let synthesizer = self.synthesizer
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
            model.setHermesLaneStatus(.off)
            if context.lane == .hermes && context.state.isAgentBusy {
                dispatch(.stopAllRequested)
            }
            enqueueShutdown()
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
        let backend = self.backend
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
        let previous = stopChain
        stopChain = Task { @MainActor in
            await previous?.value
            await backend.shutdown()
        }
    }
}
