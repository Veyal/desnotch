# WP-HERMES: the coordinator, app wiring, and the Hermes (cloud agent) lane

> Self-contained prompt for an external coding agent. You have NOT seen the conversation that produced this plan.
> Implementer: Cursor agent CLI (strong model). **You run only after WP-LOGIC, WP-UI and WP-PLATFORM are merged** into
> `feat/voice`; your worktree already contains their code. Do not commit.

## 1. Background

desnotch is a macOS menu-bar app (SwiftPM, macOS 13+, library target `DesnotchCore`) with a notch pill UI. We are adding
**voice control**, OFF by default. The user holds a hotkey, speaks, and either a fixed local command runs (volume, media, open
an app, timer) or, if enabled, the request goes to the user's local **Hermes** agent (a Python agent; a cloud model sits behind
it). The design (read it): `docs/voice/PLAN.md`. The contracts: `Sources/DesnotchCore/Voice/Contracts/{VoiceTypes,Protocols,VoiceSessionModel,VoiceStubs}.swift`.
The merged work packages gave you:

- `Voice/Logic/*`: the pure brain. `VoiceReducer.reduce(context, event, env:) -> VoiceTransition`, `IntentRouter`, `ConfirmationPolicy`, `ToolTierTable`, `CommandRiskScanner`, `RateLimiter`.
- `Voice/Platform/*`: `AppleSpeechRecognizer` (+`LevelMeter`), `AppleSpeechSynthesizer`, `CarbonPushToTalk`, `ScreenLockMonitor`, `SystemLocalExecutor`, `VolumeDucker`, `FileAuditLogger`, `DiskFileWriter`, `SystemVoicePermissions`.
- UI: `VoiceSectionView`, wings, status-menu items, Settings section, `VoiceCuePlayer`. They only talk to `VoiceSessionModel`.

**Your job has three parts, in this order, each with its own gate:**

- **Part A: the coordinator and app wiring.** The `@MainActor` object that owns the reducer's `VoiceContext`, feeds it events (keys, speech, timers, lock, UI actions, agent), interprets its effects with the real platform objects, and publishes the result to `VoiceSessionModel`. After Part A the **local lane works end to end** (hold the key, say "volume thirty", it happens), including a typed debug entry point that needs no microphone. No Hermes yet.
- **Part B: the Hermes lane.** `AgentBackend` over ACP (the Agent Client Protocol: JSON-RPC over the stdin/stdout of `hermes acp`), with a preflight that refuses to run unless the dedicated locked-down `voice` Hermes profile is in place, an own-process-group supervisor with a hard stop, and approval cards.
- **Part C: closing documentation.** `AGENTS.md`, `CHANGELOG.md`, `README.md`.

## 2. Non-negotiable safety properties (they decide every judgement call)

1. **desnotch never creates, edits, or touches anything in `~/.hermes`.** The profile named `voice` is created and locked by the human (`chflags uchg` on its `config.yaml`). Our code only READS it at runtime for the preflight and refuses the Hermes lane until it checks out.
2. **You (the implementer) must never run `hermes`** (not even `--version`), never read `~/.hermes/config.yaml`, `~/.hermes/profiles/**/config.yaml`, `.env`, `auth.json`, or any secret. You MAY read the Hermes Python SOURCE under `~/.hermes/hermes-agent/` (read-only) to learn the ACP shapes and config key names. All your tests use synthetic fixtures and a scripted fake transport.
3. **Nothing is ever approved by voice.** Approvals are visual, bound to a random nonce, and answered `once` or `deny` only; never `session`/`always`.
4. **Default-deny toolset + tripwire.** The reducer already trips on any tool that is not explicitly allowed (R83). You make sure `AgentEvent.toolActivity` is emitted only when a tool *actually starts running* (not when ACP announces it as `pending`).
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

### A.1 API

