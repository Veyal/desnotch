import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceCoordinatorHermesTests: XCTestCase {
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

    func testCoordinatorS3_cloudAgentWithApproval() async {
        let parts = makeParts(laneOn: true)
        await reachThinking(parts)
        parts.gated.emit(.toolActivity(kind: "clock"))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .acting })
        parts.gated.emit(.approvalNeeded(ConfirmationRequest(
            nonce: "c1", tier: .t2, source: .hermes,
            summary: "Agent wants to run a command", literal: "clock"
        )))
        await CoordTestSupport.settle(self, until: {
            parts.coordinator.context.state == .awaitingApproval
                && parts.model.pendingConfirmation?.nonce == "c1"
        })
        parts.model.approve(nonce: "c1")
        await CoordTestSupport.settle(self, until: { parts.gated.responses.count == 1 })
        XCTAssertEqual(parts.gated.responses.count, 1)
        XCTAssertEqual(parts.gated.responses.first?.nonce, "c1")
        XCTAssertEqual(parts.gated.responses.first?.allow, true)
        XCTAssertEqual(parts.coordinator.context.state, .acting)
        parts.gated.emit(.finished(summary: "It is sunny"))
        await CoordTestSupport.settle(self, until: {
            parts.coordinator.context.state == .speaking && parts.model.reply == "It is sunny"
        })
        fire(parts, seconds: VoiceTiming.replyDisplay)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .idle })
    }

    func testCoordinatorS4_tripwire() async {
        let parts = makeParts(laneOn: true)
        await reachThinking(parts)
        parts.gated.emergencyReport = EmergencyStopReport(survivors: ["perl"])
        parts.gated.emit(.toolActivity(kind: "terminal"))
        await CoordTestSupport.settle(self, until: {
            parts.coordinator.context.state == .paused
                && parts.gated.emergencyStops == 1
                && parts.model.survivors == ["perl"]
        })
        parts.model.resume()
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .idle })
        parts.keys.made[0].send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .armed })
    }

    func testTripwirePausesAndCallsEmergencyStop() async {
        let parts = makeParts(laneOn: true)
        await reachThinking(parts)
        parts.gated.emit(.toolActivity(kind: "terminal"))
        await CoordTestSupport.settle(self, until: {
            parts.coordinator.context.state == .paused && parts.gated.emergencyStops == 1
        })
    }

    func testEscDuringThinkingCallsCancelTurn() async {
        let parts = makeParts(laneOn: true)
        await reachThinking(parts)
        parts.keys.made[0].send(.cancelKey)
        await CoordTestSupport.settle(self, until: { parts.gated.cancelCalls == 1 })
    }

    func testDailyCounterIncrementedOncePerTurnThroughTheCoordinator() async {
        let parts = makeParts(laneOn: true)
        await reachThinking(parts)
        XCTAssertEqual(turnsLeft(parts), VoiceLimits.hermesTurnsPerDay)
        parts.gated.emit(.status("started"))
        await CoordTestSupport.settle(self, until: {
            turnsLeft(parts) == VoiceLimits.hermesTurnsPerDay - 1
        })
        parts.gated.emit(.status("working"))
        await CoordTestSupport.drainMainRound()
        XCTAssertEqual(turnsLeft(parts), VoiceLimits.hermesTurnsPerDay - 1)
    }

    func testRefusedPreflightAtSubmitShowsRefusedAndRoutesMissesToNotLocalCommand() async {
        let parts = makeParts(laneOn: true)
        await reachThinking(parts)
        parts.gated.emit(.failed(.preflightRefused(.approvalsOff)))
        await CoordTestSupport.settle(self, until: {
            parts.model.hermesLaneStatus == .refused(.approvalsOff)
        })
        fire(parts, seconds: VoiceTiming.errorDisplay)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .idle })
        parts.coordinator.submitTyped("what is the weather")
        XCTAssertEqual(parts.coordinator.context.failure, .rejected(.notLocalCommand))
    }

    func testLaneToggledOffMidTurnStillHardStopsTheLiveBackend() async {
        let parts = makeParts(laneOn: true)
        await reachThinking(parts)
        parts.settings.voiceHermesLane = false
        await CoordTestSupport.settle(self, until: {
            parts.gated.emergencyStops == 1 && parts.gated.shutdownCalls >= 1
        })
        let log = parts.gated.callLog
        let stop = log.firstIndex(of: "emergencyStop")
        let shutdown = log.firstIndex(of: "shutdown")
        XCTAssertNotNil(stop)
        XCTAssertNotNil(shutdown)
        XCTAssertLessThan(stop ?? 0, shutdown ?? 0)
    }

    func testStopCallsTerminateAgentNow() {
        let parts = makeParts()
        parts.coordinator.stop()
        XCTAssertEqual(parts.terminator.count, 1)
    }

    private func makeParts(laneOn: Bool = false) -> CoordParts {
        let suiteName = "desnotch.voice.hermes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: SettingsStore.Key.voiceEnabled.rawValue)
        if laneOn { defaults.set(true, forKey: SettingsStore.Key.voiceHermesLane.rawValue) }
        let settings = SettingsStore(defaults: defaults)
        let clock = FakeVoiceClock()
        let model = VoiceSessionModel()
        let keys = CoordKeyBox()
        let lock = CoordFakeLock()
        let ducker = CoordRecordingDucker()
        let synth = CoordRecordingSynth()
        synth.gated = false
        let audit = CoordRecordingAudit()
        audit.failing = false
        let permissions = CoordFakePermissions()
        let timers = CoordManualTimerScheduler()
        let cues = RecordingCuePlayer()
        let executor = RecordingExecutor()
        let held = CoordHeldRecognizer()
        let gated = CoordGatedBackend()
        let terminator = CoordTerminateCounter()
        let coordinator = VoiceCoordinator(
            model: model, settings: settings, clock: clock, recognizer: held, synthesizer: synth,
            executor: executor, backend: gated, terminateAgentNow: { terminator.invoke() },
            audit: audit, makeKeys: { keys.make($0) }, lock: lock, ducker: ducker,
            permissions: permissions, cues: cues, timers: timers,
            dailyTurns: DailyTurnCounter(defaults: defaults),
            isPrivacyMode: { settings.privacyModeEnabled }, makeNonce: { "nonce-1" },
            debugTypingEnabled: true
        )
        coordinator.start()
        let parts = CoordParts(
            suiteName: suiteName, defaults: defaults, settings: settings, model: model, clock: clock,
            keys: keys, lock: lock, ducker: ducker, synth: synth, audit: audit, permissions: permissions,
            timers: timers, cues: cues, executor: executor, held: held, gated: gated, backend: gated,
            terminator: terminator, coordinator: coordinator
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

    private func reachThinking(_ parts: CoordParts) async {
        await CoordTestSupport.settle(self, until: { parts.model.hermesLaneStatus == .ready })
        let keys = parts.keys.made[0]
        keys.send(.pressed)
        await CoordTestSupport.settle(self, until: { parts.held.startCount == 1 })
        parts.held.emit(.captureStarted)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .listening })
        keys.send(.released(heldSeconds: 1.2))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.captureEndedByUser })
        parts.held.emit(.final("what is the weather in Jakarta"))
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .review })
        fire(parts, seconds: VoiceTiming.reviewWindow)
        await CoordTestSupport.settle(self, until: { parts.coordinator.context.state == .thinking })
    }
}
