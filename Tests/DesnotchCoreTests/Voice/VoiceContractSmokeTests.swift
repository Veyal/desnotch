import XCTest
@testable import DesnotchCore

/// Smoke tests for the frozen contract: types, settings keys, the model, and the honest stubs.
/// They deliberately do NOT assert anything about the WP-LOGIC stubs (router, reducer, policy):
/// those are replaced by real implementations that have their own tests.
final class VoiceContractSmokeTests: XCTestCase {
    private let suiteName = "desnotch.tests.voice.contract"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Types

    func testTierOrderingAndLabels() {
        XCTAssertTrue(VoiceTier.t0 < VoiceTier.t1)
        XCTAssertTrue(VoiceTier.t3 < VoiceTier.t4)
        XCTAssertEqual(VoiceTier.allCases.map(\.label), ["T0", "T1", "T2", "T3", "T4"])
        XCTAssertEqual(VoiceTier.allCases.sorted(), VoiceTier.allCases)
    }

    func testStateMachineVocabularyIsComplete() {
        XCTAssertEqual(VoiceState.allCases.count, 11)
        XCTAssertEqual(
            VoiceState.allCases.filter(\.isAgentBusy).map(\.rawValue).sorted(),
            ["acting", "awaitingApproval", "thinking"]
        )
        XCTAssertEqual(VoiceTimerKind.allCases.count, 7)
    }

    func testLocalIntentKindsAndSummaries() {
        XCTAssertEqual(LocalIntent.volumeSet(percent: 30).summary, "Set volume to 30%")
        XCTAssertEqual(LocalIntent.volumeStep(delta: -10).summary, "Volume down 10")
        XCTAssertEqual(LocalIntent.volumeStep(delta: 5).summary, "Volume up 5")
        XCTAssertEqual(LocalIntent.openApp(bundleID: "com.apple.Safari", name: "Safari").summary, "Open Safari")
        XCTAssertEqual(LocalIntent.timerStart(minutes: 10).summary, "Timer 10 min")
        XCTAssertEqual(LocalIntent.mediaNext.kind, "media.next")
        XCTAssertFalse(LocalIntent.volumeSet(percent: 30).kind.contains("30"), "kind never carries arguments")
    }

    func testFreshContextIsIdleAndEmpty() {
        let context = VoiceContext()
        XCTAssertEqual(context.state, .idle)
        XCTAssertEqual(context.generation, 0)
        XCTAssertEqual(context.counter, 0)
        XCTAssertNil(context.pending)
        XCTAssertNil(context.interrupt)
        XCTAssertTrue(context.steps.isEmpty)
    }

    func testEveryFailureHasAShortGenericMessage() {
        let failures: [VoiceFailure] = [
            .unavailable(.recognizer), .permissionDenied(.microphone), .permissionDenied(.speech),
            .noSpeech, .screenLocked, .rateLimited, .dailyCapReached, .timeout, .stepBudgetExceeded,
            .tripwire(tool: "x"), .preflightRefused(.approvalsOff), .executionFailed("code"),
            .agentFailed("code"), .denied(.tierT4)
        ] + RejectReason.allCases.map { VoiceFailure.rejected($0) }
        for failure in failures {
            XCTAssertFalse(failure.userMessage.isEmpty)
            XCTAssertLessThanOrEqual(failure.userMessage.count, 60)
        }
        XCTAssertEqual(VoiceFailure.rejected(.unknownApp).code, "rejected.unknownApp")
        XCTAssertEqual(VoiceFailure.tripwire(tool: "secret-name").code, "tripwire", "no payload in codes")
        XCTAssertEqual(VoiceFailure.executionFailed("whatever").code, "execution_failed")
        XCTAssertEqual(VoiceFailure.noSpeech.severity, .info)
        XCTAssertEqual(VoiceFailure.tripwire(tool: "x").severity, .alert)
        XCTAssertEqual(VoiceFailure.rateLimited.severity, .warning)
    }

    func testConfirmationRequestApprovability() {
        var request = ConfirmationRequest(
            nonce: "n1", tier: .t2, source: .local, summary: "Set volume to 80%", literal: "Set volume to 80%"
        )
        XCTAssertTrue(request.canApprove)
        request.isTruncated = true
        XCTAssertFalse(request.canApprove, "a truncated command can never be approved")
        request.isTruncated = false
        request.risk = [.pipeToInterpreter]
        XCTAssertFalse(request.canApprove, "auto-deny flags disable Approve")
        request.risk = [.chaining]
        XCTAssertTrue(request.canApprove, "informational flags only warn")
        request.tier = .t3
        XCTAssertFalse(request.canApprove, "T3 needs a second factor that the MVP does not have")
    }