```swift
@MainActor
final class VoiceCoordinator {
    init(
        model: VoiceSessionModel, settings: SettingsStore, clock: VoiceClock,
        recognizer: SpeechRecognizing, synthesizer: SpeechSynthesizing, executor: LocalExecuting,
        backend: @escaping @MainActor () -> AgentBackend,        // factory: NullBackend or HermesAgentBackend, asked per use
        audit: AuditLogging, makeKeys: @escaping @MainActor (VoiceHotkeyChoice) -> PushToTalkSource,
        lock: LockStateProviding, ducker: MediaDucking,
        permissions: VoicePermissionProviding, cues: VoiceCuePlaying,
        timers: VoiceTimerScheduling = RunLoopTimerScheduler(),
        dailyTurns: DailyTurnCounter, isPrivacyMode: @escaping @MainActor () -> Bool,
        makeNonce: @escaping () -> String = { UUID().uuidString }, debugTypingEnabled: Bool
    )
    func start()                      // idempotent; begins observing settings. Does nothing visible unless voiceEnabled.
    func stop()                       // app termination or disable: cancel everything, release hotkeys, restore volume, shut the backend down
    func dispatch(_ event: VoiceEvent)  // internal entry; tests call it directly
    func submitTyped(_ text: String)  // debug only
    private(set) var context: VoiceContext
}
```

