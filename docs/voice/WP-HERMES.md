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
**Tests** (`Tests/DesnotchCoreTests/Voice/Coordinator/`): Part A: `VoiceCoordinatorLocalTests.swift`, `DailyTurnCounterTests.swift`, `VoiceTimersTests.swift`; Part B: `VoiceCoordinatorHermesTests.swift`;
(`Tests/DesnotchCoreTests/Voice/Hermes/`, all Part B): `MiniConfigScanTests.swift`, `HermesPreflightTests.swift`, `ACPClientTests.swift`, `HermesEventMapperTests.swift`, `HermesProcessGuardTests.swift`, `HermesAgentBackendTests.swift`, and `HermesFixtures.swift` (fixtures as Swift string literals: the test target has no resources).
A fresh worktree does not contain the empty directories (git does not track them): `mkdir -p Sources/DesnotchCore/Voice/Coordinator Sources/DesnotchCore/Voice/Hermes Tests/DesnotchCoreTests/Voice/Coordinator Tests/DesnotchCoreTests/Voice/Hermes` before you create files.

## Part A: the coordinator

**Part A wires ONLY `NullBackend()`.** `HermesAgentBackend` does not exist until Part B, so Part A must build and pass its gate without it. Part B later changes the single backend line in `AppComposition.swift` (same file, same owner).
**Part A also owns all shared coordinator behaviour that touches the backend.** Part A implements the lane check (A.5, formerly "B.8"), the whole `.submitToAgent` row of A.3 (daily counter, `.preflightRefused` to `.refused`, the `stream_ended` failure) and every `Coord*` double, and tests them against stub backends (`NullBackend`, `ScriptedBackend`, `CoordGatedBackend`). With `NullBackend` the lane status becomes `.refused(.notImplemented)`. Part B adds the real backend and its own tests; it does not change coordinator behaviour.

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

**Backend identity (read this twice).** `AppComposition` owns exactly ONE backend object for the app's lifetime and passes that SAME instance to the coordinator: in Part A it is `NullBackend()`; in Part B it is a lazily created stored `HermesAgentBackend` (constructing it spawns nothing). There is **no backend factory**. `submit`, `respond`, `cancelTurn`, `emergencyStop`, `preflight` and `shutdown` always go to that one instance, so a hard stop always reaches the object that owns the child process, and turning the lane off cannot strand a running child. The `voiceHermesLane` setting is NOT a backend switch: it gates `env.hermesLaneReady` (A.2) and the lane check (A.5).
`AgentBackend.shutdown()` is async, but app termination calls `stop()` synchronously and an unawaited `Task` does not run before the process exits, which would orphan `hermes acp`. So `stop()` calls `terminateAgentNow()` directly, a synchronous closure that `AppComposition` wires (Part B) to `HermesAgentBackend.terminateNow()` (B.6); Part A leaves the default `{}`. `AppComposition.stopOwnedResources()` calls `voiceCoordinator?.stop()`.

`VoiceTimerScheduling` and its handle (in `VoiceTimers.swift`), exact:

```swift
@MainActor protocol VoiceTimerHandle: AnyObject { func cancel() }
@MainActor protocol VoiceTimerScheduling { func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> VoiceTimerHandle }
```

