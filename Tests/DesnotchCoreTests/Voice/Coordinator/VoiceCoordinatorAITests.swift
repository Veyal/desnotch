import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceCoordinatorAITests: XCTestCase {
    private var retained: [AICoordParts] = []

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

    // MARK: Speech-to-text routing

    func testOnDeviceRecognizerIsTheDefault() async {
        let parts = makeParts()
        parts.keys.made[0].send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.onDevice.startCount == 1 })
        XCTAssertEqual(parts.cloud.startCount, 0)
        XCTAssertFalse(parts.model.usesCloud)
    }

    func testCloudSpeechUsesTheProviderRecognizerAndShowsTheCloudMark() async {
        let parts = makeParts { $0.voiceSpeechProvider = .openAICompatible }
        let keys = parts.keys.made[0]
        keys.send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.cloud.startCount == 1 })
        XCTAssertEqual(parts.onDevice.startCount, 0)
        XCTAssertTrue(parts.model.cloudActivity)
        XCTAssertTrue(parts.model.usesCloud)
        parts.cloud.emit(.captureStarted)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .listening })
        keys.send(.released(heldSeconds: 1.2))
        await CoordTestSupport.settle(self, until: { parts.cloud.endAudioCalls == 1 })
        XCTAssertTrue(parts.timers.scheduled.contains(VoiceAILimits.transcriptionWatchdog))
        XCTAssertFalse(parts.timers.scheduled.contains(VoiceTiming.finalWatchdog))
        parts.cloud.emit(.final("play"))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .review })
        XCTAssertTrue(parts.model.usesCloud, "the badge stays for the flow whose audio was uploaded")
    }

    func testCapEndedCloudCaptureIsNeverUploaded() async {
        let parts = makeParts { $0.voiceSpeechProvider = .openAICompatible }
        parts.keys.made[0].send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.cloud.startCount == 1 })
        parts.cloud.emit(.captureStarted)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .listening })
        fire(parts, seconds: VoiceTiming.holdListenCap)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .error })
        XCTAssertEqual(parts.cloud.endAudioCalls, 0)
        XCTAssertGreaterThanOrEqual(parts.cloud.cancelCalls, 1)
        XCTAssertEqual(parts.coordinator.context.failure, .rejected(.needsUserRelease))
    }

    // MARK: Answers routing

    func testHermesStillAnswersByDefault() async {
        let parts = makeParts { $0.voiceHermesLane = true }
        await reachThinking(parts)
        await CoordTestSupport.settle(self, until: { parts.hermes.submitted.count == 1 })
        XCTAssertEqual(parts.hermes.submitted, ["what is the weather in Jakarta"])
        XCTAssertTrue(parts.chat.submitted.isEmpty)
        XCTAssertEqual(parts.model.agentName, "Hermes")
    }

    func testProviderAnswersGoToTheChatBackend() async {
        let parts = makeParts {
            $0.voiceHermesLane = true
            $0.voiceAnswersProvider = .openAICompatible
        }
        await CoordTestSupport.settle(self, until: { parts.chat.preflightCalls >= 1 })
        await reachThinking(parts, expectReviewSummary: "Send to AI provider (cloud)")
        await CoordTestSupport.settle(self, until: { parts.chat.submitted.count == 1 })
        XCTAssertEqual(parts.chat.submitted, ["what is the weather in Jakarta"])
        XCTAssertTrue(parts.hermes.submitted.isEmpty)
        XCTAssertEqual(parts.model.agentName, "AI provider")
        XCTAssertTrue(parts.model.usesCloud)
        parts.chat.emit(.status("started"))
        parts.chat.emit(.finished(summary: "Cerah."))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .speaking })
        XCTAssertEqual(parts.model.reply, "Cerah.")
    }

    func testClaudeIsNamedInTheReviewLine() async {
        let parts = makeParts {
            $0.voiceHermesLane = true
            $0.voiceAnswersProvider = .anthropic
        }
        await reachThinking(parts, expectReviewSummary: "Send to Claude (cloud)")
        await CoordTestSupport.settle(self, until: { parts.chat.submitted.count == 1 })
        XCTAssertTrue(parts.hermes.submitted.isEmpty)
    }

    func testR54AppliesToTheProviderLane() async {
        let parts = makeParts {
            $0.voiceHermesLane = true
            $0.voiceAnswersProvider = .openAICompatible
        }
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .ready })
        parts.keys.made[0].send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.onDevice.startCount == 1 })
        parts.onDevice.emit(.captureStarted)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .listening })
        parts.onDevice.emit(.final("what is the weather in Jakarta"))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .error })
        XCTAssertEqual(parts.coordinator.context.failure, .rejected(.needsUserRelease))
        XCTAssertTrue(parts.chat.submitted.isEmpty)
    }

    func testStopHardStopsTheProviderTurn() async {
        let parts = makeParts {
            $0.voiceHermesLane = true
            $0.voiceAnswersProvider = .openAICompatible
        }
        await reachThinking(parts)
        parts.model.stopAll()
        await CoordTestSupport.settle(self, until: { parts.chat.emergencyStops >= 1 })
        XCTAssertEqual(parts.coordinator.context.state, .paused)
    }

    func testSwitchingProviderMidTurnStopsItAndRechecksTheLane() async {
        let parts = makeParts {
            $0.voiceHermesLane = true
            $0.voiceAnswersProvider = .openAICompatible
        }
        await reachThinking(parts)
        let hermesChecks = parts.hermes.preflightCalls
        parts.settings.voiceAnswersProvider = .hermes
        await CoordTestSupport.settle(self, until: {
            parts.chat.emergencyStops >= 1 && parts.hermes.preflightCalls > hermesChecks
        })
        XCTAssertEqual(parts.model.agentName, "Hermes")
    }

    func testRefreshAgentLaneRerunsThePreflight() async {
        let parts = makeParts {
            $0.voiceHermesLane = true
            $0.voiceAnswersProvider = .anthropic
        }
        parts.chat.preflightResult = .refused(.providerKeyMissing)
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .refused(.providerKeyMissing) })
        parts.chat.preflightResult = .ready(profile: "anthropic")
        parts.model.refreshAgentLane()
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .ready })
    }

    // MARK: Spoken replies

    func testCloudReplyVoiceSpeaksThroughTheProvider() async {
        let parts = makeParts {
            $0.voiceHermesLane = true
            $0.voiceTTSEnabled = true
            $0.voiceReplyProvider = .openAICompatible
        }
        await reachThinking(parts)
        parts.hermes.emit(.finished(summary: "It is sunny"))
        await CoordTestSupport.settle(self, until: { parts.cloudSynth.spoken.count == 1 })
        XCTAssertEqual(parts.cloudSynth.spoken.first?.text, "It is sunny")
        XCTAssertTrue(parts.systemSynth.spoken.isEmpty)
        XCTAssertTrue(parts.model.cloudActivity)
        parts.model.cancelReview()
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .idle })
        XCTAssertGreaterThanOrEqual(parts.cloudSynth.stopCount, 1)
        XCTAssertFalse(parts.model.cloudActivity, "the cloud mark clears with the session")
    }

    func testMacOSVoiceIsTheDefaultReplyVoice() async {
        let parts = makeParts {
            $0.voiceHermesLane = true
            $0.voiceTTSEnabled = true
        }
        await reachThinking(parts)
        parts.hermes.emit(.finished(summary: "It is sunny"))
        await CoordTestSupport.settle(self, until: { parts.systemSynth.spoken.count == 1 })
        XCTAssertTrue(parts.cloudSynth.spoken.isEmpty)
    }

    // MARK: Helpers

    private func makeParts(_ configure: (SettingsStore) -> Void = { _ in }) -> AICoordParts {
        let suiteName = "desnotch.voice.ai.coord.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: SettingsStore.Key.voiceEnabled.rawValue)
        let settings = SettingsStore(defaults: defaults)
        configure(settings)
        let model = VoiceSessionModel()
        let keys = CoordKeyBox()
        let timers = CoordManualTimerScheduler()
        let onDevice = CoordHeldRecognizer()
        let cloud = CoordHeldRecognizer()
        let systemSynth = CoordRecordingSynth()
        systemSynth.gated = false
        let cloudSynth = CoordRecordingSynth()
        let hermes = CoordGatedBackend()
        let chat = CoordGatedBackend()
        let audit = CoordRecordingAudit()
        audit.failing = false
        let ai = VoiceAIProviders(config: VoiceAIConfigBox(), recognizer: cloud, synthesizer: cloudSynth, chatBackend: chat)
        let coordinator = VoiceCoordinator(
            model: model, settings: settings, clock: FakeVoiceClock(), recognizer: onDevice, synthesizer: systemSynth,
            executor: RecordingExecutor(), backend: hermes, audit: audit, makeKeys: { keys.make($0) },
            lock: CoordFakeLock(), ducker: CoordRecordingDucker(), permissions: CoordFakePermissions(),
            cues: RecordingCuePlayer(), timers: timers, dailyTurns: DailyTurnCounter(defaults: defaults),
            isPrivacyMode: { false }, makeNonce: { "nonce-ai" }, ai: ai, debugTypingEnabled: false
        )
        coordinator.start()
        let parts = AICoordParts(
            suiteName: suiteName, defaults: defaults, settings: settings, model: model, keys: keys, timers: timers,
            onDevice: onDevice, cloud: cloud, systemSynth: systemSynth, cloudSynth: cloudSynth,
            hermes: hermes, chat: chat, coordinator: coordinator
        )
        retained.append(parts)
        return parts
    }

    private func fire(_ parts: AICoordParts, seconds: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let index = parts.timers.scheduled.lastIndex(of: seconds) else {
            XCTFail("missing timer \(seconds)", file: file, line: line)
            return
        }
        parts.timers.fire(index: index)
    }

    private func reachThinking(_ parts: AICoordParts, expectReviewSummary: String? = nil) async {
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .ready })
        let keys = parts.keys.made[0]
        keys.send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.onDevice.startCount == 1 })
        parts.onDevice.emit(.captureStarted)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .listening })
        keys.send(.released(heldSeconds: 1.2))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.captureEndedByUser })
        parts.onDevice.emit(.final("what is the weather in Jakarta"))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .review })
        if let expectReviewSummary {
            XCTAssertEqual(parts.model.routeSummary, expectReviewSummary)
        }
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .thinking })
    }
}