`VoiceTimerScheduling` (in `VoiceTimers.swift`): `@MainActor protocol VoiceTimerScheduling { func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> VoiceTimerHandle }`, `VoiceTimerHandle.cancel()`. Real: `RunLoopTimerScheduler` (a non-repeating `Timer` on `.common` mode, like `FocusTimerController`'s scheduler; one timer per `(kind, generation)` key; scheduling the same key replaces the old timer). `VoiceTimersTests` uses a `ManualTimerScheduler` test double (also used by the coordinator tests) and tests the real scheduler's replace/cancel semantics with a 10 ms timer and `drainMainQueue`-style waiting.

### A.2 The dispatch loop

`dispatch(event)`: build `VoiceReducerEnv` (below), `let t = VoiceReducer.reduce(context, event, env: env)`, `context = t.context`, **run the effects in order**, then publish: `model.apply(context, reviewDeadline: reviewDeadline)`; arm/disarm the Esc key (`keys.setCancelKeyArmed(context.state != .idle)`, only when the value changes). Re-entrancy: effects may synchronously cause more events (e.g. a fake executor); queue events and drain them in order instead of recursing (a simple `pending: [VoiceEvent]` + `isDispatching` flag).

`VoiceReducerEnv` per call: `now: clock.now()`, `voiceEnabled: settings.voiceEnabled`, `screenLocked: lock.isLocked`, `hermesLaneReady: settings.voiceHermesLane && model.hermesLaneStatus == .ready`, `hermesTurnsRemainingToday: dailyTurns.remaining`, `speechAllowed: settings.voiceTTSEnabled && !isPrivacyMode()`, `secondFactorAvailable: false`, `freshNonce: makeNonce()`.

### A.3 Effect interpreter (exact)

| Effect | What the coordinator does |
|---|---|
| `.startCapture(g, mode)` | remember `captureGeneration = g` and clear the level history. Unless this is a typed flow (A.6): `Task { @MainActor [weak self] ... }` consuming `recognizer.start(localeIdentifier: settings.voiceLocale, contextualStrings: VoiceLexicon.contextualStrings)`, mapping each `SpeechEvent` to `dispatch` with generation `g`: `.captureStarted` -> `.captureStarted(generation: g)` and, if `settings.voiceDuckMedia`, `ducker.duck()`; `.level(x)` -> push into the history and `model.setLevels(LevelMeter.bars(from: history))` (no reducer event); `.partial(s)` -> `.partialTranscript(s, g)`; `.final(s)` -> `.finalTranscript(s, g)`; `.failed(f)` -> `.captureFailed(f, g)`. A stream that finishes without final/failed produces nothing. Drop events whose `g != captureGeneration` (they are stale anyway). |
| `.endCapture(g)` | `recognizer.endAudio()`; `ducker.restore()`. |
| `.cancelCapture(g)` | `recognizer.cancel()`; `ducker.restore()`; clear levels. (Calling `restore()` twice is harmless; the ducker is idempotent. `duck()` must be called at most once per capture: guard with a flag.) |
| `.startTimer(kind, g, seconds)` | `timers.schedule(after: seconds) { dispatch(.timerElapsed(kind, generation: g)) }`; remember the handle by `(kind, g)`; for `.review` also set `reviewDeadline = clock.now() + seconds`. Handles of an old generation are cancelled when a new generation starts (any `startCapture` or `NEW_ID`); cancel all handles on `stop()`. |
| `.cue(c)` | `cues.play(c)` |
| `.execute(intent, g)` | audit gate (A.4), then `Task { let r = await executor.execute(intent); dispatch(.localExecutionFinished(r, generation: g)) }` |
| `.submitToAgent(text, g)` | audit gate (A.4), then `Task { for await e in backend().submit(text) { if case .status("started") = e { dailyTurns.increment(now: clock.now()) }; dispatch(.agent(e, generation: g)) } }`; if the stream ends without having delivered `.finished` or `.failed`, dispatch `.agent(.failed(.agentFailed("stream_ended")), generation: g)`. With the default `NullBackend` this yields the typed `.unavailable(.backend)` failure. |
| `.respondToApproval(nonce, allow)` | `Task { await backend().respond(nonce: nonce, allow: allow) }` |
| `.cancelAgentTurn` | `Task { await backend().cancelTurn() }` |
| `.stopAgentHard` | `Task { let report = await backend().emergencyStop(); model.setSurvivors(report.survivors) }` |
| `.speak(text, g)` | `Task { _ = await synthesizer.speak(text, localeIdentifier: settings.voiceLocale); dispatch(.speechFinished(generation: g)) }` |
| `.stopSpeaking` | `synthesizer.stop()` |
| `.audit(draft)` | `Task { let ok = await audit.append(draft); if !ok { auditWritable = false } else { auditWritable = true } }` (tasks run in order: chain them through one stored `Task` so records stay ordered) |

### A.4 Audit gate

`auditWritable` starts true. When it is false: an `.execute` effect for an intent whose tier is `>= .t2`, and every `.submitToAgent`, is NOT run; instead dispatch `.localExecutionFinished(.failure(.executionFailed("audit_unwritable")), generation: g)` or `.agent(.failed(.executionFailed("audit_unwritable")), generation: g)`. T0 local commands keep working. (Tier from `ConfirmationPolicy.tier(of:)`.) `FileAuditLogger` default directory/instance is created in `AppComposition`.

### A.5 Inputs

- `keys = makeKeys(settings.voiceHotkey)`; `keys.events` -> `.pressed` => `.talkPressed`; `.released(h)` => `.talkReleased(heldSeconds: h)`; `.cancelKey` => `.cancelRequested`; `.stopKey` => `.stopAllRequested`. Consumed by one `Task` started after `keys.start()`. Always publish the result of `keys.start()` with `model.setHotkeyStatus(...)` (`.unavailable` means another app owns the combination; Settings shows it).
- `lock.changes` -> when it becomes true: `.screenLocked`.
- `NSApplication.didBecomeActiveNotification` (observed only while voice is enabled) -> `model.setPermissions(permissions.status())`, so Settings notices a grant made in System Settings.
- `settings` (Combine, `[weak self]`): `voiceEnabled` true -> `startVoice()` (keys start, lock watcher, `model.setPermissions(permissions.status())`, if `voiceHermesLane` run the lane check B.8); false -> `dispatch(.featureDisabled)`, then stop keys and recognizer, `ducker.restore()`, `backend().shutdown()`. `voiceHermesLane` changed -> re-run the lane check (on) or `model.setHermesLaneStatus(.off)` and shut the backend down (off). `voiceHotkey` changed -> `keys.stop()`, `keys = makeKeys(newChoice)`, start it, publish the status again.
- `model.actions` (installed in `start()`): `stopAll` => `.stopAllRequested`; `resume` => `.resumeRequested`; `approve(n)` => `.approveRequested(nonce: n)`; `deny(n)` => `.denyRequested(nonce: n)`; `cancelReview` => `.cancelRequested`; `toggleTalk` => `.toggleTalk`; `submitTyped` => `submitTyped` (only if `debugTypingEnabled`); `requestPermissions` => `Task { model.setPermissions(await permissions.request()) }`.

### A.6 Typed debug flow (no microphone)

`submitTyped(text)`: only if `debugTypingEnabled` and `context.state == .idle` and `settings.voiceEnabled`. Set `typedFlow = true`; `dispatch(.talkPressed)`; (the `.startCapture` effect is NOT executed while `typedFlow`); then `dispatch(.captureStarted(generation: context.generation))`, `dispatch(.talkReleased(heldSeconds: 1.0))`, `dispatch(.finalTranscript(text, generation: context.generation))`. `typedFlow` is cleared when the state returns to `idle`, `error`, or `paused`. Everything after the final transcript (review window, execution, approvals, audit) is the real pipeline.

### A.7 Daily cap

`DailyTurnCounter` (struct, `DailyTurnCounterTests`): `init(defaults: UserDefaults, calendar: Calendar = .current, limit: Int = VoiceLimits.hermesTurnsPerDay)`; keys `"voice.hermesTurns.day"` (a `yyyy-MM-dd` string in the calendar's time zone) and `"voice.hermesTurns.count"`; `func remaining(now: Date) -> Int`, `mutating func increment(now: Date)`; a new day resets; a corrupt value counts as 0; never negative. The coordinator calls `increment` when a turn is actually submitted (B.7). These keys are NOT in `SettingsStore` and not exported.

### A.8 `AppComposition` wiring

(The only edit to `AppComposition.swift`; keep the existing code as is.) Create the platform objects and the coordinator **only when `!smokeTestMode`**: `voiceCoordinator` (optional property), built with real `AppleSpeechRecognizer()`, `AppleSpeechSynthesizer()`, `SystemLocalExecutor(...)` wired to `nowPlayingController`, `focusTimerController`, `VolumeDucker()`, `FileAuditLogger(directory: FileAuditLogger.defaultDirectory(), writer: DiskFileWriter(), clock: SystemVoiceClock())`, `CarbonPushToTalk(choice:)`, `ScreenLockMonitor()`, `SystemVoicePermissions()`, the UI's `VoiceCuePlayer()`, `backend` factory returning `HermesAgentBackend` when `settings.voiceHermesLane` is on, else `NullBackend()`, `dailyTurns: DailyTurnCounter(defaults: .standard)`, `isPrivacyMode: { SettingsStore.shared.privacyModeEnabled }`, `debugTypingEnabled: ProcessInfo.processInfo.environment["DESNOTCH_VOICE_DEBUG"] == "1"`. Create it at the end of `init` (after every other property is initialized) and call `start()` right there (it is inert unless `voiceEnabled`); you may NOT edit `AppDelegate.swift`. Call `voiceCoordinator?.stop()` in `stopOwnedResources()`. With `voiceEnabled == false` the coordinator must register NO hotkey, create NO audio engine and run NO timers (verify with a test).

### A.9 Part A tests (`VoiceCoordinatorLocalTests`, using the contract's doubles and a `ManualTimerScheduler`)

Names (each is a test): `testTypedVolumeCommandRunsThroughReviewAndExecutes`, `testHoldFlowWithScriptedRecognizer` (press, scripted `.captureStarted/.partial/.final`, release), `testReviewWindowCancelByEscapeNeverExecutes`, `testStopKeyAlwaysStopsAndReturnsIdle`, `testLockedScreenRefusesToStart`, `testScreenLockedWhileListeningCancelsCapture`, `testFeatureDisabledStopsCaptureAndReleasesKeys`, `testCancelKeyIsArmedOnlyWhileActive`, `testDuckingIsBalanced` (one duck, one restore per capture, also on cancel), `testT2VolumeNeedsApprovalAndWrongNonceDoesNothing`, `testApproveExecutesAndDenyDoesNot`, `testAuditUnwritableRefusesT2ButNotT0`, `testRepliesAreSpokenOnlyWhenAllowed` (TTS setting, privacy mode), `testNoCloudSubmitWithoutUserRelease`, `testDailyCapRefusesTheTurn`, `testDisabledVoiceStartsNothing` (no `keys.start`, no recognizer start, no timers), `testModelActionsDispatchEvents`, `testStaleTimerFromOldFlowIsIgnored`, `testNoAuditRecordContainsTheTranscript` (scan every appended draft/record for the spoken text except the `transcript` field handed to the logger, which `FileAuditLogger` hashes). `DailyTurnCounterTests`: remaining/increment/new day/corrupt/limit.

**Part A gate (P2).** Build clean; the new tests and the whole suite green; `git status` only in your files. Then a **manual check on the Mac mini** (it launches the app, so it needs the installed `/Applications/desnotch.app` to be quit by the human first; if it is running, report these items as `NOT RUN: installed desnotch is running` and hand the exact steps to the human; report each item you do run as DONE/NOT DONE and what you saw):

1. `swift build` then `DESNOTCH_VOICE_DEBUG=1 swift run` (or the packaged app), enable "Voice control" in Settings (this prompts for Microphone/Speech: allow, or skip: the typed path does not need them), use the status menu "Type a Voice Command…": `volume thirty`, `mute`, `unmute`, `play`, `pause`, `timer one minute`, `open safari`, `volume ninety` (a card must appear; Deny it; again and Approve it), `cancel` (ambiguous), `abort agent`. Each must behave per the tables in `docs/voice/PLAN.md`; the review banner shows for 1.5 s; Esc is not captured at idle.
2. `~/Library/Application Support/desnotch/voice/voice-audit.jsonl` exists with mode 0600, contains no spoken text, and `verify()` passes (a tiny debug-only call or a unit test over the file).
3. With Voice control OFF: no new process threads for audio, no hotkey registered (try ⌥⌘V in another app), idle CPU unchanged.

## Part B: the Hermes lane

### B.1 What you may read (read-only) to learn the shapes

Under `~/.hermes/hermes-agent/` ONLY Python source: `acp_adapter/entry.py`, `server.py` (methods `initialize`, `new_session(cwd, mcp_servers)`, `prompt`, `cancel`), `permissions.py` (the permission option ids are exactly `allow_once`, `allow_session`, `allow_always`, `deny`, `deny_always`), `events.py`, `tools.py`, `session.py`; the `acp` Python package's `schema.py` (find it with `find ~/.hermes/hermes-agent -path '*site-packages/acp/schema.py'`); `hermes_cli/` profile code (to learn the profile directory layout for `-p voice`) and `tools/approval*.py` (to learn the approval config key names: `approvals.mode`, the command allowlist key). Record in a code comment at the top of `HermesPreflight.swift` the exact source file + line of each fact you rely on. If you cannot determine a fact, implement the preflight to REFUSE and say so in your report.

### B.2 Transport

`ACPTransport` (`ACPTransport.swift`): a `Sendable` protocol: `func start() throws`, `func send(line: Data) throws`, `var lines: AsyncStream<Data>`, `func terminate()`. Newline-delimited JSON-RPC 2.0 (reuse `AdapterLineBuffer`). `ProcessACPTransport` spawns `/usr/bin/perl -MPOSIX=setsid -e 'setsid(); exec {$ARGV[0]} @ARGV; exit 127' <hermesPath> -p voice acp` (the same fixed launcher `SubprocessRunner` uses, so the child leads its own session and process group, `pgid == pid`), environment `SubprocessRunner.sanitizedEnvironment()`, stdin/stdout pipes, stderr to `FileHandle.nullDevice`, working directory = a fresh empty temp directory (`FileManager.default.temporaryDirectory/desnotch-voice-<uuid>`, removed on shutdown). All pipe callbacks run on one serial queue and carry a generation (copy the `MediaRemoteBridge` pattern: stale callbacks from a dead process must not touch the new stream).

### B.3 Preflight (`HermesLocator`, `MiniConfigScan`, `HermesPreflight`)

`HermesLocator.hermesURL() -> URL?`: first executable among `NSHomeDirectory()/.local/bin/hermes`, `/opt/homebrew/bin/hermes`, `/usr/local/bin/hermes`. `HermesPreflight.run(locator:, configReader:, fileFlags:, protocolVersion:) -> AgentPreflightResult` with injected seams (`ConfigReading`: returns the profile's `config.yaml` text or nil; `FileFlagReading`: returns `st_flags` for the config path). Checks, in order; the first failure is returned:

| # | Check | Failure |
|---|---|---|
| P1 | `hermesURL()` is non-nil | `.binaryMissing` |
| P2 | the `voice` profile directory/config exists and is readable | `.profileMissing` |
| P3 | `MiniConfigScan` parses the config; `approvals.mode` is present and (lowercased) is `manual` or `smart` | `.approvalsOff` (also when the file cannot be parsed: if you cannot prove approvals are on, refuse) |
| P4 | the approvals command allowlist key is absent or empty | `.allowlistNotEmpty` |
| P5 | no MCP servers are configured (key absent or empty) | `.mcpConfigured` |
| P6 | the ACP platform toolset list is explicitly present, and every entry is in `HermesToolsetPolicy.allowedToolsets` (a `static let ...: Set<String>` constant in `HermesPreflight.swift`, initially EMPTY, i.e. the profile must declare no toolsets; the human widens it later with a code change and a test) | `.toolsetOutsideAllowlist` |
| P7 | the config file carries the immutable flag (`UF_IMMUTABLE`, `chflags uchg`) | `.configNotLocked` |
| P8 | (live, inside `ACPClient` after `initialize`) the reported protocol version is in `HermesACP.supportedProtocolVersions` | `.protocolMismatch` |

`MiniConfigScan` is a tiny YAML-subset reader (no dependency): `key: value` scalars, nested maps by consistent indentation, block lists (`- x`), flow `[]`/`{}` on one line, `#` comments, single/double quoted scalars. Anything else (anchors, multi-docs, tabs, block scalars) throws `.unsupported` and the preflight refuses. It exposes `value(at path: [String]) -> ScanValue?`. Run the preflight on EVERY process spawn and EVERY new ACP session, and refresh `model.hermesLaneStatus` (`.checking` -> `.ready` or `.refused(reason)`).

### B.4 ACP client (`ACPClient`)

Lenient decoding (`JSONSerialization` into dictionaries; unknown fields ignored; a malformed line is dropped). It speaks only: `initialize` (declare NO client capabilities: no file system, no terminal), `session/new` (`cwd` = the temp dir, `mcpServers: []`), `session/prompt` (one text content block, the utterance), `session/cancel`, and answers `session/request_permission`. Notifications `session/update` carry the updates. Any other agent->client REQUEST is answered with JSON-RPC error `-32601` (method not found). Request ids are monotonically increasing integers; responses are matched by id; a timeout of 20 s on `initialize`/`session/new` and none on the streaming `prompt`.

### B.5 Event mapping (`HermesEventMapper`, pure)

Map ACP updates to `AgentEvent`:

- agent message chunk text -> accumulate; emit `.partial(accumulatedSoFar)` (bounded to 400 characters, keep the END of the text) at most every 100 ms (coalesce).
- tool call announced as `pending` -> NOTHING. A tool call update with status `in_progress` (first time for that tool call id) -> `.toolActivity(kind: <tool name lowercased, bounded to 40 chars>)`. Completed/failed updates -> nothing. Use the tool *name* as the kind (it feeds `ToolTierTable`'s word rules); NEVER put arguments, paths or titles in `kind`.
- `session/request_permission` -> build the card: `literal` = the command text from the request's raw input (fall back to the title); `risk = CommandRiskScanner.scan(literal)`; `tier = risk.tier`; `summary` = "Agent wants to run a command"; `source = .hermes`; `isTruncated = risk.wasTruncated`; `requiresSecondFactor = (tier >= .t3)`; `literal` shown = `risk.sanitized`; `nonce` = a fresh `UUID().uuidString` that you map to the JSON-RPC request id and its option ids. Emit `.approvalNeeded(card)`.
- `respond(nonce:allow:)`: allow => reply with option id `allow_once` ONLY; deny => option id `deny` ONLY. If the nonce is unknown reply nothing. If the request offered no `allow_once`, deny. A permission request still unanswered after 60 s is answered `deny`.
- prompt response with stop reason end of turn => `.finished(summary: accumulated text bounded to 400)`; cancelled/refusal/max tokens => `.failed(.agentFailed("stop_<reason>"))`; a JSON-RPC error => `.failed(.agentFailed("rpc_error"))`.
- any usage information the agent sends => `.usage(inputTokens:, outputTokens:, costMicros: 0)`; none is fine.

### B.6 Process supervision (`HermesProcessGuard`) and hard stop

- Spawn lazily on the first submit; keep it for the idle window (10 minutes) to keep the prompt cache; then `shutdown()` (SIGTERM the group, 0.5 s, SIGKILL). Kill on `stop()`/app termination (`AppComposition.stopOwnedResources`).
- Crash recovery: write `~/Library/Application Support/desnotch/voice/hermes-acp.pid` (pid + launch time). On the next start, if it names a live pid whose command line (`ps -p <pid> -o command=` via `SubprocessRunner`) contains both `hermes` and `acp`, kill THAT process group and remove the file. Never scan for other hermes processes.
- Restart backoff: reuse `AdapterRestartBackoff`; a process that dies mid-turn yields `.failed(.agentFailed("process_exited"))`.
- `emergencyStop()`: (1) snapshot all descendant pids of the child (`proc_listchildpids`, recursively), (2) send `session/cancel`, (3) wait `VoiceTiming.hardStopGrace` (0.5 s), (4) `killpg(pgid, SIGTERM)`, (5) wait 0.5 s, (6) `killpg(pgid, SIGKILL)`, (7) wait 0.2 s, (8) `survivors` = names (via `proc_name`) of snapshot pids for which `kill(pid, 0) == 0` still holds. Then drop the transport (the next submit respawns).
- Tests (`HermesProcessGuardTests`) run a REAL tiny process tree, not Hermes: launch `/bin/sh -c 'sleep 60 & sleep 60 & wait'` through the same perl launcher, call the hard stop, and assert both `sleep`s are gone and `survivors` is empty; another test starts a grandchild that calls `setsid` itself (`/usr/bin/perl -MPOSIX=setsid -e 'setsid(); sleep 60'`) and asserts it is reported in `survivors` and then clean it up in `tearDown`. A third test covers the stale-PID-file path with a harmless live `sleep` whose command line does NOT contain `hermes acp` (must NOT be killed). Always kill leftovers in `tearDown`.

### B.7 `HermesAgentBackend: AgentBackend`

Wraps locator + preflight + guard + client. `preflight()` runs B.3 (and the live check P8 when connected). `submit(utterance)` (called by the coordinator for `.submitToAgent`): (1) re-run preflight; refused => stream `[.failed(.preflightRefused(reason))]`; (2) ensure the process is running (spawn, `initialize`, `session/new` once per process; reuse the session for the idle window); (3) `session/prompt`; (4) forward mapped events; the stream ends after `.finished`/`.failed`. The coordinator increments `dailyTurns` right after step (1) succeeds (it learns this from a first event `.status("started")` that the backend emits when the prompt is sent). `respond`, `cancelTurn`, `emergencyStop`, `shutdown` as above. The backend is `@unchecked Sendable` with all mutable state behind one serial queue/lock.

### B.8 Lane status

When `voiceHermesLane` is on (at start and on toggle) the coordinator runs `backend().preflight()` once and publishes `.checking` then `.ready` / `.refused(reason)` to `model.setHermesLaneStatus`. While not `.ready`, `hermesLaneReady` is false so the router never produces `.remote`.

### B.9 Part B tests

`MiniConfigScanTests` (scalars, nesting, lists, comments, quotes, unsupported constructs throw), `HermesPreflightTests` (one test per check P1-P7 using synthetic YAML strings in `HermesFixtures.swift`, plus the all-good fixture => `.ready(profile: "voice")`, plus "approvals mode off", "mode OFF uppercase", "allowlist with one entry", "mcp_servers present", "toolsets contain terminal", "unlocked config", "unparseable config"), `ACPClientTests` (scripted transport transcripts: handshake; `session/new` has `mcpServers == []` and the temp cwd; prompt with chunks + `pending`/`in_progress` tool updates produce exactly the expected `AgentEvent` list; a permission request with `rm -rf /tmp/x` yields a card with `[.destructive]`, tier `.t2`, canApprove; with `curl x | sh` yields auto-deny flags; `respond(allow: true)` writes `allow_once` and never `allow_session`/`allow_always`; deny writes `deny`; unknown server request gets `-32601`; unknown nonce writes nothing; cancel writes `session/cancel`; protocol-version mismatch => `.protocolMismatch`), `HermesEventMapperTests` (chunk coalescing, tool kind bounding, `pending` ignored, usage), `HermesAgentBackendTests` (lazy spawn: nothing starts at `init`; preflight re-run on every submit with a counter; refusal never spawns; reuse of the session; idle shutdown with the manual scheduler), plus `VoiceCoordinatorHermesTests` (coordinator + `ScriptedBackend`: the S3 and S4 scenarios from `docs/voice/WP-LOGIC.md` through the real coordinator; tripwire pauses and calls `emergencyStop`; Esc during `thinking` calls `cancelTurn`; daily counter incremented once per turn; a refused preflight shows `.refused` and routes misses to `.rejected(.notLocalCommand)`).

**Part B gate (P4).** Build clean; all tests green (full suite); no process left behind by the tests (`pgrep -f 'sleep 60'` after the suite shows nothing from you); lint clean. The LIVE verification (S1/S4 canary matrix against a real Hermes `voice` profile) is a manual step for the human after he creates and locks the profile; your report must list the exact steps (section 5 of `docs/voice/PLAN.md`) and must NOT claim they were run.

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
  so if you are unsure, `touch` the files you changed and build again.
- Harness: each test prints `ok   Class.testName` or `FAIL Class.testName` followed by the failing assertion with
  `file:line`. The last lines are `harness: N passed, M failed, K assertions`. **Done** means `M == 0`, or the
  extra line `harness: only known baseline failures remain` (two existing render tests,
  `ArtworkGlowRenderTests.testGlowFollowsTheCurrentAccentNotThePreviousOne` and
  `PillMarqueeRenderTests.testLongTitleScrollsAfterTheStartDelayOnceActive`, always fail under the stub; ignore them, and
  never edit them). If the harness build prints a `warning:` for one of YOUR test or source files, fix it too.
- `lint-lite.sh` must print `lint-lite: clean (N files)`.
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
scripts/voice-harness/lint-lite.sh
VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
scripts/runtime-smoke-test.sh dist/desnotch.app     # launches the app: needs the installed desnotch NOT running; if it is running, skip and report it, never kill it
HARDENED_RUNTIME=1 VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
rg -n "print\\(|NSLog\\(|\\.onHover|repeatForever|serve --stop|pkill|killall|hermes pause|osascript|auth\\.json|AXIsProcessTrusted" Sources/DesnotchCore/Voice
```

The last `rg` must show nothing that is not a comment explaining a ban. Done means: every gate above met, plus the section-5 manual checklist of `docs/voice/PLAN.md` reported honestly.

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
   `docs/voice/*`, `scripts/voice-harness/*`, `.github/*`, or anything under `Sources/DesnotchCore/MediaRemote/Vendor/`.
   If you believe a contract file is wrong or incomplete, do NOT edit it: implement the literal spec, work around it locally
   in your own files, and add an `AMENDMENT REQUEST:` paragraph to your final report.
8. **Tests are XCTest, deterministic, and fast.** No sleeps (`Thread.sleep`, `Task.sleep`) to wait for results: use the
   helpers in `Tests/DesnotchCoreTests/TestSupport.swift` (`drainMainQueue`, `drainMainOperationQueue`) or await a stream. No
   network, no microphone, no real `~/Library` paths (use `FileManager.default.temporaryDirectory` + a UUID folder and delete
   it in `tearDown`), no real `UserDefaults.standard` (use `UserDefaults(suiteName:)` and remove the domain in `tearDown`).
   Tests must compile under real XCTest on Xcode 15: only use the assertion functions the existing tests use
   (`XCTAssertEqual/True/False/Nil/NotNil/NotEqual/Greater...`, `XCTUnwrap`, `XCTAssertThrowsError`, `XCTFail`,
   `expectation`/`wait(for:)`).
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
- Do NOT run `git add/commit/push/...`.