Real: `RunLoopTimerScheduler` is **un-keyed**: every `schedule(after:_:)` makes one independent non-repeating `Timer` on `.common` mode (like `FocusTimerController`'s scheduler) and `handle.cancel()` invalidates that timer. It knows nothing about `(kind, generation)`. **Keying and replacement live only in the coordinator** (A.3, `.startTimer` row); the protocol above is exact and has no key parameter. **Timer semantics the reducer relies on:** a `.startTimer(kind, generation:, seconds:)` REPLACES any pending timer with the same `(kind, generation)`. This matters for a second agent approval card in one turn: R85 starts a 60 s `.approval` timer under the same generation as the first card's, so the first card's timer is cancelled and the second card gets its full 60 s (without replacement the first timer would expire the second card early). R32's second `.listenCap` replaces the first the same way. **The real scheduler's closure is not main-actor isolated:** Foundation's `Timer` block is `@Sendable` and non-isolated on Swift 5.10, so `RunLoopTimerScheduler` calls the `@MainActor` action as `MainActor.assumeIsolated { action() }` inside the timer block (the local 6.1 compiler accepts a bare call, CI's 5.10 does not). `VoiceTimersTests` defines the test double `CoordManualTimerScheduler` and uses it; the coordinator tests reuse it. Its minimum surface (the tests rely on exactly this; the double never learns `(kind, generation)`, only the coordinator keys handles): `private(set) var scheduled: [Double]` (the `seconds` of every `schedule` call, in order), `private(set) var cancelledCount: Int`, `var pendingCount: Int` (scheduled, not yet fired, not cancelled), `func fire(index: Int)` (runs the action scheduled at that position unless it was cancelled or already fired), `func fireLatest()` (the newest non-cancelled pending one), and `func fireAll()`. A test that needs "the review timer of generation 1" fires by position (the review timer is the one whose `seconds == 1.5`: `fire(index: scheduled.lastIndex(of: 1.5)!)` is fine in test code), and a stale-timer test dispatches `.timerElapsed(kind, generation: old)` straight into `coordinator.dispatch`, which is exactly what an elapsed timer does. `VoiceTimersTests` also tests the REAL scheduler with 10 ms timers, written as SYNC tests (`wait(for:timeout:)`; the stub also offers `await fulfillment(of:timeout:)`, which a test may use if it is `async`, because real XCTest warns about `wait` called directly from an async test): a timer fires exactly once (wait with an `expectation`, then `drainMainQueue()` twice and assert the counter is 1); a cancelled timer never fires (schedule it, cancel it, then schedule a 30 ms sentinel timer that fulfils an expectation; when the sentinel has fired the cancelled counter is still 0); `cancel()` twice is harmless.

### A.2 The dispatch loop

`dispatch(event)`: build `VoiceReducerEnv` (below), `let t = VoiceReducer.reduce(context, event, env: env)`, `context = t.context`, **run the effects in order**, then publish: `model.apply(context, reviewDeadline: context.state == .review ? reviewDeadline : nil)`; arm/disarm the Esc key (`keys.setCancelKeyArmed(armed)` where **`armed = context.state != .idle && context.state != .paused`** (Esc does something only in those states: `cancelRequested` is a no-op in `paused` (R132) and in `idle` (R14), and a global key that does nothing must not be stolen from other apps), only when the value changes). Re-entrancy: effects may synchronously cause more events (e.g. a fake executor); queue events and drain them in order instead of recursing (a simple `pending: [VoiceEvent]` + `isDispatching` flag). After each dispatch also run the timer clean-up of A.3.

`VoiceReducerEnv` per call: `now: clock.now()`, `voiceEnabled: voiceEnabledState`, `screenLocked: lock.isLocked`, `hermesLaneReady: laneEnabled && model.hermesLaneStatus == .ready && model.hotkeyStatus == .active` (the cloud lane never runs while the global Stop chord is not registered: `CarbonPushToTalk.start()` returns `.unavailable` when it could not register the chord, yet the status-menu Talk path still works then; PLAN deviation 9), `hermesTurnsRemainingToday: dailyTurns.remaining(now: clock.now())`, `speechAllowed: settings.voiceTTSEnabled && !isPrivacyMode()`, `secondFactorAvailable: false`, `freshNonce: makeNonce()`. `voiceEnabledState` and `laneEnabled` are the coordinator's own mirrors of the two settings, updated ONLY from the values the Combine sinks emit (A.5), never by re-reading the setting. `dailyTurns` is stored as a `var` (its `increment(now:)` is mutating).

### A.3 Effect interpreter (exact)

| Effect | What the coordinator does |
|---|---|
| `.startCapture(g, mode)` | remember `captureGeneration = g` and clear the level history (a `[Float]` of the last `VoiceLimits.meterBars` (5) levels: append, then drop from the front beyond 5). Unless this is a typed flow (A.6): **call `recognizer.start(localeIdentifier: settings.voiceLocale, contextualStrings: VoiceLexicon.contextualStrings)` SYNCHRONOUSLY inside the effect, before any `Task` exists** (`SpeechRecognizing.start` is a plain non-`async` function that returns the stream), keep the returned stream, and only THEN create the `Task { @MainActor [weak self] ... }` that consumes it. Any later `.endCapture`/`.cancelCapture` effect is then ordered after the `start` call. If `start` ran inside the Task instead, a `.cancelCapture` (R21: a hold of 0.35 s or more released before the first audio buffer, which a cold microphone start makes likely; a lock; Esc) could reach `recognizer.cancel()` BEFORE `start`, no-op, and the Task would open the microphone afterwards while the reducer is already idle (the late events are dropped as stale, but the microphone would stay open). The Task maps each `SpeechEvent` to `dispatch` with generation `g`: `.captureStarted` -> `.captureStarted(generation: g)` and, if `settings.voiceDuckMedia`, `ducker.duck()`; `.level(x)` -> `x` is ALREADY the mapped 0...1 value (WP-PLATFORM 3.1 emits `.level(LevelMeter.level(fromRMS:))`): push it into the history as is, do NOT call `level(fromRMS:)` again (a second mapping pins the meter near 0), then `model.setLevels(LevelMeter.bars(from: history))` (no reducer event); `.partial(s)` -> `.partialTranscript(s, g)`; `.final(s)` -> `.finalTranscript(s, g)`; `.failed(f)` -> `.captureFailed(f, g)`. **A stream that finishes without a final or failed**: if `context.state` is `armed` or `listening` for that generation (or it is the live interrupt capture) dispatch `.captureFailed(.unavailable(.recognizer), generation: g)` (there is no other watchdog for a silently dead recognizer); in `transcribing` the final watchdog (R41) covers it; after a cancel nothing. Drop events whose `g != captureGeneration` (they are stale anyway). **Ducker balance:** whenever any event of the stream is a `.final` or a `.failed`, or the stream finishes, call `ducker.restore()` (idempotent) after dispatching: R103 (an interrupt capture's final) and a recognizer that finalizes on its own while the key is still held emit no `.endCapture`, so without this the system volume could stay lowered. |
| `.endCapture(g)` | `recognizer.endAudio()`; `ducker.restore()`. |
| `.cancelCapture(g)` | `recognizer.cancel()`; `ducker.restore()`; clear levels. (Calling `restore()` twice is harmless; the ducker is idempotent. `duck()` must be called at most once per capture: guard with a flag.) While `typedFlow` is set (A.6) neither the recognizer nor the ducker is touched by `.endCapture`/`.cancelCapture`. |
| `.startTimer(kind, g, seconds)` | `timers.schedule(after: seconds) { dispatch(.timerElapsed(kind, generation: g)) }`; remember the handle by `(kind, g)`; when the same key is scheduled again, cancel the replaced handle; for `.review` also set `reviewDeadline = clock.now() + seconds`. **Clean-up rule: after each dispatch, cancel every stored handle whose generation is neither `context.generation` nor `context.interrupt?.generation`.** Do NOT cancel on "any `startCapture` or NEW_ID": R100 starts the stop-only interrupt capture with a new `counter` while the main flow keeps its generation, and the 180 s `.turnBudget` and 60 s `.approval` timers of the running turn must survive it. Cancel all handles on `stop()`. |
| `.cue(c)` | `cues.play(c)` |
| `.execute(intent, g)` | audit gate (A.4), then `Task { let r = await executor.execute(intent); dispatch(.localExecutionFinished(r, generation: g)) }` |
| `.submitToAgent(text, g)` | audit gate (A.4), then `let stream = backend.submit(text)` (called SYNCHRONOUSLY on the main actor, before any `Task` exists: `AgentBackend.submit` is not `async`, and the backend captures its turn epoch inside this very call, so a Stop issued afterwards is guaranteed to be newer however its `Task` is scheduled), then `Task { for await e in stream { if case .status("started") = e { dailyTurns.increment(now: clock.now()) }; if case .failed(.preflightRefused(let r)) = e { model.setHermesLaneStatus(.refused(r)); appendAudit(AuditDraft(kind: .preflight, lane: .hermes, decision: "refused", outcome: r.rawValue)) }; dispatch(.agent(e, generation: g)) } }` (`appendAudit` is the ordered audit chain of the `.audit` row); if the stream ends without having delivered `.finished` or `.failed`, dispatch `.agent(.failed(.agentFailed("stream_ended")), generation: g)`. With the Part A `NullBackend` this yields the typed `.unavailable(.backend)` failure. |
| `.respondToApproval(nonce, allow)` | audit gate for approvals (A.4): `let effectiveAllow = allow && auditWritable`; then `Task { await backend.respond(nonce: nonce, allow: effectiveAllow) }`. A deny is never converted into an allow. |
| `.cancelAgentTurn` | `Task { await backend.cancelTurn() }` |
| `.stopAgentHard` | `let g = context.generation` (already the post-`NEW_ID` value: effects are interpreted after `context = t.context`), then `Task { @MainActor [weak self] in let report = await backend.emergencyStop(); guard let self, self.context.state == .paused, self.context.generation == g else { return }; self.model.setSurvivors(report.survivors) }`. The guard keeps a Resume that came first (state `idle`, a newer generation) from being followed by stale survivor names (the hard stop itself still ran). |
| `.speak(text, g)` | `Task { _ = await synthesizer.speak(text, localeIdentifier: settings.voiceLocale); dispatch(.speechFinished(generation: g)) }` |
| `.stopSpeaking` | `synthesizer.stop()` |
| `.audit(draft)` | `Task { let ok = await audit.append(draft); auditWritable = ok }` (tasks run in order: chain them through one stored `Task`, each awaiting the previous, so records stay ordered) |

### A.4 Audit gate

`auditWritable` starts true. When it is false: an `.execute` effect for an intent whose tier is `>= .t2`, and every `.submitToAgent`, is NOT run; instead dispatch `.localExecutionFinished(.failure(.executionFailed("audit_unwritable")), generation: g)` or `.agent(.failed(.executionFailed("audit_unwritable")), generation: g)`. T0 local commands keep working. (Tier from `ConfirmationPolicy.tier(of:)`.) **Agent approvals are gated too** (safety rule 6: audit unwritable = no risky actions): when `auditWritable == false`, a `.respondToApproval(nonce, allow: true)` is sent to the backend as `allow: false`. Nothing else changes: the reducer has already moved on (R74 went to `acting`), and the agent finishes or fails by itself. `FileAuditLogger` default directory/instance is created in `AppComposition`.

**Accepted one-record lag.** `auditWritable` is updated after the asynchronous append of the PREVIOUS record, so the gate can lag by one record. That is accepted on purpose: the `route` record and the `approval requested` record of the same flow were appended at least 1.5 s (review window) or a card display earlier, so a failing disk is seen before the next risky action in practice. (The alternative, which a stricter implementation may choose, is to make the T2 `.execute` Task and the approval response await the tail of the ordered audit chain before running.)

### A.5 Inputs

- **Hotkey source: one per enable.** `keys` is created in `startVoice()` and nowhere else: `keys = makeKeys(hotkeyChoice)`, where `hotkeyChoice` is the coordinator's mirror of `settings.voiceHotkey` (updated only from the values its sink emits, like the other mirrors below). It is ALWAYS a fresh instance: a `CarbonPushToTalk` is single-use (`start()` after `stop()` returns `.unavailable` and registers nothing), so reusing the previous instance after Settings off, then on, with the same hotkey would leave the hotkeys dead and the status "unavailable". Then `let status = keys.start()` and ALWAYS `model.setHotkeyStatus(status)` (`.unavailable` means another app owns the combination, or the Stop chord ⌥⌘. could not be registered; Settings shows it). `keys.events` is consumed by one `keyTask` (a `Task { @MainActor [weak self] in ... }` started after `keys.start()`; cancelled and restarted on every enable and every hotkey change): `.pressed` => `.talkPressed`; `.released(h)` => `.talkReleased(heldSeconds: h)`; `.cancelKey` => `.cancelRequested`; `.stopKey` => `.stopAllRequested`.
- **Lock gate.** `lock.changes` is a computed property that returns a NEW stream on every access (WP-PLATFORM 3.4). Access it ONCE per enable, in `startVoice()`, and iterate it in one `lockTask`; the monitor installs its observers when that stream is created and removes them (and resets its flags) when the last stream terminates, which happens when `lockTask` is cancelled on disable. Do not access `changes` anywhere else and do not hold a stream while voice is off. `lock.isLocked` (read on every dispatch for `env.screenLocked`) is recomputed from the system on every call and needs no stream to be correct. A change to `true` => `.screenLocked`.
- `NSApplication.didBecomeActiveNotification` (observed only while voice is enabled) -> `model.setPermissions(permissions.status())`, so Settings notices a grant made in System Settings.
- **Settings sinks (Combine, `[weak self]`).** `@Published` emits in `willSet`, so inside a sink `settings.voiceEnabled` / `settings.voiceHermesLane` / `settings.voiceHotkey` still hold the OLD value. Therefore: (1) every sink is `settings.$voiceEnabled.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] value in ... }` (the pattern the existing controllers use; tests call `settle` or `drainMainQueue()` after flipping a setting), and the handler acts on the EMITTED `value`, storing it in the mirror (`voiceEnabledState`, `laneEnabled`, `hotkeyChoice`), never re-reading the setting; (2) `start()` first applies the current values of the settings once, synchronously (so a launch with voice already on starts voice), then subscribes (`dropFirst` skips the replayed value). The handlers:
  - `voiceEnabled` true -> `startVoice()`: (1) `keys = makeKeys(hotkeyChoice)` (always a new instance, see above); (2) `keys.start()` and `model.setHotkeyStatus(status)`; (3) start `keyTask`; (4) access `lock.changes` once and start `lockTask`, and start the didBecomeActive observer; (5) `model.setPermissions(permissions.status())`; (6) if `laneEnabled`, run the lane check below.
  - `voiceEnabled` false -> `dispatch(.featureDisabled)` FIRST (so the reducer's STOP_ALL effects, including a hard stop of a live agent, are interpreted while everything still exists), then `stopVoice()`: cancel `keyTask`, `lockTask` and the didBecomeActive observer; `keys.stop()`; `model.setHotkeyStatus(.unavailable)`; `laneCheckGeneration += 1` (a lane check still in flight must not write `.ready` or `.refused` after voice went off) and `model.setHermesLaneStatus(.off)` (the status must not stay `.ready` while voice is off; the next enable re-runs the check); `recognizer.cancel()`; `ducker.restore()`; cancel every stored timer handle; `Task { await backend.shutdown() }`.
  - `voiceHermesLane` on -> `laneEnabled = true`; if `voiceEnabledState`, run the lane check. Off -> `laneEnabled = false`, `model.setHermesLaneStatus(.off)`; if a Hermes turn is live (`context.lane == .hermes && context.state.isAgentBusy`) `dispatch(.stopAllRequested)` (the hard stop goes to the live backend instance); then `Task { await backend.shutdown() }`.
  - `voiceHotkey` changed -> `hotkeyChoice = value`. If `voiceEnabledState`: `keys.stop()`, cancel `keyTask`, then steps (1)-(3) of `startVoice()` again (a new `makeKeys(value)`, `start()`, publish the status, restart `keyTask`) and re-apply the Esc arm state (`keys.setCancelKeyArmed(...)` with the current value). If voice is off, only the mirror changes (no keys exist).
- **Lane check (implemented in THIS part; the real backend arrives in Part B).** When `voiceHermesLane` is on (at `start()`, on toggle, and on every enable, always using the emitted value) the coordinator runs `Task { @MainActor [weak self] ... }`: `model.setHermesLaneStatus(.checking)`, `let result = await backend.preflight()`, then `.ready` or `.refused(reason)`, and appends `AuditDraft(kind: .preflight, lane: .hermes, decision: ready ? "ready" : "refused", outcome: ready ? nil : reason.rawValue)` through the ordered audit chain. It captures a `laneCheckGeneration` counter before the `await` and discards its result if the lane was toggled meanwhile. While the status is not `.ready` (or the hotkey is not `.active`) `hermesLaneReady` is false, so the router never produces `.remote`. With the Part A `NullBackend` the result is `.refused(.notImplemented)`. Because the real preflight also runs on every submit (B.7), a profile unlocked later is caught at the next utterance and the status line is refreshed from the refusal (A.3).
- `model.actions` (installed in `start()`): `stopAll` => `.stopAllRequested`; `resume` => `.resumeRequested`; `approve(n)` => `.approveRequested(nonce: n)`; `deny(n)` => `.denyRequested(nonce: n)`; `cancelReview` => `.cancelRequested`; `toggleTalk` => `.toggleTalk`; `submitTyped` => `submitTyped` (only if `debugTypingEnabled`); `requestPermissions` => `Task { model.setPermissions(await permissions.request()) }`.

### A.6 Typed debug flow (no microphone)

`submitTyped(text)`: only if `debugTypingEnabled` and `context.state == .idle` and `voiceEnabledState`. Set `typedFlow = true`; `dispatch(.talkPressed)`; (the `.startCapture` effect is NOT executed while `typedFlow`, and neither are `.endCapture`/`.cancelCapture` on the recognizer or ducker); then `dispatch(.captureStarted(generation: context.generation))`, `dispatch(.talkReleased(heldSeconds: 1.0))`, `dispatch(.finalTranscript(text, generation: context.generation))`. Clear `typedFlow` after ANY dispatch that leaves the state in `idle`, `error` or `paused`, including a `.talkPressed` that was refused (screen locked: R13 goes to `error`). **Also clear it on any `.startCapture` effect that was NOT produced by `submitTyped`** (a real hotkey press from `speaking` (R111), or the R100 interrupt capture while the typed command's agent turn is `thinking`): otherwise `typedFlow` would still be set when the state moves on to `review`, `thinking` or `speaking`, and that real capture would silently start no recognizer. Implementation: `submitTyped` also sets a one-shot flag `typedStartPending = true` just before its `dispatch(.talkPressed)`; the `.startCapture` interpreter reads and clears it first thing (`let typed = typedStartPending; typedStartPending = false; typedFlow = typed`) and skips the recognizer only when `typed` is true; `submitTyped` resets `typedStartPending = false` right after its first dispatch returns (a refused press produces no `.startCapture`). Everything after the final transcript (review window, execution, approvals, audit) is the real pipeline.

### A.7 Daily cap

`DailyTurnCounter` (struct, `DailyTurnCounterTests`): `init(defaults: UserDefaults, calendar: Calendar = .current, limit: Int = VoiceLimits.hermesTurnsPerDay)`; keys `"voice.hermesTurns.day"` (a `yyyy-MM-dd` string in the calendar's time zone) and `"voice.hermesTurns.count"`; `func remaining(now: Date) -> Int` (the ONLY reader: the env uses `dailyTurns.remaining(now: clock.now())`), `mutating func increment(now: Date)`; a new day resets; a corrupt value counts as 0; never negative. The coordinator calls `increment` when a turn is actually submitted (B.7). These keys are NOT in `SettingsStore` and not exported.

### A.8 `AppComposition` wiring (Part A: `NullBackend` only)

(The only edit to `AppComposition.swift`; keep the existing code as is.) Create the platform objects and the coordinator **only when `!smokeTestMode`**: `voiceCoordinator` (optional property), built with exactly the merged signatures of WP-PLATFORM (read them in the files before you call them). The complete argument list, by label:

```swift
VoiceCoordinator(
    model: voiceModel, settings: SettingsStore.shared, clock: SystemVoiceClock(),
    recognizer: AppleSpeechRecognizer(), synthesizer: AppleSpeechSynthesizer(),
    executor: SystemLocalExecutor(nowPlaying: nowPlayingController, focusTimer: focusTimerController),
    backend: NullBackend(),                       // Part B replaces exactly this argument (B.7)
    audit: FileAuditLogger(directory: FileAuditLogger.defaultDirectory(), writer: DiskFileWriter(), clock: SystemVoiceClock()),
    makeKeys: { CarbonPushToTalk(choice: $0) },
    lock: ScreenLockMonitor(), ducker: VolumeDucker(),
    permissions: SystemVoicePermissions(), cues: VoiceCuePlayer(),
    dailyTurns: DailyTurnCounter(defaults: .standard),
    isPrivacyMode: { SettingsStore.shared.privacyModeEnabled },
    debugTypingEnabled: ProcessInfo.processInfo.environment["DESNOTCH_VOICE_DEBUG"] == "1"
)   // terminateAgentNow, timers and makeNonce keep their defaults in Part A
```

These initializers are specified to be side-effect free (no audio engine, no observers, no directories); if you find one that is not, build it lazily inside a closure instead of eagerly and report it. Create the coordinator at the end of `init` (after every other property is initialized) and call `start()` right there (it is inert unless `voiceEnabled`); you may NOT edit `AppDelegate.swift`. Call `voiceCoordinator?.stop()` in `stopOwnedResources()`. With `voiceEnabled == false` the coordinator must register NO hotkey, create NO audio engine and run NO timers (verify with a test).

### A.9 Part A tests (`VoiceCoordinatorLocalTests`, using the contract's doubles)

**Test doubles.** All test files share one module, so a double named like another package's double breaks the merged build. Define every coordinator double INSIDE `VoiceCoordinatorLocalTests.swift` (the timer scheduler inside `VoiceTimersTests.swift`), as internal `final class`es (not `private`, `VoiceCoordinatorHermesTests` reuses them), all prefixed `Coord`: `CoordFakeKeys`, `CoordFakeLock`, `CoordRecordingDucker`, `CoordRecordingSynth`, `CoordRecordingAudit`, `CoordFakePermissions`, `CoordManualTimerScheduler`, `CoordGatedBackend`, `CoordHeldRecognizer` and the helper `CoordTestSupport`. Before you name a type run `rg -n "class <Name>|struct <Name>" Tests` and change the name on a collision. Use the contract's `RecordingExecutor`, `FakeVoiceClock`, `InMemoryFileWriter` from `VoiceTestSupport.swift` as they are, `ScriptedRecognizer` ONLY for the instant-final and silent-end tests, and `ScriptedBackend` ONLY for the instant-finish and tripwire cases (see below). **Which recognizer double a test uses:** `ScriptedRecognizer` (frozen) replays its WHOLE script at `start` and then finishes the stream, so with an empty or short script the A.3 rule "stream ends without a final or failed while `armed`/`listening` => `.captureFailed(.unavailable(.recognizer))`" fires at once and sends the flow to `error`. Therefore EVERY test that presses the talk key and then drives `captureStarted`, the release, a partial or the final BY HAND (S3, S4, `testInterruptCaptureDoesNotCancelTurnBudgetOrApprovalTimers`, `testStaleTimerFromOldFlowIsIgnored`, `testNoCloudSubmitWithoutUserRelease`, the lock/cancel/ducking tests, ...) uses `CoordHeldRecognizer`; alternatively such a flow may run through `submitTyped`, which sets `captureEndedByUser = true` through the typed path and never starts a recognizer. Every double that conforms to a `@MainActor` protocol is `@MainActor`; every `@unchecked Sendable` double keeps its locked work in synchronous helpers (global rule 2).

- `CoordFakeKeys` (a `PushToTalkSource`): injectable `events` (a `send(_:)` method), `startCount`, `stopCount`, the history of `setCancelKeyArmed` values, and a settable `startResult` (default `.active`). **It must behave like the real source: single-use.** `start()` after `stop()` returns `.unavailable` and registers nothing, and `events` is finished by `stop()`. Otherwise it could never catch the dead-hotkey-after-off-on bug. The tests count the instances `makeKeys` produced (a `[CoordFakeKeys]` array the `makeKeys` closure appends to).
- `CoordFakeLock` (a `LockStateProviding`): a settable `isLocked`, a `changesAccessCount`, and `changes` returning a NEW stream per access whose continuations the test drives with `set(locked:)`.
- `CoordRecordingDucker` (duck/restore counters), `CoordRecordingSynth` (records the spoken texts and locales; **gatable**: with `var gated = true` its `speak` suspends until the test calls `finishSpeaking(_ result: Bool = true)`, so `.stopSpeaking` followed by a late `speechFinished` can be tested; `stopCount` counts `stop()` calls), `CoordRecordingAudit` (records drafts, optionally the `transcript` field; has a failing mode, `var failing = true`, in which `append` returns false), `CoordFakePermissions`.
- `CoordHeldRecognizer: SpeechRecognizing, @unchecked Sendable` (the recognizer equivalent of `CoordGatedBackend`). Its stream stays OPEN until the test calls `emit(_ event: SpeechEvent)` or `finish()`. It counts `startCount`, `endAudioCalls` and `cancelCalls`, records the `localeIdentifier` and `contextualStrings` of each `start`, and keeps the continuation behind one `NSLock` in synchronous helpers (global rule 2). `start(...)` is called synchronously by the coordinator (A.3), so `startCount` is already 1 when `dispatch(.talkPressed)` returns. `cancel()` increments `cancelCalls` and finishes the stream WITHOUT emitting anything (like the real one).
- `CoordGatedBackend: AgentBackend, @unchecked Sendable` (the contract's `ScriptedBackend` replays its whole script at once and then finishes the stream, has no `shutdown` counter and ends the turn before the test can act, so it cannot express "the turn stays open until the test says so"). It keeps one `AsyncStream<AgentEvent>.Continuation` per `submit` that the test yields into by hand (`func emit(_ event: AgentEvent)`, `func finish()`), lock-guarded counters `submitted: [String]`, `responses: [(nonce: String, allow: Bool)]`, `cancelCalls`, `emergencyStops`, `shutdownCalls`, `preflightCalls`, a settable `preflightResult` (default `.ready(profile: "voice")`) and `emergencyReport` (default `EmergencyStopReport()`). The S3 approval flow (the turn must stay open until `approveRequested` has produced `respondToApproval`), `Esc during thinking calls cancelTurn`, and `testLaneToggledOffMidTurnStillHardStopsTheLiveBackend` all use it. A tuple array is NOT `Equatable`, so never write `XCTAssertEqual(backend.responses, [("c1", true)])`: assert `responses.count`, `responses.first?.nonce` and `responses.first?.allow` separately (the same applies to `ScriptedBackend.responses`). Give it a `var preflightGate: Bool`-style hook only if a test needs a preflight that suspends (`testVoiceOffResetsTheLaneStatus`): with `preflightGated = true` its `preflight()` suspends until the test calls `releasePreflight()`.
- `CoordTestSupport` (an `enum` with static helpers): the ONLY way the coordinator tests wait.

  ```swift
  enum CoordTestSupport {
      /// Spins until `condition()` holds: each round does `test.drainMainQueue()` and `await Task.yield()`, so a chain of
      /// hops (recognizer stream, dispatch, `await executor.execute`, dispatch, audit task, `backend.submit`) completes without a sleep.
      /// `maxRounds` is a ceiling, not a delay; a condition that never holds fails the test.
      @MainActor
      static func settle(_ test: XCTestCase, until condition: @MainActor () -> Bool, maxRounds: Int = 500,
                         file: StaticString = #filePath, line: UInt = #line) async {
          for _ in 0..<maxRounds {
              if condition() { return }
              test.drainMainQueue()
              await Task.yield()
          }
          if !condition() { XCTFail("condition not met after \(maxRounds) rounds", file: file, line: line) }
      }
  }
  ```

  `drainMainQueue()` drains ONE main-queue round; a multi-hop chain needs several, so NO coordinator test uses a fixed number of drains: every assertion about an asynchronous result is preceded by `await CoordTestSupport.settle(self, until: { ... })` (tests that use it are `async`).

Names (each is a test; "(moved)" = was in Part B): `testTypedVolumeCommandRunsThroughReviewAndExecutes`, `testHoldFlowWithScriptedRecognizer` (press, scripted `.captureStarted/.partial/.final`, release), `testReviewWindowCancelByEscapeNeverExecutes`, `testStopKeyAlwaysStopsAndReturnsIdle`, `testLockedScreenRefusesToStart`, `testScreenLockedWhileListeningCancelsCapture`, `testFeatureDisabledStopsCaptureAndReleasesKeys`, `testCancelKeyIsArmedOnlyWhileActive`, `testCancelKeyIsDisarmedInIdleAndPaused`, `testDuckingIsBalanced` (one duck, one restore per capture, also on cancel), `testDuckerRestoredWhenTheRecognizerFinalizesByItself` (a scripted `.final` while the key is still held, then `restore` count 1), `testT2VolumeNeedsApprovalAndWrongNonceDoesNothing`, `testApproveExecutesAndDenyDoesNot`, `testAuditUnwritableRefusesT2ButNotT0`, `testRepliesAreSpokenOnlyWhenAllowed` (TTS setting, privacy mode), `testNoCloudSubmitWithoutUserRelease`, `testDailyCapRefusesTheTurn`, `testDisabledVoiceStartsNothing` (no `keys.start`, no `makeKeys` call, no recognizer start, no timers), `testModelActionsDispatchEvents`, `testStaleTimerFromOldFlowIsIgnored`, `testInterruptCaptureDoesNotCancelTurnBudgetOrApprovalTimers`, `testSilentRecognizerStreamEndFailsTheCaptureInsteadOfHanging`, `testNoAuditRecordContainsTheTranscript` (scan every appended draft/record for the spoken text except the `transcript` field handed to the logger, which `FileAuditLogger` hashes), `testSettingsFlipOnARealSettingsStoreStartsAndStopsVoice` and the rest below.

- `testSettingsFlipOnARealSettingsStoreStartsAndStopsVoice` flips voice **on, off, on** with the SAME hotkey on a real `SettingsStore(defaults:)` UUID suite (`settle` after each flip) and asserts: `makeKeys` was called exactly twice (two distinct `CoordFakeKeys`), the first instance has `startCount == 1` and `stopCount == 1`, the second `startCount == 1` and `stopCount == 0`, `model.hotkeyStatus == .active` after the second enable, `lock.changesAccessCount == 2`, and the key events of the SECOND instance reach the reducer (a `send(.pressed)` leaves `.idle`). The fake being single-use is what makes the test able to fail.
- `testHotkeyChangeWhileEnabledBuildsANewSource`: with voice on, change `voiceHotkey`: the old instance is stopped, `makeKeys` receives the new choice, the new instance is started, the Esc arm state is re-applied; with voice off, a hotkey change creates no source.
- `testHermesLaneFlipOnARealSettingsStoreBecomesReadyOrRefused` (moved from Part B): flip `voiceHermesLane` on a `SettingsStore(defaults:)` suite and `settle` until `model.hermesLaneStatus` is `.ready` for a `CoordGatedBackend`/`ScriptedBackend` whose preflight is `.ready`, and `.refused(.profileMissing)` for one that refuses; never stuck at `.off`/`.checking`; the toggle off sets `.off`.
- `testNullBackendLaneCheckRefusesWithNotImplemented`: with `NullBackend` the status becomes `.refused(.notImplemented)` and a speech miss is routed to `.rejected(.notLocalCommand)`.
- `testHermesLaneNotReadyWhileHotkeyUnavailable`: lane `.ready` but `CoordFakeKeys.startResult == .unavailable`: a miss is `.rejected(.notLocalCommand)`, never `.remote`.
- `testLaneCheckIsAudited`: the lane check appends one `.preflight` draft (`ready`, or `refused` with the reason), and a `.failed(.preflightRefused)` from `submit` appends one more.
- `testSubmitToAgentWithScriptedBackendCountsTheTurnOncePerSubmit` (the whole `.submitToAgent` row with `ScriptedBackend`): `.status("started")` increments the daily counter exactly once; a script without `.finished`/`.failed` yields `.failed(.agentFailed("stream_ended"))`; a `.failed(.preflightRefused(r))` sets `.refused(r)`.
- `testCancelRightAfterPressLeavesTheRecognizerCancelledAfterStart` (open-microphone race; `CoordHeldRecognizer`): `dispatch(.talkPressed)` then immediately `dispatch(.cancelRequested)` (state `armed`, no `captureStarted` yet): afterwards `startCount == 1` and `cancelCalls >= 1`, the state is `.idle`, and a later `emit(.captureStarted)` / `emit(.final("x"))` changes nothing (stale). Repeat with `.screenLocked` (via `CoordFakeLock.set(locked:)`) instead of `.cancelRequested`, and with `dispatch(.talkReleased(heldSeconds: 0.5))` (R21: a hold of at least 0.35 s released before the first buffer). `startCount == 1` BEFORE any `settle`: it proves `start` was called synchronously by the effect.
- `testAuditUnwritableConvertsAgentApprovalToDeny` (`CoordGatedBackend` + a failing `CoordRecordingAudit`): an agent turn reaches `awaitingApproval` with a card (T2, nonce `c1`, risk `[]`; tool name `clock` first); then make the audit fail (`failing = true`) and `settle` until one more `.audit` append has been attempted (any dispatch that audits, for example a wrong-nonce `model.approve(nonce: "zzz")`, which audits `nonce_mismatch`); then `model.approve(nonce: "c1")`: `XCTAssertEqual(backend.responses.count, 1)`, `XCTAssertEqual(backend.responses.first?.nonce, "c1")`, `XCTAssertEqual(backend.responses.first?.allow, false)`, and the turn is still open (state `acting`). With a healthy audit the same flow records `allow == true` (this pins the one-record lag of A.4 as the only gap).
- `testInterruptCaptureStartsTheRecognizerEvenAfterATypedSubmit` (A.6): lane ready, `submitTyped("what is the weather")`, the review timer elapses (state `thinking`, `CoordGatedBackend` open), then a real `.pressed` key event (R100): `CoordHeldRecognizer.startCount == 1` (the interrupt capture is NOT swallowed by `typedFlow`).
- `testVoiceOffResetsTheLaneStatus`: lane `.ready`, then voice off: `model.hermesLaneStatus == .off`; a lane check that is still in flight (gate the double's `preflight` with a continuation) does not write `.ready` after voice went off.

`DailyTurnCounterTests`: remaining/increment/new day/corrupt/limit.

**Part A gate (P2).** Build clean; the warning check prints nothing; the new tests and the whole suite green; `git status` only in your files; lint and ownership checks (section 4, Part A list). Then **stop**: Part A ends here and the orchestrator gates, reviews and commits it before Part B is started. Then a **manual check on the Mac mini** (it launches the app, so it needs the installed `/Applications/desnotch.app` to be quit by the human first; if it is running, report these items as `NOT RUN: installed desnotch is running` and hand the exact steps to the human. They are HUMAN items (PLAN section 11): they are never retried, never worked around, and never block the import or the commit; you NEVER quit, kill or restart the installed app. Report each item you do run as DONE/NOT DONE and what you saw):

1. `swift build` then `DESNOTCH_VOICE_DEBUG=1 swift run` (or the packaged app), enable "Voice control" in Settings (enabling does NOT prompt; the Microphone and Speech prompts appear only when you press the Settings "Allow Access…" button, and the typed path needs neither), use the status menu "Type a Voice Command…": `volume thirty`, `mute`, `unmute`, `play`, `pause`, `timer one minute`, `open safari`, `volume ninety` (a card must appear; Deny it; again and Approve it), `cancel` (ambiguous), `abort agent`. Each must behave per the tables in `docs/voice/PLAN.md`; the review banner shows for 1.5 s; Esc is not captured at idle. Also switch Voice control off and on again in Settings, then hold the hotkey: it must still work (the hotkey source is rebuilt on every enable).
2. `~/Library/Application Support/desnotch/voice/voice-audit.jsonl` exists with mode 0600, contains no spoken text, and `python3 -I scripts/voice-harness/verify-audit.py "$HOME/Library/Application Support/desnotch/voice/voice-audit.jsonl"` prints a line starting `verify-audit: ok`.
3. With Voice control OFF: no new process threads for audio, no hotkey registered (try ⌥⌘V in another app), idle CPU unchanged. Measure it, before and after the change and with voice off: `for i in 1 2 3; do ps -o %cpu= -p "$(pgrep -x desnotch)"; sleep 10; done` (three samples 10 s apart; the pill is idle, so each reading stays near 0.0 and does not exceed the pre-change readings by more than 0.5).

## Part B: the Hermes lane

(Part B starts from a fresh worktree that already contains the committed Part A.)

### B.1 What you may read (read-only) to learn the shapes

Under `~/.hermes/hermes-agent/` ONLY Python source: `acp_adapter/entry.py`, `server.py` (methods `initialize`, `new_session(cwd, mcp_servers)`, `prompt`, `cancel`), `permissions.py` (the permission option ids are exactly `allow_once`, `allow_session`, `allow_always`, `deny`, `deny_always`), `events.py`, `tools.py`, `session.py`; the `acp` Python package's `schema.py` (find it with `find ~/.hermes/hermes-agent -path '*site-packages/acp/schema.py'`); `hermes_cli/` profile code and `tools/approval*.py`. The facts you need are already verified and listed below with their source lines; record them in a code comment at the top of `HermesPreflight.swift` as `file:line` (re-check the lines; they can drift). Also record there, as a P6 comment, that the preflight cannot see toolsets Hermes adds on its own even with `platform_toolsets.acp: []` (for example `x_search` when xAI credentials exist, `hermes_cli/tools_config.py` `_composite_toolsets`, and `_recover_platform_native_toolsets`), and that this still fails closed because such a tool is not allowlisted, classifies T3 and trips R83. If you cannot confirm a fact, implement the preflight to REFUSE and say so in your report.

### B.2 Transport

`ACPTransport` (`ACPTransport.swift`): a `Sendable` protocol: `func start() throws`, `func send(line: Data) throws`, `var lines: AsyncStream<Data>`, `func terminate()`, `var processID: Int32? { get }` (the child's pid, which is also its process-group id; `nil` for the scripted transports of the tests, so the guard falls back to `terminate()` alone for them), and **`var workingDirectory: URL { get }`**: the session's `cwd`. `ProcessACPTransport` creates `<workingDirectoryRoot>/desnotch-voice-<uuid>` (mode 0700) in `init` or `start()` (decide once, document it, and make `workingDirectory` stable from then on) and deletes it in `terminate()`/shutdown; `HermesFakeTransport` returns a fixed absolute URL (for example `/tmp/desnotch-voice-test`, nothing is created for it). `ACPClient.handshake()` sends exactly `transport.workingDirectory.path` as `session/new`'s `cwd`, so the client never invents a path (B.4, and the `cwd == transport.workingDirectory.path` assertion in B.9). Newline-delimited JSON-RPC 2.0 (reuse `AdapterLineBuffer`). `ProcessACPTransport` spawns `/usr/bin/perl -MPOSIX=setsid -e 'setsid(); exec {$ARGV[0]} @ARGV; exit 127' <hermesPath> -p voice acp` (the same fixed launcher `SubprocessRunner` uses, so the child leads its own session and process group, `pgid == pid`), environment `SubprocessRunner.sanitizedEnvironment()` (keeps `HOME`), stdin/stdout pipes, stderr to `FileHandle.nullDevice`, working directory = a fresh empty temp directory (`FileManager.default.temporaryDirectory/desnotch-voice-<uuid>`, removed on shutdown). All pipe callbacks run on one serial queue and carry a generation (copy the `MediaRemoteBridge` pattern: stale callbacks from a dead process must not touch the new stream).
**Test injection.** The command is injectable: `struct ACPLaunch: Sendable { var perl: URL; var arguments: [String] }` with `static func hermes(path: URL) -> ACPLaunch` as the production value, and `ProcessACPTransport.init(launch: ACPLaunch, workingDirectoryRoot: URL)`; `HermesProcessGuard` takes the same `ACPLaunch` and a `pidFileDirectory: URL` (production: `~/Library/Application Support/desnotch/voice`; tests: a UUID temp directory). The real-process tests (B.6) point it at `/bin/sh -c '...'` through the same perl launcher. `ACPLaunch` lives in `ACPTransport.swift`; it has a test-only convenience, `static func command(_ shellCommand: String) -> ACPLaunch` (declared in `HermesFixtures.swift` as an extension, NOT in the production file), which builds `ACPLaunch(perl: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-MPOSIX=setsid", "-e", "setsid(); exec {$ARGV[0]} @ARGV; exit 127", "/bin/sh", "-c", shellCommand])`, so every real-process test gets the same own-session, own-process-group child as production.

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
struct HermesLocator { init(candidates: [URL] = default, isExecutable: @escaping @Sendable (URL) -> Bool = default); func hermesURL() -> URL?; static func voiceProfileConfigURL() -> URL }   // the closure is stored, so it is @escaping
enum HermesPreflight {
    static func run(locator: HermesLocator, configReader: ConfigReading, fileFlags: FileFlagReading) -> AgentPreflightResult
    static func checkProtocol(_ version: Int) -> AgentPreflightResult?   // nil = fine; .refused(.protocolMismatch) otherwise; P8, called by ACPClient after `initialize`
}
```

Where the declarations live: `ConfigReading`, `FileFlagReading`, `VoiceProfileConfigReader`, `VoiceProfileFlagReader`, `HermesToolsetPolicy` and `HermesPreflight` in `HermesPreflight.swift`; `HermesLocator` in `HermesLocator.swift`; `ScanValue`, `MiniConfigScanError`, `MiniConfigScan` in `MiniConfigScan.swift`; `HermesACP` in `ACPClient.swift`. Real readers: `VoiceProfileConfigReader: ConfigReading` reads `HermesLocator.voiceProfileConfigURL()` = `NSHomeDirectory()/.hermes/profiles/voice/config.yaml` (profile layout: `hermes_cli/profiles.py:287-290,442`); `VoiceProfileFlagReader: FileFlagReading` does `stat` on the same path and returns `st_flags`. `HermesLocator.hermesURL()`: first executable among `NSHomeDirectory()/.local/bin/hermes`, `/opt/homebrew/bin/hermes`, `/usr/local/bin/hermes`. `run` has NO `protocolVersion:` parameter (P8 is live inside `ACPClient`). Checks, in order; the first failure is returned:

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

`MiniConfigScan` is a tiny YAML-subset reader (no dependency): `key: value` scalars, nested maps by consistent two-space-multiple indentation, block lists (`- x`), flow `[]`/`{}` on one line, `#` comments, single/double quoted scalars. It indexes the TOP-LEVEL keys (column 0) and interprets ONLY the four sections the preflight reads (`approvals`, `command_allowlist`, `mcp_servers`, `platform_toolsets`); every other top-level section of a real Hermes config (model, display, long folded strings, lists of maps...) is skipped line by line without being interpreted, up to the next column-0 key. Inside the four sections anything unsupported (anchors/aliases/merge keys `&x *x <<:`, block scalars `|` `>`, tabs, lists of maps) throws `.unsupported`; a tab or a second document marker (`---` after the first line, `...`) ANYWHERE throws; **a duplicate key in the four sections (or a duplicate top-level key of one of them) throws `.unsupported`** (PyYAML keeps the LAST duplicate, so a first-wins scanner would read `mode: manual` while Hermes uses `mode: off`). **Two cases that must not be left open:** (1) a NON-empty single-line flow collection inside the four sections (`command_allowlist: [rm]`, `approvals: {mode: off}`, `platform_toolsets: {acp: [terminal]}`) is PARSED (flow lists of plain/quoted scalars become `.list`, flow maps of scalars/flow lists become `.map`, nested to any depth on one line, no multi-line flows); a flow collection the scanner cannot parse completely (unbalanced brackets, a comma inside an unquoted scalar it cannot split, a flow that continues on the next line) throws `.unsupported`. So `approvals: {mode: off}` is read as mode `off` (P3 refuses) and `command_allowlist: [rm]` as a non-empty list (P4 refuses). (2) A QUOTED KEY inside the four sections (`"approvals":`, `'mode':`) throws `.unsupported`, because a quoted duplicate (`mode: manual` plus `"mode": off`) would defeat the duplicate-key check; a quoted top-level key whose unquoted form is one of the four section names throws too (a quoted top-level key of any other name is skipped like any other unrelated section). Tests for all of these are in `MiniConfigScanTests`. Run the preflight on EVERY process spawn and EVERY new ACP session, never cached, and refresh `model.hermesLaneStatus` (`.checking` -> `.ready` or `.refused(reason)`).

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

Lenient decoding (`JSONSerialization` into dictionaries; unknown fields ignored; a malformed line is dropped). It speaks only: `initialize` (declare NO client capabilities: no file system, no terminal; check the reported `protocolVersion` with `HermesPreflight.checkProtocol`), `session/new` (`cwd` = `transport.workingDirectory.path`, `mcpServers: []`), `session/prompt` (one text content block, the utterance), `session/cancel`, and answers `session/request_permission`. Notifications `session/update` carry the updates. Any other agent->client REQUEST is answered with JSON-RPC error `-32601` (method not found). Request ids are monotonically increasing integers; responses are matched by id; a timeout of 20 s on `initialize`/`session/new` and none on the streaming `prompt`. The wire keys are camelCase. The literal requests we send (the implementer re-checks them against `acp/schema.py`; if one differs, the schema wins and the report says so):

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/private/var/.../desnotch-voice-<uuid>","mcpServers":[]}}
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"s1","prompt":[{"type":"text","text":"<utterance>"}]}}
{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s1"}}
```

`session/cancel` is a NOTIFICATION (no `id`, no response). Fields we read from results: `initialize` -> `result.protocolVersion` (an integer); `session/new` -> `result.sessionId` (a string); `session/prompt` -> `result.stopReason` (B.5). Everything else in a result is ignored.

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

Suggested shape (the type name is fixed; tests need the seams marked *):

```swift
final class HermesProcessGuard: @unchecked Sendable {          // all mutable state behind one lock, sync helpers only
    init(launch: ACPLaunch, pidFileDirectory: URL, workingDirectoryRoot: URL,
         transportFactory: @escaping @Sendable (ACPLaunch, URL) -> ACPTransport = { ProcessACPTransport(launch: $0, workingDirectoryRoot: $1) })   // *
    func ensureRunning() throws -> ACPTransport     // crash recovery of a stale pid file, then spawn if nothing is running; returns the live transport
    var liveTransport: ACPTransport? { get }        // *  the process-guard test reads `lines` from it before calling the hard stop
    func hardStop(sendCancel: @Sendable () -> Void) async -> EmergencyStopReport    // the emergencyStop() steps below
    func terminateNow()                             // synchronous, idempotent
    func shutdown() async
}
```

- Spawn lazily on the first submit; keep it for the idle window (10 minutes) to keep the prompt cache; then `shutdown()` (SIGTERM the group, 0.5 s, SIGKILL). Kill on `stop()`/app termination.
- **`terminateNow()` (synchronous, on `HermesProcessGuard` and re-exported by `HermesAgentBackend`).** No `Task`, no `await`, callable from any thread, idempotent, returns only when finished: `killpg(pgid, SIGTERM)`, poll the SAME `alive(pid)` helper that `hardStop` uses (`kill(pid, 0) == 0` AND not a zombie) every 10 ms for at most 0.5 s, `killpg(pgid, SIGKILL)`, remove the pid file. (The direct child is a zombie of desnotch's own `Process` until it is reaped, and a zombie still answers `kill(pid, 0)`: a bare `kill(pid, 0)` loop would always wait the full 0.5 s on the main thread at quit.) `VoiceCoordinator.stop()` reaches it through `terminateAgentNow`, and `AppComposition.stopOwnedResources()` may call it too; this is what prevents an orphaned `hermes acp` at quit.
- Crash recovery: write `~/Library/Application Support/desnotch/voice/hermes-acp.pid` (pid + launch time) into the injected `pidFileDirectory`. On the next start, if it names a live pid whose command line contains both `hermes` and `acp`, kill THAT process group and remove the file. Never scan for other hermes processes. **How to read the command line (synchronous, bounded).** `SubprocessRunner.run` is `async`, but `ensureRunning() throws -> ACPTransport` is synchronous and runs under the backend's spawn lock, so do NOT use `SubprocessRunner` and do NOT make `ensureRunning` async. Run `/bin/ps -p <pid> -o command=` synchronously with `Process` and a `Pipe` (precedent for running `/bin/ps`: `ProcessMonitor/ProcessSampler.swift:45`, which uses the async runner; here it must be a synchronous `Process`), read at most 4 KB of its output, and wait at most 2 s (`terminate()` the `ps` if it is still running at the deadline). On ANY error (launch failure, timeout, non-zero exit, undecodable output, pid not alive) treat the pid as not ours: delete the pid file and kill nothing. **The pid-file directory:** before writing the pid file the guard calls `FileManager.default.createDirectory(at: pidFileDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])` (the audit logger only creates `~/Library/Application Support/desnotch/voice` once voice has run once), and the pid file itself is mode 0600.
- Restart backoff: reuse `AdapterRestartBackoff` (`MediaRemote/MediaRemoteBridge.swift:366`: `mutating func nextDelay(afterUptime: TimeInterval?) -> TimeInterval` and `mutating func recordHealthyOutput() -> Bool`). When the child exits on its own (mid-turn or before the handshake finished) the guard calls `nextDelay(afterUptime: <seconds the child lived>)` and stores `retryNotBefore = now() + delay`. A `submit`/`ensureRunning` that arrives while `now() < retryNotBefore` FAILS FAST with `.failed(.agentFailed("backoff"))` and spawns nothing (it never sleeps); a successful handshake calls `recordHealthyOutput()`. A process that dies mid-turn yields `.failed(.agentFailed("process_exited"))`. Test with the injected `now` and a transport factory whose transport ends its `lines` stream right after `start`: the immediate second submit gets `backoff`, and a submit after the delay (advance the injected clock) spawns again.
- `hardStop(sendCancel:)` (this is what `emergencyStop()` runs): (1) snapshot all descendant pids of the child (`proc_listchildpids`, recursively), (2) call `sendCancel()` (the backend sends `session/cancel`), (3) wait `VoiceTiming.hardStopGrace` (0.5 s), (4) `killpg(pgid, SIGTERM)`, (5) wait 0.5 s, (6) `killpg(pgid, SIGKILL)`, (7) poll every 10 ms for up to 0.5 s until no snapshot pid is a survivor, (8) `survivors` = names (via `proc_name`) of snapshot pids that are still alive. **A pid is alive only if `kill(pid, 0) == 0` AND it is not a zombie** (`proc_pidinfo(pid, PROC_PIDTBSDINFO, ...)`, `pbi_status != SZOMB`): a killed but not yet reaped process still answers `kill(pid, 0)`, which would make the report flaky. Then drop the transport (the next submit respawns). A transport whose `processID` is `nil` (a test transport) is only `terminate()`d.
- Tests (`HermesProcessGuardTests`) run a REAL tiny process tree, not Hermes, with deterministic "the tree is up" signals and no sleeps. Every test builds its launch with the test helper `ACPLaunch.command(...)` of B.2 (the same own-session launcher as production) and owns a UNIQUE marker (a distinct `sleep` argument that nothing else on the machine uses), so a `pgrep -fx` can prove the test left nothing behind. Markers: `61` tree test, `62` setsid survivor test, `63` negative stale-pid-file test, `64` `terminateNow` test, `66` positive stale-pid-file test. Always kill leftovers in `tearDown`, by exact pid with `kill(pid, SIGKILL)` (never `pkill`/`killall`).
  - `testHardStopKillsTheWholeTree` (marker `61`): `ACPLaunch.command("sleep 61 & sleep 61 & echo tree-up; wait")`, `ensureRunning()`, await the line `tree-up` from `liveTransport.lines`, collect the descendant pids (`proc_listchildpids` of `processID`), THEN `await hardStop(sendCancel: {})`; assert `kill(pid, 0) != 0` (or zombie) for both `sleep 61` pids and `report.survivors.isEmpty`.
  - `testHardStopReportsAProcessThatLeftTheGroup` (marker `62`, the survivor test). The launch target is EXACTLY this Swift raw string (the argument of `ACPLaunch.command`, i.e. the `-c` argument of `/bin/sh`):

    ```swift
    ACPLaunch.command(#"/usr/bin/perl -MPOSIX=setsid -e "\$|=1; setsid(); print qq(setsid-up \$\$\n); sleep 62" & wait"#)
    ```

    **Why the `&`:** the guard's launcher makes the shell the session and process-group leader; a process that is already a group leader cannot call `setsid()` (it fails with `EPERM`) and then dies with the group, so it would not be a survivor. With the `&` the inner perl is a non-leader grandchild, so `setsid()` succeeds, it becomes its own session and group leader (its pgid is its own pid, verified), `killpg` of the shell's group does not reach it, and it is a genuine survivor. Await the line `setsid-up <pid>` from `liveTransport.lines`, parse the pid, call `hardStop`, then assert `report.survivors == ["perl"]` (`survivors` holds process BASENAMES from `proc_name`, a `[String]`, so assert the name, not the pid), assert `kill(pid, 0) == 0` and that the process is NOT a zombie (so the report is not an artifact of an unreaped corpse), and in `tearDown` kill EXACTLY that parsed pid with `SIGKILL`. Its command line is the long perl line, not `sleep 62`, so `pgrep -fx 'sleep 62'` can never match it: the Part B gate checks it with a different pattern (B gate), and the exact-pid `tearDown` is the real cleanup.
  - `testTerminateNowKillsTheTreeSynchronously` (marker `64`, its OWN marker; do not reuse `61`): the tree of the first test with `sleep 64`, `terminateNow()` called with no `await`; assert both pids are gone immediately after it returns.
  - `testStalePidFileForAnUnrelatedProcessIsNotKilled` (marker `63`): start a harmless live `sleep 63` yourself with a plain `Process` (its command line does NOT contain `hermes` and `acp`), write its pid into the pid file by hand, build a guard on that `pidFileDirectory` and call `ensureRunning()` (harmless launch such as `ACPLaunch.command("echo ready; wait")`); assert the `sleep 63` is STILL alive and the pid file now names the NEW child.
  - `testStalePidFileForALeftoverAcpIsKilled` (marker `66`, the positive case): guard A launches `ACPLaunch.command("echo up; sleep 66 & wait # hermes acp")` (verified: the shell's `ps -p <pid> -o command=` line is `/bin/sh -c echo up; sleep 66 & wait # hermes acp`, which contains both `hermes` and `acp`; the shell leads its own process group), awaits the line `up` from `liveTransport.lines`, and is then DROPPED without `shutdown()`/`terminateNow()` (a simulated crash: the pid file stays); guard B on the same `pidFileDirectory` calls `ensureRunning()`; assert the old `sleep 66` and its shell are gone and the pid file names B's child. Before killing, the guard verifies `getpgid(pid) == pid` (the child is a group leader by construction) and kills nothing otherwise.
  - A pure test of the matching helper the guard uses on the `ps` output, `static func isHermesACP(commandLine: String) -> Bool` (true only when the text contains both `hermes` and `acp`, case-insensitive): positive, negative, empty string.

### B.7 `HermesAgentBackend: AgentBackend`

Wraps locator + preflight + guard + client. It is the single instance `AppComposition` holds (A.1). Fixed seams (type and parameter names are exact because the tests need them; helpers are yours):

```swift
final class HermesAgentBackend: AgentBackend, @unchecked Sendable {          // ALL mutable state behind one lock (sync helpers only) or one serial queue
    init(locator: HermesLocator = HermesLocator(), configReader: ConfigReading = VoiceProfileConfigReader(),
         fileFlags: FileFlagReading = VoiceProfileFlagReader(), launch: ACPLaunch? = nil,   // nil = ACPLaunch.hermes(path: locator.hermesURL())
         pidFileDirectory: URL = FileAuditLogger.defaultDirectory(),
         transportFactory: @escaping @Sendable (ACPLaunch, URL) -> ACPTransport = { ProcessACPTransport(launch: $0, workingDirectoryRoot: $1) },
         scheduler: HermesScheduling = DispatchHermesScheduler(), now: @escaping @Sendable () -> Date = { Date() })
    func terminateNow()            // synchronous; re-exports the guard's
}
```

`preflight()` runs B.3 (and the live check P8 when connected). The `ACPClient` (suggested: `init(transport:mapper:now:newNonce:)`, `func handshake() async throws -> String` returning the session id, `func prompt(_:) -> AsyncStream<AgentEvent>`, `func respond(nonce:allow:)`, `func cancel()`) and `HermesEventMapper` (a value type with `mutating func ingest(...)` taking `at: Date`) are internal to Part B; their tests drive them with a scripted `ACPTransport`.

**Turn epoch (the stop and cancel guarantees; read twice).** `submit` is a synchronous function that returns the stream; it takes its epoch snapshot BEFORE it returns (the coordinator calls it synchronously, A.3) and does the asynchronous work (preflight, spawn, handshake, prompt) in its own task. The backend keeps an integer `epoch`. `cancelTurn()`, `emergencyStop()`, `shutdown()` and `terminateNow()` each do `epoch += 1` as their FIRST action, under the lock. `submit` takes `myEpoch = epoch` when it is called and RE-CHECKS `epoch == myEpoch` (a) after the preflight returns, (b) after the process is spawned, (c) after `session/new` returns, and (d) immediately before `session/prompt` is sent. On a mismatch it aborts: it sends NO `session/prompt`, it terminates the process it spawned in this very call (if no other turn uses it), and it finishes the stream with `.failed(.agentFailed("stop_cancelled"))`. Spawn happens under the lock, so `emergencyStop()` either sees the child or runs before the spawn, and in the latter case check (b) kills the new child. Without this, a STOP during `thinking` (when the backend may still be preflighting, spawning or about to send the prompt) would find no child, return, and the in-flight submit would then spawn and prompt anyway, and every event of that unobserved agent would be stale (R01) and ignored, tripwire included.

`submit(utterance)` (called by the coordinator for `.submitToAgent`):
0. **No slash commands.** Hermes treats any prompt whose text starts with `/` as a slash command (`acp_adapter/server.py:833-834`: `/model`, `/compress`, ...). If the first non-whitespace character of `utterance` is `/` (a spoken transcript will not normally start with one, but the typed debug path can), finish with `[.failed(.agentFailed("slash_prefix"))]` and touch nothing (no preflight, no spawn, no `.status("started")`, so the daily counter is not charged). Strip nothing: refusing is the safe choice.
1. If a prompt is already in flight (an active turn that is neither cancelled nor terminal): finish with `[.failed(.agentFailed("busy"))]` and touch nothing.
2. If `killPending` is set (a cancelled turn's process may still be alive, see `cancelTurn`): complete the kill NOW (group SIGTERM, up to 0.5 s, SIGKILL, drop the transport, clear the flag) BEFORE anything else, so a new utterance is never submitted into a possibly still-running session.
3. Re-run preflight; refused => stream `[.failed(.preflightRefused(reason))]` (the coordinator maps that to `model.setHermesLaneStatus(.refused(reason))` and an audit record, A.3). Epoch check (a).
4. Ensure the process is running (spawn, `initialize`, `session/new` once per process; reuse the session for the idle window). Epoch checks (b) and (c).
5. Epoch check (d), then send `session/prompt`, then emit `.status("started")` (the coordinator increments `dailyTurns` when it sees it).
6. Forward the mapped events; the stream ends after `.finished`/`.failed`.

`cancelTurn()` (the reducer's soft cancel: Esc, spoken "stop", the 180 s budget R89, the 12-step budget R82): bump the epoch; if a turn is in flight send `session/cancel`, set `killPending = true`, and schedule through the injected `scheduler` a hard kill after `VoiceTiming.hardStopGrace`; if the prompt response arrives before that, cancel the scheduled task and clear `killPending`. When the task fires it does the same process-group kill as `emergencyStop()` (no reducer change, no coordinator involvement) and drops the transport. Finish the turn's stream with `.failed(.agentFailed("stop_cancelled"))` only if no terminal event was sent (the reducer has already left the turn, so the event is ignored, but the consumer's loop ends). A soft cancel alone does nothing to an agent that ignores it; this escalation is what makes the 180 s and 12-step budgets real.

**Late activity after a cancel.** A first-sighting `tool_call` (or any `.toolActivity` the mapper would emit) that belongs to a turn whose epoch is no longer current triggers the hard kill IMMEDIATELY (the reducer is no longer watching that turn, so nobody else would trip the wire); a `session/request_permission` that belongs to such a turn is answered `deny` first, then the kill. `emergencyStop()` runs the guard's `hardStop(sendCancel:)` and returns its report.

`respond`, `shutdown`, `terminateNow` as above. The 60 s auto-deny of an unanswered permission request and the 10-minute idle shutdown use `scheduler`.

**Part B wiring in `AppComposition.swift` (the only Part B edit outside `Voice/Hermes`):** keep ONE stored `private var hermesBackend: HermesAgentBackend?` (nil in smoke-test mode, which keeps the app "inert in smoke-test mode"). In the same `!smokeTestMode` branch that builds the coordinator, create a LOCAL NON-OPTIONAL `let backend = HermesAgentBackend()` (constructing it spawns nothing), assign `hermesBackend = backend`, and pass `backend: backend` (the coordinator parameter is a non-optional `AgentBackend`, so never pass the optional property) and `terminateAgentNow: { [backend] in backend.terminateNow() }` instead of the Part A `NullBackend()` / default. Call `hermesBackend?.terminateNow()` in `stopOwnedResources()` right after `voiceCoordinator?.stop()` (idempotent; optional chaining, so nothing is instantiated just to be terminated).
**Clock and timers are injected.** The backend takes `now: @Sendable () -> Date` (given to the mapper as `at:`) and a small scheduler seam, because its 60 s permission auto-deny, its 10-minute idle shutdown and the cancel escalation cannot use the `@MainActor` `VoiceTimerScheduling`:

```swift
protocol HermesScheduledTask: Sendable { func cancel() }
protocol HermesScheduling: Sendable { func schedule(after seconds: Double, _ action: @escaping @Sendable () -> Void) -> HermesScheduledTask }
```

Real: `DispatchHermesScheduler` (a `DispatchQueue` timer). `HermesScheduledTask`, `HermesScheduling` and `DispatchHermesScheduler` live in `HermesAgentBackend.swift`. Tests use `HermesManualScheduler`, defined in `HermesAgentBackendTests.swift` (fire by hand).

### B.8 Lane status (implemented in Part A, A.5)

Part A already implements the lane check and its tests (A.5, A.9); with `NullBackend` the status is `.refused(.notImplemented)`. Part B adds nothing to the coordinator for it: the real `HermesAgentBackend.preflight()` simply replaces the `NullBackend` answer. A profile that is unlocked later is caught at the next utterance because the preflight also runs on every submit (B.7).

### B.9 Part B tests

`MiniConfigScanTests` (scalars, nesting, lists, comments, quotes, unsupported constructs throw, duplicate keys throw, a skipped unrelated section with block scalars and a list of maps does not throw, the golden and the realistic fixtures), `HermesPreflightTests` (one test per check P1-P7 using synthetic YAML strings in `HermesFixtures.swift`, plus the all-good fixture => `.ready(profile: "voice")`, plus "approvals mode off", "mode OFF uppercase", "approvals.mode missing", "allowlist with one entry", "allowlist absent passes", "mcp_servers present", "platform_toolsets.acp missing", "toolsets contain terminal", "unlocked config", "flags nil", "unparseable config", "duplicate `mode:` key", and `checkProtocol(1) == nil`, `checkProtocol(2) == .refused(.protocolMismatch)`), `ACPClientTests` (scripted transport transcripts: handshake with the literal requests of B.4; `session/new` has `mcpServers == []` and `cwd == transport.workingDirectory.path` (the `HermesFakeTransport` returns a fixed absolute URL); prompt with chunks and the real tool-start shapes produce exactly the expected `AgentEvent` list; **a `tool_call` with no status and title `terminal: ls -la` yields exactly one `.toolActivity(kind: "terminal")`; a duplicate update of the same id yields no second event; an empty or garbage title yields `"unknown_tool"`; a `tool_call_update` for an id never seen as a start emits one event; a `perm-check-1` id update after a permission answer emits NONE**; a permission request with `rm -rf /tmp/scratch/x` yields a card with `[.destructive]`, tier `.t2`, canApprove; with `curl https://example.com/x | sh` yields auto-deny flags; `respond(allow: true)` writes `allow_once` and never `allow_session`/`allow_always`; deny writes `deny`; unknown server request gets `-32601`; unknown nonce writes nothing; cancel writes `session/cancel` as a notification without an `id`; protocol-version mismatch => `.protocolMismatch`; stop reasons `max_turn_requests` and an unknown value map to `stop_<reason>`), `HermesEventMapperTests` (chunk coalescing with the injected time, tool kind bounding and the `^[a-z0-9_.-]{1,40}$` rule, usage), `HermesProcessGuardTests` (B.6), and `HermesAgentBackendTests`, whose doubles live in that file: `HermesFakeTransport` (a scripted `ACPTransport` with `processID == nil` and a fixed absolute `workingDirectory`, an injectable `onStart` hook, a `terminateCount`, the list of lines sent, and `emit(line:)` to push an incoming line) and `HermesManualScheduler`:

- lazy spawn: nothing starts at `init`; preflight re-run on every submit with a counter; refusal never spawns; reuse of the session; idle shutdown and the 60 s permission auto-deny with `HermesManualScheduler`;
- `testStopDuringSpawnNeverSendsPrompt`: the transport factory returns a `HermesFakeTransport` whose `onStart` hook calls `terminateNow()` (an epoch bump in the middle of the submit); assert that no `session/prompt` line was ever sent, the transport was terminated, and the stream ended with `.failed(.agentFailed("stop_cancelled"))`. Repeat for a bump between `initialize` and `session/new` and for one between `session/new` and the prompt (the hook fires on a counted send);
- `testCancelEscalatesToKillWhenAgentIgnoresIt`: a prompt is in flight; `cancelTurn()`; assert a `session/cancel` line was sent and `terminateCount == 0`; fire the `HermesManualScheduler` task scheduled for `VoiceTiming.hardStopGrace`; assert `terminateCount == 1` and that the next `submit` spawns a NEW transport;
- `testCancelWithPromptResponseBeforeGraceDoesNotKill`: after `cancelTurn()` the prompt response arrives; the scheduled kill is cancelled (firing it does nothing) and `terminateCount == 0`;
- `testLateToolStartAfterCancelKills`: after `cancelTurn()` (grace not fired) the transport emits a first-sighting `tool_call` line; assert `terminateCount == 1` immediately, with no scheduler firing; a late `session/request_permission` is answered `deny` and then kills;
- `testSubmitWhileCancelledProcessAliveCompletesTheKillFirst`: `cancelTurn()`, then `submit` before the grace task fires: the old transport is terminated BEFORE the new one is created, and the new `session/prompt` goes to the new transport;
- `testSubmitWhilePromptInFlightIsRefusedBusy`: a second `submit` while the first prompt is open yields `.failed(.agentFailed("busy"))` and sends nothing;
- `testEmergencyStopDuringPreflightLeavesNothingRunning`;
- `testSlashPrefixedUtteranceIsRefusedWithoutSpawning`: `submit("/model gpt")` and `submit("  /compress")` finish with `.failed(.agentFailed("slash_prefix"))`, the preflight counter is 0, no transport was created and no `.status("started")` was emitted; `submit("what is 1/2")` is NOT refused;
- `testBackoffAfterProcessExitFailsFast` (with `HermesProcessGuardTests` for the guard-level version): after a transport that ends its stream right after `start`, an immediate second `submit` yields `.failed(.agentFailed("backoff"))` and creates no transport; after the injected clock advances past the delay it spawns again;
- `testStopRightAfterSubmitNeverSendsPrompt`: call `submit` (synchronously, as the coordinator does), call `emergencyStop()` BEFORE consuming the stream, then consume it: no process was spawned, no `session/prompt` was sent, and the stream ended with `.failed(.agentFailed("stop_cancelled"))`.

Plus `VoiceCoordinatorHermesTests` (coordinator + `CoordGatedBackend`, reusing the `Coord*` doubles and `CoordTestSupport.settle`; `ScriptedBackend` only for the instant-finish and tripwire cases): the **S3** and **S4** scenarios of the scenario table in `docs/voice/WP-LOGIC.md` ("Scenario tests", rows S3 and S4) through the real coordinator. S3 (the recognizer is `CoordHeldRecognizer`, see A.9: its stream stays open, so nothing ends the capture on its own): lane ready; press (`CoordFakeKeys.send(.pressed)`), `recognizer.emit(.captureStarted)`, release after 1.2 s (`send(.released(heldSeconds: 1.2))`), and ONLY THEN `recognizer.emit(.final("what is the weather in Jakarta"))` (the final must arrive after the release so `captureEndedByUser` is true; a scripted `.final` while the key is held would be R35 and end in R54 `needsUserRelease`, never `.remote`), the review window elapses (fire the 1.5 s timer of `CoordManualTimerScheduler`), the gated backend emits `.toolActivity(kind: "clock")` and `.approvalNeeded` (a T2 card, nonce `c1`, risk `[]`), the test calls `model.approve(nonce: "c1")`, assert `XCTAssertEqual(backend.responses.count, 1)`, `XCTAssertEqual(backend.responses.first?.nonce, "c1")` and `XCTAssertEqual(backend.responses.first?.allow, true)` (an array of tuples is not `Equatable`: never compare `backend.responses` to an array literal) while the turn is STILL open, then the backend emits `.finished(summary: "It is sunny")`, the reply is displayed, the `replyDisplay` timer elapses and the state is idle. S4 (same `CoordHeldRecognizer` rule for the press/release/final that gets the turn to `thinking`): from a `thinking` turn the backend emits `.toolActivity(kind: "terminal")`: the state is `paused`, `backend.emergencyStops == 1` and `model.survivors` is set from the report; `resume`, then a new press arms again. Further tests: tripwire pauses and calls `emergencyStop`; **Esc during `thinking` calls `cancelTurn`** (gated backend, `cancelCalls == 1`); daily counter incremented once per turn; a refused preflight at submit shows `.refused` and routes misses to `.rejected(.notLocalCommand)`; **`testLaneToggledOffMidTurnStillHardStopsTheLiveBackend`** (a turn is `thinking` on a `CoordGatedBackend`, the lane is switched off: the SAME backend instance receives `emergencyStop` (`emergencyStops == 1`) and `shutdown` (`shutdownCalls >= 1`)); `testStopCallsTerminateAgentNow`. (`testHermesLaneFlipOnARealSettingsStoreBecomesReadyOrRefused` now lives in Part A, A.9.)

**Part B gate (P4).** Build clean; the warning check prints nothing; all tests green (full suite); no process left behind by the tests (`pgrep -fx "sleep $m"` for the markers 61, 63, 64 and 66, and `pgrep -f 'setsid-u[p]'` for the marker-62 survivor perl, show nothing after the suite: `-x` matches the whole command line, so the `pgrep` cannot match its own shell, and the bracketed pattern cannot match its own command line; `sleep 62` itself is a perl builtin inside that perl process and has no process of its own); lint clean. Then **stop**: the orchestrator gates, reviews and commits Part B before Part C. The LIVE verification (S1/S4 canary matrix against a real Hermes `voice` profile) is a manual step for the human after he creates and locks the profile; your report must list the exact steps (section 15 of `docs/voice/PLAN.md`) and must NOT claim they were run. It must also contain, so the human can create the profile without reading code: (a) the golden YAML of B.3 verbatim (`HermesFixtures.goldenConfig`), (b) the path `~/.hermes/profiles/voice/config.yaml`, (c) the lock step `chflags uchg ~/.hermes/profiles/voice/config.yaml`, and (d) the expected behavior: because `ToolTierTable` default-denies tools the profile does not list (including Hermes-internal ones such as memory, todo or skills), any tool that classifies T2 or higher ends in a tripwire pause (R83, the tool start arrives before its permission request), so a tripwire pause is the NORMAL outcome of the S1/S4 live runs, not a defect, and the agent approval card and hold-to-approve are reachable only through scripted tests in the MVP.

## Part C: closing documentation

- `AGENTS.md`: add a section "Voice control (`Sources/DesnotchCore/Voice/`)" in the existing style, CONCISE (the repo's own "Maintaining this file" rule: only knowledge useful to almost every future session; point to `docs/voice/PLAN.md` instead of repeating it). Contents: the pipeline in one paragraph; the file layout (Contracts/Logic/Platform/Coordinator/Hermes) and that `Contracts/` is frozen; the load-bearing privacy rules in one short bullet each, with a link to `docs/voice/PLAN.md` section 14 for the full list of 12 (do NOT paste all 12 verbatim): audio never on disk and recognition on-device only; no live content (transcript, reply, command) in logs, the audit log, VoiceOver or the status menu; approvals visual-only, nonce-bound, once/deny only, T3/T4 denied; default-deny tools plus tripwire; the stop is total and signals only processes desnotch spawned; permissions held are Microphone + Speech only (never Accessibility/Automation/Screen Recording/Full Disk Access); "voice is OFF by default and inert in smoke-test mode"; "the Hermes profile `voice` is created and locked by the human; desnotch only reads it; never edit `~/.hermes`"; "Hermes also retains its own transcripts in its `state.db`; our audit log is metadata only"; "with the empty toolset a tool that is T2 or higher trips the wire (a tripwire pause is the normal outcome of an agent tool call in the MVP; agent approval cards are exercised only by tests)"; the harness commands (`scripts/voice-harness/run.sh`, `lint-lite.sh`, the warning check); the deletion path (PLAN section 17). **Also UPDATE the existing statements that voice changes**, do not leave them stale: "An agent needing attention does NOT force the pill open" (an active voice session now holds the pill open); "hover has exactly one authority" (`wantsHover` now has a third input, `voiceActive`; it is still one decision); the "App wiring" note that lists what is nil in smoke-test mode (add the voice coordinator and the Hermes backend); and the Build/run entitlements line (it names calendars only; it now also carries `com.apple.security.device.audio-input`, and `Info.plist` gains the two usage strings).
- `CHANGELOG.md`: under `## Unreleased` add one bullet "**Voice control (experimental, off by default):** ..." describing local commands, on-device recognition, the optional cloud agent lane, and that Microphone and Speech Recognition permissions are requested only when enabled.
- `README.md`: a short "Voice control" section (what it does, how to enable, the local command list, the privacy statements). For the agent lane include the same few lines the Part B report carries: the golden `voice` profile YAML of B.3, its path `~/.hermes/profiles/voice/config.yaml`, `chflags uchg` on it, "the agent lane needs a locked Hermes profile", and the honest expectation that with the empty toolset an agent tool call usually ends in a tripwire pause. Also mention that the default talk shortcut Option-Command-V shadows Finder's "Move Item Here" while Finder is frontmost, and that the other two choices in Settings (Shift-Option-Command-V, Option-Command-J) avoid it.
- Re-run the whole verification below after editing these: the Part C list in section 4 is the union of the Part A and Part B lists plus both packaging smoke runs.

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
  never edit them). The generated `runner/main.swift` prints about 1,700
  baseline `no calls to throwing functions occur within 'try' expression` warnings, and SwiftPM prints every diagnostic twice (a
  `/path/File.swift:L:C: warning:` line, then an indented caret line that starts with `|` and has no file name), so a plain
  `grep 'warning:'` over the raw output is useless. **The warning check** is the command below. SwiftPM prints a file's warnings only
  when it recompiles that file and an incremental harness build skips files it already built, so the check builds into a FRESH
  harness directory (about 40 s) and keeps only lines that START with a file path. It must print nothing (its last `grep -v` exits 1 when there is nothing to print, which is the good outcome: never run it under `set -e` or chain it with `&&`):

  ```sh
  W="$(mktemp -d)"; HARNESS_DIR="$W" scripts/voice-harness/run.sh --filter VoiceContractSmoke 2>&1 \
    | grep -E '^/.*: (warning|error):' | grep -vE '/(main|UpdateCheckerTests)\.swift:'; rm -rf "$W"
  ```

  The only known baseline warnings are the `main.swift` `try` warnings and 4 copies of one actor-isolation warning at
  `Tests/DesnotchCoreTests/UpdateCheckerTests.swift:41`; they are not yours and you must not touch that file. Any other line the check
  prints is yours: fix it. `swift build` never compiles the test target, so a warning or an error in a TEST file shows up only in
  the harness run (and in CI).
  The harness finds a test class only when it is declared on ONE line as `class X: XCTestCase` or `final class X: XCTestCase`,
  and it resets its current class at every column-0 `class`, `struct`, `enum` or `actor`: put helper types and fakes at
  column 0 AFTER the test class (or indent them inside it), and confirm with `scripts/voice-harness/run.sh --list | grep <Class>`
  that every test you wrote is listed.
- `lint-lite.sh` must print `lint-lite: clean (N files)`. Pass your files explicitly
  (`scripts/voice-harness/lint-lite.sh path/one.swift path/two.swift`). It only checks the whitespace rules; CI's SwiftLint also
  enforces `duplicate_imports`, `empty_enum_arguments`, `redundant_discardable_let`, `unused_optional_binding` and
  `void_return`, so check those by eye (only `trailing_whitespace` is an error there): write `case .foo`, not `case .foo(_)`;
  never `if let _ = x` (use `x != nil`) or `let _ = f()` (use `_ = f()`).
- First harness run builds everything into `.build/voice-harness/` inside your worktree (gitignored); it takes about 1 minute
  (about 40 s on the Mac mini). If your shell tool times out after 2 minutes, raise the timeout, or run
  `scripts/voice-harness/run.sh --filter VoiceContractSmoke` once up front so later runs are incremental. `--skip-build` re-runs
  without rebuilding.
- The harness copies your current `Sources/DesnotchCore` and `Tests/DesnotchCoreTests` on every run, so just save and re-run.
- Tests only ever run for real on GitHub Actions (`swift test` on macos-14 with Swift 5.10, and macos-15). The harness uses
  your local Swift 6.1 compiler in Swift 5 language mode, so it can NOT catch every Swift 5.10 actor-isolation error. Follow
  the isolation rules in "Global rules" literally.

**A desnotch is probably already running on this Mac (the installed `/Applications/desnotch.app`).** The app has a
single-instance guard, so a second copy (including `swift run`, `scripts/runtime-smoke-test.sh`, or anything that launches the
app) exits immediately while the installed one runs. NEVER quit, kill or restart the installed app or its adapter process
yourself. Steps that need to launch the app are marked "manual" below: do not attempt them; list them in your report as
`NOT RUN: installed desnotch is running`, and the human runs them after quitting his copy.

Run and report. Run ONLY the list of YOUR part. A `--filter` that matches no test prints `harness: 0 passed, 0 failed` and exits 0, which looks like success: after each filtered run check that N in `harness: N passed` is greater than 0 (or that `scripts/voice-harness/run.sh --list | grep -c <Class>` is greater than 0). The forbidden-pattern commands (`PATTERNS` below) are the passes of `docs/voice/PLAN.md` section 12, "Final checks"; each must print what is stated there. `rg` and the last `grep` of the warning check exit 1 when they print nothing, which is the GOOD outcome: never run these under `set -e` or chain them with `&&`.

```sh
# warning check (all parts): must print nothing
W="$(mktemp -d)"; HARNESS_DIR="$W" scripts/voice-harness/run.sh --filter VoiceContractSmoke 2>&1 \
  | grep -E '^/.*: (warning|error):' | grep -vE '/(main|UpdateCheckerTests)\.swift:'; rm -rf "$W"

# PATTERNS pass 1 (all parts): must print NOTHING, comments included (write a comment that explains a ban without the literal token). The patterns are word-anchored, so FileAuditLogger( and fingerprint( do not match.
rg -n '\bprint\(|\bNSLog\(|\bos_log|\bLogger\(|\.onHover|repeatForever|serve --stop|pkill|killall|hermes pause|osascript|auth\.json|AXIsProcessTrusted' \
  --glob '!**/Logic/CommandRiskScanner.swift' Sources/DesnotchCore/Voice
# PATTERNS pass 2 (all parts): the scanner file. 2a may hit only the `Pat` constants and the protected-path list; 2b must print nothing
rg -n 'osascript|pkill|killall|auth\.json' Sources/DesnotchCore/Voice/Logic/CommandRiskScanner.swift
rg -n '\bprint\(|\bNSLog\(|\bos_log|\bLogger\(|\.onHover|repeatForever|serve --stop|hermes pause|AXIsProcessTrusted' Sources/DesnotchCore/Voice/Logic/CommandRiskScanner.swift
# PATTERNS pass 3 (all parts): safety invariants, the whole Voice tree INCLUDING the scanner; must print nothing
rg -n 'AVAudioFile|SFSpeechURLRecognitionRequest|URLSession|setVoiceProcessingEnabled|allow_session|allow_always|deny_always|NSAppleScript|AXUIElement' Sources/DesnotchCore/Voice
# diff-based logging check for every file the voice work changed outside Voice/ (AppComposition, UI, status menu...); must print nothing
git diff origin/main -- Sources | rg '^\+.*(\bprint\(|\bNSLog\(|\bos_log|\bLogger\()'
```

**Part A** (coordinator and wiring):

```sh
swift build 2>&1 | grep -E "warning:|error:|Build complete"
scripts/voice-harness/run.sh --filter Coordinator          # VoiceCoordinatorLocalTests
scripts/voice-harness/run.sh --filter DailyTurnCounter
scripts/voice-harness/run.sh --filter VoiceTimers
scripts/voice-harness/run.sh
scripts/voice-harness/lint-lite.sh Sources/DesnotchCore/Voice/Coordinator/*.swift Sources/DesnotchCore/App/AppComposition.swift Tests/DesnotchCoreTests/Voice/Coordinator/*.swift
scripts/voice-harness/check-ownership.sh WP-HERMES
```

plus the warning check and every `PATTERNS` pass above. Part A has no `Hermes/` files: `--filter Hermes`, `--filter ACP` and `--filter MiniConfigScan` match nothing in Part A, and there is no `pgrep` step, packaging step or `Voice/Hermes` lint glob.

**Part B** (the Hermes lane), from a worktree that already contains the committed Part A:

```sh
swift build 2>&1 | grep -E "warning:|error:|Build complete"
scripts/voice-harness/run.sh --filter Coordinator          # regression of Part A, plus VoiceCoordinatorHermesTests
scripts/voice-harness/run.sh --filter Hermes
scripts/voice-harness/run.sh --filter ACP
scripts/voice-harness/run.sh --filter MiniConfigScan
scripts/voice-harness/run.sh
scripts/voice-harness/lint-lite.sh Sources/DesnotchCore/Voice/Coordinator/*.swift Sources/DesnotchCore/Voice/Hermes/*.swift Sources/DesnotchCore/App/AppComposition.swift Tests/DesnotchCoreTests/Voice/Coordinator/*.swift Tests/DesnotchCoreTests/Voice/Hermes/*.swift
scripts/voice-harness/check-ownership.sh WP-HERMES
for m in 61 63 64 66; do pgrep -fx "sleep $m"; done                  # after the suite: must print nothing (-x matches the whole command line, so it cannot match its own shell)
pgrep -f 'setsid-u[p]'                                                   # the marker-62 survivor perl (its command line is the perl one-liner, never 'sleep 62'): must print nothing; the bracket stops the pattern matching its own pgrep
```

plus the warning check and every `PATTERNS` pass.

**Part C** (documentation) runs everything of Parts A and B, then both packaging smoke runs:

```sh
VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
scripts/runtime-smoke-test.sh dist/desnotch.app     # launches the app: needs the installed desnotch NOT running; if it is running, skip and report it, never kill it
HARDENED_RUNTIME=1 VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
```

Pass 1 of `PATTERNS` must print nothing at all, comments included (the scanner's `Pat` constants are why that file is excluded and checked by the allowlist in passes 2a/2b instead; pass 3 covers the scanner too). Done means: every gate above that belongs to YOUR part met (A: the A gate; B: the B gate; C: the full list), plus, for Part A, the manual checks of the A gate reported honestly (the live Hermes checklist is section 15 of `docs/voice/PLAN.md` and is the human's).

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
   - Never call `NSLock.lock()` / `unlock()` inside the body of an `async` function or closure: the Swift 6.1 compiler warns
     "unavailable from asynchronous contexts" (breaking rule 3). Put every locked access in a private SYNCHRONOUS helper
     (`private func appendLocked(...) -> Bool`) and call the helper from the async body. The frozen
     `Tests/DesnotchCoreTests/Voice/VoiceTestSupport.swift` (`ScriptedBackend.recordResponse`) shows the pattern.
3. **No warnings.** `swift build` must be warning-free for the whole package, and the harness build must show no warnings
   from your files. No `// swiftlint:disable`. No `try!` / `as!` / `!` force unwraps in non-test code unless the
   spec above shows one.
4. **No secrets, no real user data.** Never read, print, log or commit `auth.json`, `.env`, keychain items, `~/.ssh`,
   `~/.hermes/config.yaml`, vault or engagement files. Tests use synthetic fixtures only.
5. **Privacy boundary.** A transcript, a command line, a reply text or an audio buffer is live content. Voice code logs
   NOTHING: no `print`, no `NSLog`, no `os_log`, no `Logger` anywhere under `Sources/DesnotchCore/Voice` or in the voice UI files (the
   final-check `rg` bans all of them, in comments too: explain a ban with words, never with the literal token). Surface a failure as a typed `VoiceFailure` (its `code` is what the audit log stores).
   Never write live content to disk (the audit log stores hashes and codes only) and never pass it to VoiceOver announcements.
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
   prefix your package doc prescribes). **File-scope (column 0) helper FUNCTIONS and constants are `private` too** (`private func step(...)`, `private let t0`): an internal helper with the same signature as a `private` one in another file of the module is an "invalid redeclaration" error, while two `private` ones coexist (WP-LOGIC's `env`, `ctx`, `step`, `run`, `t0` are `private` for that reason), and before naming any type run `rg -n "class <Name>|struct <Name>" Tests` and change the name
   on a collision. `Tests/DesnotchCoreTests/Voice/VoiceTestSupport.swift` (frozen) already provides `FakeVoiceClock`,
   `ScriptedRecognizer`, `RecordingExecutor`, `ScriptedBackend` and `InMemoryFileWriter`; use them as they are. A test class that
   touches a `@MainActor` type (`SystemLocalExecutor`, `VolumeDucker`, `CarbonPushToTalk`, `VoiceCuePlayer`, `NSHostingView`,
   `VoiceSessionModel`, `SettingsStore`, or a double that conforms to a `@MainActor` protocol) is declared
   `@MainActor final class XTests: XCTestCase {` (the harness accepts the attribute on the same line or on the line before).
   Doubles that conform to a `@MainActor` protocol are themselves `@MainActor` and can only be created from `@MainActor` code.
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