@MainActor
private final class AICoordParts {
    let suiteName: String
    let defaults: UserDefaults
    let settings: SettingsStore
    let model: VoiceSessionModel
    let keys: CoordKeyBox
    let timers: CoordManualTimerScheduler
    let onDevice: CoordHeldRecognizer
    let cloud: CoordHeldRecognizer
    let systemSynth: CoordRecordingSynth
    let cloudSynth: CoordRecordingSynth
    let hermes: CoordGatedBackend
    let chat: CoordGatedBackend
    let coordinator: VoiceCoordinator

    init(
        suiteName: String, defaults: UserDefaults, settings: SettingsStore, model: VoiceSessionModel,
        keys: CoordKeyBox, timers: CoordManualTimerScheduler, onDevice: CoordHeldRecognizer,
        cloud: CoordHeldRecognizer, systemSynth: CoordRecordingSynth, cloudSynth: CoordRecordingSynth,
        hermes: CoordGatedBackend, chat: CoordGatedBackend, coordinator: VoiceCoordinator
    ) {
        self.suiteName = suiteName
        self.defaults = defaults
        self.settings = settings
        self.model = model
        self.keys = keys
        self.timers = timers
        self.onDevice = onDevice
        self.cloud = cloud
        self.systemSynth = systemSynth
        self.cloudSynth = cloudSynth
        self.hermes = hermes
        self.chat = chat
        self.coordinator = coordinator
    }
}