    func testAuditRecordRoundTripsThroughJSON() throws {
        let record = AuditRecord(
            seq: 1, timestamp: "2026-10-12T20:25:00Z", kind: .route, lane: .local, tier: 0,
            decision: "allow", outcome: nil, transcriptHash: "ab", counters: ["steps": 2],
            prevHash: "", hash: "cd"
        )
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(AuditRecord.self, from: data), record)
    }

    // MARK: Settings

    @MainActor
    func testVoiceSettingsDefaultOffAndPersist() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.voiceEnabled, "voice is off by default")
        XCTAssertFalse(store.voiceHermesLane, "the cloud lane is off by default")
        XCTAssertFalse(store.voiceTTSEnabled)
        XCTAssertTrue(store.voiceDuckMedia)
        XCTAssertEqual(store.voiceLocale, "en-US")
        XCTAssertEqual(store.voiceHotkey, .optionCommandV)

        store.voiceEnabled = true
        store.voiceLocale = "id-ID"
        store.voiceHotkey = .optionCommandJ
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.voiceEnabled)
        XCTAssertEqual(reloaded.voiceLocale, "id-ID")
        XCTAssertEqual(reloaded.voiceHotkey, .optionCommandJ)
    }

    @MainActor
    func testUnsupportedVoiceLocaleNormalizesToDefault() {
        defaults.set("fr-FR", forKey: "voiceLocale")
        XCTAssertEqual(SettingsStore(defaults: defaults).voiceLocale, "en-US")
        let store = SettingsStore(defaults: defaults)
        store.voiceLocale = "xx"
        XCTAssertEqual(store.voiceLocale, "en-US")
        XCTAssertEqual(defaults.string(forKey: "voiceLocale"), "en-US")
    }

    @MainActor
    func testVoiceSettingsAreNeverExportedAndResetSwitchesThemOff() throws {
        XCTAssertFalse(SettingsStore.exportedKeyNames.contains { $0.hasPrefix("voice") })
        let store = SettingsStore(defaults: defaults)
        store.voiceEnabled = true
        store.voiceHermesLane = true
        let exported = try store.exportJSON()
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("voice"))
        let report = try store.importJSON(Data(#"{"app":"desnotch","settings":{"voiceEnabled":true}}"#.utf8))
        XCTAssertEqual(report.rejected, ["voiceEnabled"], "import must not be able to enable voice")
        store.resetToDefaults()
        XCTAssertFalse(store.voiceEnabled)
        XCTAssertFalse(store.voiceHermesLane)
    }

    // MARK: Model

    @MainActor
    func testModelStartsIdleAndActionsAreSafeNoOps() {
        let model = VoiceSessionModel()
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.usesCloud)
        model.stopAll()
        model.approve(nonce: "x")
        model.deny(nonce: "x")
        model.cancelReview()
        model.toggleTalk()
        model.resume()
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testModelForwardsActionsToInstalledHandlers() {
        let model = VoiceSessionModel()
        var calls: [String] = []
        model.actions.stopAll = { calls.append("stop") }
        model.actions.approve = { calls.append("approve:\($0)") }
        model.actions.deny = { calls.append("deny:\($0)") }
        model.actions.cancelReview = { calls.append("cancel") }
        model.actions.toggleTalk = { calls.append("toggle") }
        model.actions.resume = { calls.append("resume") }
        model.stopAll()
        model.approve(nonce: "a")
        model.deny(nonce: "b")
        model.cancelReview()
        model.toggleTalk()
        model.resume()
        XCTAssertEqual(calls, ["stop", "approve:a", "deny:b", "cancel", "toggle", "resume"])
    }

    @MainActor
    func testApplyPublishesTheContextAndDerivesFlags() {
        let model = VoiceSessionModel()
        var context = VoiceContext()
        context.state = .awaitingApproval
        context.lane = .hermes
        context.partialTranscript = "open the"
        context.pending = ConfirmationRequest(
            nonce: "n", tier: .t2, source: .hermes, summary: "Run", literal: "ls"
        )
        model.apply(context, reviewDeadline: nil)
        XCTAssertEqual(model.state, .awaitingApproval)
        XCTAssertTrue(model.isActive)
        XCTAssertTrue(model.usesCloud)
        XCTAssertEqual(model.pendingConfirmation?.nonce, "n")

        context.route = .local(.volumeSet(percent: 30))
        model.apply(context, reviewDeadline: nil)
        XCTAssertEqual(model.routeSummary, "Set volume to 30%")
        context.route = .remote(utterance: "anything")
        model.apply(context, reviewDeadline: nil)
        XCTAssertEqual(model.routeSummary, "Send to Hermes (cloud)")
        context.route = nil

        context.state = .error
        context.failure = .noSpeech
        context.pending = nil
        model.apply(context, reviewDeadline: nil)
        XCTAssertEqual(model.errorText, "Didn't catch that")
        XCTAssertEqual(model.errorSeverity, .info)

        context.state = .idle
        context.failure = nil
        model.apply(context, reviewDeadline: nil)
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.isActive)
    }

    @MainActor
    func testStatusWritersPublish() {
        let model = VoiceSessionModel()
        XCTAssertEqual(model.hotkeyStatus, .unavailable)
        model.setHotkeyStatus(.active)
        XCTAssertEqual(model.hotkeyStatus, .active)
        model.setHermesLaneStatus(.refused(.approvalsOff))
        XCTAssertEqual(model.hermesLaneStatus, .refused(.approvalsOff))
        model.setPermissions(VoicePermissionStatus(microphone: .authorized, speech: .denied))
        XCTAssertFalse(model.permissions.isReady)
        model.setSurvivors(["nmap"])
        XCTAssertEqual(model.survivors, ["nmap"])
    }

    @MainActor
    func testLevelsAreClippedAndClearedWhenNotListening() {
        let model = VoiceSessionModel()
        var context = VoiceContext()
        context.state = .listening
        model.apply(context, reviewDeadline: nil)
        model.setLevels([0.2, 1.7, -3, 0.5, 0.9, 0.9, 0.9])
        XCTAssertEqual(model.levels, [0.2, 1, 0, 0.5, 0.9])
        context.state = .transcribing
        model.apply(context, reviewDeadline: nil)
        XCTAssertTrue(model.levels.isEmpty)
    }

    // MARK: Honest stubs

    func testUnavailableRecognizerReportsATypedFailure() async {
        let events = await collect(UnavailableRecognizer().start(localeIdentifier: "en-US", contextualStrings: []))
        XCTAssertEqual(events, [.failed(.unavailable(.recognizer))])
    }

    func testNullBackendFailsClosed() async {
        let backend = NullBackend()
        let preflight = await backend.preflight()
        XCTAssertEqual(preflight, .refused(.notImplemented))
        let events = await collect(backend.submit("hello"))
        XCTAssertEqual(events, [.failed(.unavailable(.backend))])
        let report = await backend.emergencyStop()
        XCTAssertEqual(report, EmergencyStopReport())
    }

    func testNullAuditLoggerAndFileWriterRefuse() async throws {
        let appended = await NullAuditLogger().append(AuditDraft(kind: .route))
        XCTAssertFalse(appended)
        let verification = await NullAuditLogger().verify()
        XCTAssertFalse(verification.isValid)
        XCTAssertThrowsError(try UnavailableFileWriter().appendLine("x", to: URL(fileURLWithPath: "/dev/null")))
    }

    @MainActor
    func testStubsForPlatformSeamsFailClosed() async {
        let result = await UnavailableLocalExecutor().execute(.mediaPlay)
        XCTAssertEqual(result, .failure(.unavailable(.executor)))
        XCTAssertTrue(UnknownLockState().isLocked, "unknown lock state counts as locked")
        XCTAssertEqual(UnavailablePushToTalk().start(), .unavailable)
        XCTAssertEqual(UnavailablePermissions().status(), .unknown)
        XCTAssertFalse(VoicePermissionStatus.unknown.isReady)
        let spoke = await UnavailableSynthesizer().speak("hi", localeIdentifier: "en-US")
        XCTAssertFalse(spoke)
    }

    // MARK: Test doubles conform to the seams

    @MainActor
    func testTestDoublesAreUsableThroughTheProtocols() async {
        let clock: VoiceClock = FakeVoiceClock()
        let start = clock.now()
        (clock as? FakeVoiceClock)?.advance(by: 5)
        XCTAssertEqual(clock.now().timeIntervalSince(start), 5)

        let recognizer: SpeechRecognizing = ScriptedRecognizer(script: [.captureStarted, .final("hello")])
        let events = await collect(recognizer.start(localeIdentifier: "en-US", contextualStrings: []))
        XCTAssertEqual(events, [.captureStarted, .final("hello")])

        let executor = RecordingExecutor()
        _ = await executor.execute(.mute)
        XCTAssertEqual(executor.executed, [.mute])

        let backend = ScriptedBackend(script: [.finished(summary: "ok")])
        let agentEvents = await collect(backend.submit("hi"))
        XCTAssertEqual(agentEvents, [.finished(summary: "ok")])
        XCTAssertEqual(backend.submitted, ["hi"])

        let writer = InMemoryFileWriter()
        let url = URL(fileURLWithPath: "/tmp/x.jsonl")
        try? writer.appendLine("a", to: url)
        XCTAssertEqual(try? writer.readLines(from: url), ["a"])
        XCTAssertEqual(try? writer.fileSize(url), 2)
        let moved = URL(fileURLWithPath: "/tmp/y.jsonl")
        try? writer.moveItem(at: url, to: moved)
        XCTAssertEqual(try? writer.readLines(from: moved), ["a"])
        XCTAssertEqual(try? writer.readLines(from: url), [])

        let cues = RecordingCuePlayer()
        (cues as VoiceCuePlaying).play(.done)
        XCTAssertEqual(cues.cues, [.done])
        NoopCuePlayer().play(.error)
    }
}
