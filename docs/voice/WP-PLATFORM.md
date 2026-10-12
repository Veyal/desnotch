# WP-PLATFORM: microphone, speech, hotkey, lock gate, local executor, audit log, permissions, packaging

> Self-contained prompt for an external coding agent. You have NOT seen the conversation that produced this plan.
> Implementer: agy (Antigravity CLI). Work in your own git worktree; do not commit.

## 1. Background

desnotch is a macOS menu-bar app (SwiftPM, macOS 13+, library target `DesnotchCore`, executable `desnotch`, no Xcode project,
packaged by `scripts/build-app.sh`). We are adding **voice control**, OFF by default (`SettingsStore.voiceEnabled`). The user
holds a hotkey, speaks, and either a fixed local command runs (volume, play/pause, open an app, timer) or the request goes to a
cloud agent. All voice code lives in `Sources/DesnotchCore/Voice/`. The pipeline is cut into seams (protocols) so that
independent work packages can build in parallel. **You implement the platform side of those seams**: everything that touches
the microphone, Apple Speech, global hotkeys, the screen-lock state, the system volume, `NSWorkspace`, the disk and the
packaging scripts. The pure state machine (WP-LOGIC), the UI (WP-UI) and the coordinator (WP-HERMES, later) are written by others.
You never call them and they never call your internals; they use the protocols in
`Sources/DesnotchCore/Voice/Contracts/Protocols.swift`.

Hard properties of this feature (they shape the code you write):

- **Audio never leaves the process and never touches the disk.** Recognition is strictly on-device. If on-device recognition is
  not available for the locale, the capture FAILS with a typed error; it never falls back to Apple's servers.
- **No new permission beyond Microphone and Speech Recognition.** No Accessibility, no Automation (no AppleScript, no
  `osascript`), no Screen Recording, no Full Disk Access. The local executor uses only public APIs.
- **Fail closed.** Unknown lock state means locked. A failed audit write means "refuse risky actions". Every failure is a typed
  `VoiceFailure`, never a crash and never a fake success.
- **Nothing runs at idle.** No timers, no taps, no observers doing work while voice is off or idle (the app's rule is "no animation
  or polling at idle"). Hotkeys are registered only when asked; Esc is registered only while armed.
- **Privacy.** Never log or print transcripts or audio details. Log `VoiceFailure.code` only.

Read first: `AGENTS.md` (sections on MediaRemote, AgentActivity privacy, "App wiring", "Build/run"), `docs/voice/PLAN.md`,
`Sources/DesnotchCore/Voice/Contracts/VoiceTypes.swift` and `Protocols.swift`, `Sources/DesnotchCore/App/GlobalHotKey.swift`
(Carbon pattern to follow), `Audio/SystemVolume.swift`, `Timer/FocusTimerController.swift`, `NowPlaying/NowPlayingController.swift`,
`MediaRemote/MediaRemoteBridge.swift` (the `Command` enum), `App/PermissionSnapshot.swift`, `scripts/build-app.sh`,
`scripts/smoke-test.sh`, `scripts/desnotch.entitlements`.

## 2. Files

You own exactly these files.

**New sources** (`Sources/DesnotchCore/Voice/Platform/`): `AppleSpeechRecognizer.swift`, `LevelMeter.swift`,
`AppleSpeechSynthesizer.swift`, `CarbonPushToTalk.swift`, `VoiceHotkeyMap.swift`, `ScreenLockMonitor.swift`,
`SystemLocalExecutor.swift`, `VolumeDucker.swift`, `AuditChain.swift`, `FileAuditLogger.swift`, `DiskFileWriter.swift`,
`SystemVoicePermissions.swift`.

**Changed**: `Sources/DesnotchCore/App/PermissionSnapshot.swift`, `scripts/build-app.sh`, `scripts/desnotch.entitlements`,
`scripts/smoke-test.sh`, `scripts/permission-status.sh`.

**New tests** (`Tests/DesnotchCoreTests/Voice/Platform/`): `LevelMeterTests.swift`, `VoiceHotkeyMapTests.swift`,
`PressTrackerTests.swift` (also declares the classes `CarbonHotKeyOutcomeTests` and `CarbonPushToTalkLifecycleTests`), `LockFlagsTests.swift` (also declares `ScreenLockMonitorTests`), `SystemLocalExecutorTests.swift`, `MuteMemoryTests.swift`, `VolumeDuckerTests.swift`,
`AuditChainTests.swift`, `FileAuditLoggerTests.swift`, `DiskFileWriterTests.swift`, `SystemVoicePermissionsTests.swift`,
`SpeechDecisionTests.swift`.
**Changed test**: `Tests/DesnotchCoreTests/PermissionSnapshotTests.swift`.

A fresh worktree does not contain the empty `Voice/Platform` directories (git does not track empty directories): start with
`mkdir -p Sources/DesnotchCore/Voice/Platform Tests/DesnotchCoreTests/Voice/Platform`.

## 3. Components

For every component: the type is `internal` (no `public`) unless stated, named exactly as below, and implements the protocol from `Contracts/Protocols.swift`. Logic that is not hardware is split into a small **pure** type so it is unit-tested;
the hardware glue around it is verified by the manual checklist in section 5.

**Constructors are part of the contract.** WP-HERMES builds these objects in `AppComposition` without reading your code, and every one of them is built eagerly at launch even when voice is OFF, so every `init` below must be **side-effect free**: no `AVAudioEngine`, no observers, no hot-key registration, no permission calls, no directory creation. Real work starts in `start()` / on the first call. Where a row lists several initializers, ALL of them exist exactly as written (do not fold a `convenience init` into a default argument).

| Type | Exact initializer(s) | Notes |
|---|---|---|
| `AppleSpeechRecognizer` | `init()` | creates the `AVAudioEngine` inside `start(...)`, never here |
| `AppleSpeechSynthesizer` | `init()` | creates the `AVSpeechSynthesizer` lazily on the first `speak` |
| `CarbonPushToTalk` | `init(choice: VoiceHotkeyChoice, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })` | `PressTracker` lives in `CarbonPushToTalk.swift`; the closure is `@Sendable` because the C callback reads it off the main actor (3.3) |
| `ScreenLockMonitor` | `init(sessionDictionary: @escaping @MainActor () -> [String: Any]? = { CGSessionCopyCurrentDictionary() as? [String: Any] }, screensaverRunning: @escaping @MainActor () -> Bool = { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" } }, notificationCenter: NotificationCenter = DistributedNotificationCenter.default())` | `ScreenLockMonitor()` works through the defaults (the production call and WP-HERMES A.8 stay source-compatible); observers are added lazily (3.4) to `notificationCenter` and removed from the SAME center; the three parameters are the test seams |
| `SystemLocalExecutor` | designated `init(volume: VolumeControlling, media: MediaTransporting, timer: TimerControlling, apps: AppLaunching)`; `convenience init(nowPlaying: NowPlayingController, focusTimer: FocusTimerController)` building the real adapters below | |
| `SystemVolumeControl` | `init()` | `: VolumeControlling`; wraps the `SystemVolume` static functions (`SystemVolume` is an enum of static functions and cannot conform to a protocol itself) |
| `NowPlayingTransport` | `init(controller: NowPlayingController)` | `: MediaTransporting`; in `SystemLocalExecutor.swift` |
| `WorkspaceAppLauncher` | `init()` | `: AppLaunching`; in `SystemLocalExecutor.swift` |
| `FocusTimerController` | `extension FocusTimerController: TimerControlling` in `SystemLocalExecutor.swift` | `FocusTimerController` ALREADY has `public var isActive: Bool` (`state == .running \|\| .paused`) and `cancel()`: do NOT redeclare either (an invalid-redeclaration build error). The extension adds exactly one member, `func start(minutes: Int) -> Bool { start(duration: TimeInterval(minutes * 60)) }` |
| `VolumeDucker` | designated `init(volume: VolumeControlling)`; `convenience init() { self.init(volume: SystemVolumeControl()) }` | `VolumeDucker()` (production) and `VolumeDucker(volume: fake)` (tests) both stay valid. **No default argument may call a `@MainActor` initializer**: `init(volume: VolumeControlling = SystemVolumeControl())` on a `@MainActor` class does NOT compile ("call to main actor-isolated initializer 'init()' in a synchronous nonisolated context"), on Swift 6.1 and on CI's 5.10 alike, whether `SystemVolumeControl` is annotated `@MainActor` or only inherits the isolation from the `@MainActor` `VolumeControlling` protocol. `SystemLocalExecutor` uses the same designated + `convenience` shape (its row above). A default argument that is a `@MainActor () -> T` closure LITERAL is fine (the `ScreenLockMonitor` defaults compile); a default that CALLS a `@MainActor` init is not. Do not "fix" this by dropping `@MainActor` from the seam. |
| `SystemVoicePermissions` | `init()` | |
| `DiskFileWriter` | `init()` | |
| `FileAuditLogger` | `init(directory: URL, fileName: String = "voice-audit.jsonl", writer: FileWriting, clock: VoiceClock, maxFileBytes: Int = 1_048_576, keepRotated: Int = 4)`, plus `static func defaultDirectory() -> URL` | |
| `LevelMeter` / `EmitThrottle` | `EmitThrottle` lives in `LevelMeter.swift` | |

**Test doubles are shared by file name, so they must not collide.** All test files of the whole package share one module. The fakes for `VolumeControlling`, `MediaTransporting`, `TimerControlling` and `AppLaunching` are defined ONCE, in `SystemLocalExecutorTests.swift`, with these exact names: `FakeVolumeControl`, `FakeMediaTransport`, `FakeTimerControl`, `FakeAppLauncher` (internal, not `private`). `VolumeDuckerTests.swift` reuses `FakeVolumeControl` and must NOT declare its own. **Behavior of the fakes (both test files depend on it):** `FakeVolumeControl` is `@MainActor final class ... : VolumeControlling` with `var level: Float?`, `var adjustable = true` and `private(set) var deltas: [Float] = []`; `adjust(by:)` appends the delta to `deltas`, then returns nil when `!adjustable` or `level == nil` (without changing `level`), otherwise sets `level = min(1, max(0, level + delta))` and returns the new level; `current()` returns `level`. `FakeMediaTransport` (`@MainActor`) records an ordered call list (`private(set) var calls: [String]`, entries `"play"`, `"pause"`, `"next"`, `"previous"`). `FakeTimerControl` (`@MainActor`) has `var active = false`, `var startResult = true`, `private(set) var startedMinutes: [Int]`, `private(set) var cancelCount = 0`; `isActive` returns `active`; `start(minutes:)` records and returns `startResult`; `cancel()` increments `cancelCount`. `FakeAppLauncher` (`@MainActor`) records `private(set) var bundleIDs: [String]` and has `var result = true`; `launch(bundleID:)` records and returns `result`. The throwing `FileWriting` double (`ThrowingFileWriter`) is defined once, in `FileAuditLoggerTests.swift`; EVERY method of it throws, so `append` returns false already at the lazy start. Before you name any other helper type run `rg -n "class <Name>|struct <Name>" Tests` and rename on a collision; a duplicate declaration only shows up when CI builds the whole test module.

### 3.1 `AppleSpeechRecognizer` (+ `LevelMeter`): `SpeechRecognizing`

Class `AppleSpeechRecognizer: SpeechRecognizing, @unchecked Sendable` guarding ALL mutable state with one `NSLock` (the tap callback takes it briefly; never hold it while calling out to Speech, and NEVER while calling `continuation.yield(...)` or `continuation.finish()`).

**Lock discipline for the continuation (deadlock rule, mandatory).** `AsyncStream.Continuation.finish()` runs `onTermination` SYNCHRONOUSLY on the calling thread (verified in a scratch program), and step 5 installs an `onTermination` that calls `cancel(token:)`, which takes the same `NSLock`. So `yield(...)` and `finish()` on the continuation are called ONLY AFTER the lock is released. Under the lock, do only this: read or clear the token, take the continuation, request, task, recognizer and engine OUT of the capture state into locals, and set the capture state to nil. Then unlock, then `yield`/`finish`, then stop the engine and remove the tap. Because the token was already cleared under the lock, the `onTermination` re-entry into `cancel(token:)` finds a stale token and returns without doing anything. This applies to every terminal path (a `.final` or `.failed` from the Speech handler, `endAudio` completion, `cancel()`, a failed `engine.start()`, a new `start` cancelling the previous capture). The same rule covers the non-terminal yields: `.captureStarted` and `.level` (and `.partial`) are yielded after the lock is released (take the continuation reference under the lock, `yield` outside it). The mandatory shape is a small `CaptureBook` (internal struct in `AppleSpeechRecognizer.swift`, no Speech or AVFoundation types in its API, generic over the payload so it is testable) held inside the lock: `mutating func begin(payload:) -> (token: UInt64, replaced: Payload?)` (new token; replaces the current capture and hands back the old payload, if any, for the caller to tear down outside the lock), `func payload(forToken:) -> Payload?` (nil when stale; used by the tap and result callbacks to read the continuation/request reference under the lock) and `mutating func take(token:) -> Payload?` (returns the payload and clears the capture only when the token is current; every terminal path uses it). Do not hand-roll lock/unlock in each callback. `CaptureBookTests` (a second class declared in the already-owned `SpeechDecisionTests.swift`; no new file, ownership.tsv stays as is) covers: `take` with a stale token returns nil and changes nothing; `take` twice returns the payload once; `begin` while a capture is active hands back the old payload; and the re-entrancy case, which needs no microphone: build an `AsyncStream` whose `onTermination` calls `take(token:)` on the book while the test calls `take` first, then `finish()` OUTSIDE the lock, and assert (bounded `XCTestExpectation`, 2 s) that the sequence completes and the re-entrant `take` returned nil.

`start(localeIdentifier:contextualStrings:)` (returns the stream; calling it while a capture is active first cancels that capture):

1. Check permissions WITHOUT prompting: `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()`. Not `.authorized` -> yield `.failed(.permissionDenied(.microphone))` or `.permissionDenied(.speech)` and finish.
2. `SFSpeechRecognizer(locale: Locale(identifier:))`; nil or `!isAvailable` -> `.failed(.unavailable(.recognizer))`. **`supportsOnDeviceRecognition == false` -> `.failed(.unavailable(.recognizer))`** (never use server recognition). (On this Mac `id-ID` has no on-device asset, so it always fails here; that is correct.)
   Keep the `SFSpeechRecognizer` instance in the capture state (strongly referenced) until the capture ends: a recognizer that is deallocated while its task runs silently produces no results at all.
3. `SFSpeechAudioBufferRecognitionRequest`: `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`, `taskHint = .dictation`, `contextualStrings = contextualStrings`, `addsPunctuation = false` (macOS 13+).
4. `AVAudioEngine` (created here): `let format = engine.inputNode.outputFormat(forBus: 0)`. **If `format.sampleRate > 0 && format.channelCount > 0` does not hold (no input device), yield `.failed(.unavailable(.recognizer))` and finish BEFORE `installTap`: `installTap` with a zero-rate format raises an `NSException` that kills the process.** Then install the tap (`bufferSize: 1024`, that format) and `engine.start()` (it runs on the caller, the main actor, and can block for a few hundred ms on a cold start; accepted for the MVP, do not move it); if `engine.start()` throws, remove the tap, yield `.failed(.unavailable(.recognizer))` and finish. In the tap, take the lock ONLY to check the token and read the current `request` reference into a local, release the lock, then call `request.append(buffer)` on that local right there in the tap callback (do not hop asynchronously with the buffer, the engine may reuse it; and never call into Speech while holding the lock, so a concurrent `endAudio()` cannot contend with the append). On the FIRST buffer yield `.captureStarted` (this is when the "listening" earcon plays). Compute `rms` per buffer over channel 0 (`guard let channel = buffer.floatChannelData?[0] else { skip the level for this buffer }`: `floatChannelData` is nil for non-float formats, and the buffer must still be appended), and yield `.level(LevelMeter.level(fromRMS: rms))` (the 0...1 value; the coordinator, not this class, turns the history into bars with `LevelMeter.bars(from:)`) at most `VoiceLimits.meterMaxHz` (15) times per second (`EmitThrottle`). Audio buffers are only handed to the request; never write them anywhere.
5. Set `continuation.onTermination = { [weak self] _ in self?.cancel(token: token) }` (this runs synchronously inside `finish()`; see the lock discipline above: it is safe ONLY because `finish()` is never called under the lock and the token is already cleared by then): a consumer that drops the stream (for example a cancelled `Task`) must stop the engine and clear the tap, and it must cancel only ITS capture, not a newer one.
6. Recognition results (token-checked). The decision is a PURE function so it can be unit-tested (this is the riskiest logic in the file), in `AppleSpeechRecognizer.swift`:

   ```swift
   enum SpeechDecision {
       /// nil = nothing to emit. `text` is `result?.bestTranscription.formattedString`, nil when the handler got an error and no result.
       static func event(text: String?, isFinal: Bool, errorPresent: Bool, endAudioCalled: Bool, lastPartial: String) -> SpeechEvent?
       /// true for `.final` and `.failed`: the capture is over, tear down and finish the stream.
       static func isTerminal(_ event: SpeechEvent) -> Bool
   }
   ```

   | `text` | `isFinal` | `errorPresent` | `endAudioCalled` | result |
   |---|---|---|---|---|
   | non-nil | false | false | any | `.partial(text)` (the caller also stores `lastPartial = text`) |
   | non-nil | true | false | any | `.final(text)` |
   | any | any | true | true | `.final(lastPartial)` (an empty `lastPartial` gives `.final("")`: a normal "the user said nothing" ends in an error, and the reducer turns the empty final into the "no speech" message, R50, not into "Voice isn't available") |
   | any | any | true | false | `.failed(.unavailable(.recognizer))` |
   | nil | any | false | any | `nil` |

   An error wins over a result in the same callback (rows 3 and 4 are evaluated first). **P3 note (accepted):** row 4 also fires in toggle mode, or when the recognizer's own silence timeout ends the task before the user releases the key (error present, `endAudio` not yet called); the user then sees "Voice isn't available" instead of "no speech". That is the safe direction and is accepted for the MVP; do not add a second guess. `SpeechDecisionTests` (class `SpeechDecisionTests`, a new file) has one test per row plus `isTerminal` for all five `SpeechEvent` cases.
7. `endAudio()`: record that the user ended the capture, then STOP THE ENGINE AND REMOVE THE TAP FIRST, and only then call `request.endAudio()` (this is Apple's sample order: a tap callback that already read the request reference must not be able to `append` after `endAudio`; the token check in the tap stays as the second guard). The final result (or the error handled above) then arrives. `cancel()`: clear the token, cancel the task, stop the engine, remove the tap, finish the stream with NO final and NO failure. Both are idempotent and safe to call when nothing is active. Never leave the engine running or the tap installed after the stream finished.

`LevelMeter.swift` (pure, tested):

```swift
enum LevelMeter {
    /// Maps a linear RMS (0...1, can exceed slightly) to 0...1: dBFS -50...0 mapped linearly, clamped.
    static func level(fromRMS rms: Float) -> Float
    /// 5 bar heights (0...1) from the last up-to-5 levels, oldest first, padded with 0 on the left.
    static func bars(from history: [Float]) -> [Float]
}
struct EmitThrottle {                      // injected time, no clocks inside
    init(maxHz: Double)
    mutating func shouldEmit(at time: TimeInterval) -> Bool   // true if >= 1/maxHz since the last true
}
```

Tests (`LevelMeterTests`): `level(fromRMS: 0) == 0`; `1.0 -> 1.0`; `0.00316 (-50 dB) -> 0 (±0.001)`; `0.0316 (-30 dB) -> 0.4 (±0.01)`; `0.1 (-20 dB) -> 0.6 (±0.01)`; `2.0 -> 1` (clamped); negative or NaN -> 0; `bars([])` is five zeros; `bars([0.5])` is `[0,0,0,0,0.5]`; seven values keep the last five in order; `EmitThrottle(maxHz: 15)`: first call true, call at +0.03 false, at +0.07 true (>= 0.0667 since last true; start at a binary-exact time such as 10.0 and use gaps like 0.03125 and 0.0703125 so no assertion depends on `Double` rounding), non-monotonic time (earlier than last) false.

### 3.2 `AppleSpeechSynthesizer`: `SpeechSynthesizing`

`AVSpeechSynthesizer`. `speak(_:localeIdentifier:)` creates an `AVSpeechUtterance` with `AVSpeechSynthesisVoice(language: localeIdentifier)` (nil voice -> default), speaks, and returns when the delegate reports `didFinish` (true) or `didCancel` (false). Only one synthesizer instance, created lazily on first use (not at init). `final class AppleSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate, @unchecked Sendable`, with ONE `NSLock` guarding the dictionary of pending continuations.
**Locking and isolation (exact).** `speak` is `async`, so it must not call `lock()`/`unlock()` itself (global rule 2). Structure it as:

- `private func register(_ utterance: AVSpeechUtterance, _ continuation: CheckedContinuation<Bool, Never>) -> [CheckedContinuation<Bool, Never>]` (SYNCHRONOUS, takes the lock): stores the new continuation under `ObjectIdentifier(utterance)` and returns every previously pending continuation (removed from the dictionary); `private func take(_ utterance: AVSpeechUtterance) -> CheckedContinuation<Bool, Never>?` (synchronous, locked): removes and returns one entry. The caller resumes returned continuations OUTSIDE the lock.
- `func speak(...) async -> Bool`: if the trimmed text is empty return `false` immediately (no continuation). Otherwise cut the text to `VoiceLimits.maxReplyCharacters` and `return await withCheckedContinuation { continuation in DispatchQueue.main.async { [weak self] in ... } }`; inside the block, if `self` is gone `continuation.resume(returning: false)`; else create the utterance, `let superseded = register(utterance, continuation)`, `superseded.forEach { $0.resume(returning: false) }`, `synthesizer.stopSpeaking(at: .immediate)` (only when something was superseded), then `synthesizer.speak(utterance)`. Every path resumes its continuation exactly once; a `speak` that cannot start resolves `false`, never leaks a continuation.
- `func stop()` is synchronous but must stay ordered with `speak`: use `DispatchQueue.main.async { [weak self] in self?.synthesizer?.stopSpeaking(at: .immediate) }` (FIFO with the `speak` block above). `Task { @MainActor }` is NOT used anywhere in this class (task ordering is not guaranteed).
- The delegate callbacks `didFinish` / `didCancel` run on the main thread: `take(utterance)?.resume(returning: true / false)`.

**Continuations are keyed by utterance identity** (`ObjectIdentifier(utterance)`), not held in a single slot: a second `speak` while speaking stops the first, resumes the superseded caller with `false` IMMEDIATELY, and the old utterance's asynchronous `didCancel` then finds no entry and does nothing (a single slot would resolve the wrong caller).
No tests (hardware); covered by the manual checklist.

### 3.3 `CarbonPushToTalk` (+ `VoiceHotkeyMap`, `PressTracker`): `PushToTalkSource`

Follow `CarbonHotKeyRegistrar` in `App/GlobalHotKey.swift` (do NOT edit that file). `@MainActor final class CarbonPushToTalk: PushToTalkSource`.

- Registers three Carbon hot keys with signature `'DSVC'` (0x44535643): id 1 = the talk key (from `VoiceHotkeyMap`), id 2 = the stop chord **⌥⌘.** (`kVK_ANSI_Period`, `cmdKey | optionKey`), id 3 = **Esc** (`kVK_Escape`, no modifiers), registered ONLY while `setCancelKeyArmed(true)`; `setCancelKeyArmed(false)` unregisters it.
- Installs ONE event handler for BOTH `kEventHotKeyPressed` and `kEventHotKeyReleased` (two `EventTypeSpec`s). This is the key difference from the existing registrar, which only handles presses.
- **Swift 5.10 pattern (follow `GlobalHotKey.swift`), with an explicit non-isolated box.** The C callback runs off the main actor and must read the `uptime` closure there, but a `nonisolated let` of a NON-Sendable closure is an error on Swift 5.10 (the local 6.1 compiler does not show it). So: a non-isolated `final class CarbonHotKeyBox: @unchecked Sendable` (in `CarbonPushToTalk.swift`, guarded by one `NSLock`) owns everything the callback and `deinit` touch: `handlerRef`, `hotKeyRefs` (talk, stop, Esc), the `uptime: @Sendable () -> TimeInterval` closure, the `@Sendable (HotKeyOutcome, TimeInterval) -> Void` main-queue sink, and the C callback itself (a `static let callback: EventHandlerUPP` that reads the box from `userData`). The `@MainActor final class CarbonPushToTalk` owns the box (a `let box: CarbonHotKeyBox`) and its `PressTracker`. **Box skeleton (so nobody has to guess):** `final class CarbonHotKeyBox: @unchecked Sendable { init(uptime: @escaping @Sendable () -> TimeInterval); func setSink(_ sink: @escaping @Sendable (HotKeyOutcome, TimeInterval) -> Void); func teardown() }` (these three are the minimum: add whatever install/register/unregister methods you need on the box, for example `installHandler()`, `register(binding:id:)`, `unregister(id:)`; every Carbon ref stays inside the box under its lock, none leaks into `CarbonPushToTalk`). `CarbonPushToTalk.init(choice:uptime:)` creates the box with `CarbonHotKeyBox(uptime: uptime)` FIRST (the sink is empty, so an early callback does nothing), finishes initializing itself, and only THEN attaches the sink in `start()` with `box.setSink { [weak self] outcome, time in MainActor.assumeIsolated { ... } }` before registering anything (a closure that captures `self` cannot be built before `self` is fully initialized). `teardown()` unregisters the three hot keys, removes the handler and clears the sink, under the box's lock, idempotently; it is the ONLY thing `deinit` and `stop()` call on the box. The callback captures the timestamp (`box.uptime()`) INSIDE the callback, before any hop; it hops with `DispatchQueue.main.async` (FIFO, so a press and its release stay ordered) and the sink re-enters with `MainActor.assumeIsolated`. Do NOT use `Task { @MainActor }` for press/release: task ordering is not guaranteed. Do not call the `@MainActor` `stop()` from `deinit`: `deinit` releases the Carbon refs through the box only (`box.teardown()`, non-isolated).
- **The callback must NOT swallow other handlers' keys (safety-relevant, exact).** Carbon calls the most recently installed application-level handler first, and this handler is installed next to the existing `CarbonHotKeyRegistrar` handler (signature `'DSNT'`, Option-Command-N, show-notch). If the new callback returned `noErr` for a foreign hot key, it would silently kill the show-notch shortcut once voice is enabled, and no test could notice (the key path is hardware-only). So the callback does, in this order: (1) `guard let event, let userData else { return OSStatus(eventNotHandledErr) }`; (2) read the id exactly as `CarbonHotKeyRegistrar` does: `GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)`, and `guard result == noErr else { return OSStatus(eventNotHandledErr) }`; (3) `guard CarbonHotKeyBox.isOwn(signature: id.signature, id: id.id) else { return OSStatus(eventNotHandledErr) }` (a foreign signature, or an id other than 1, 2, 3: not handled, the sink is NOT called); (4) `let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)`, `if let outcome = CarbonHotKeyBox.outcome(signature: id.signature, id: id.id, isRelease: isRelease)` then capture `box.uptime()` and hop to the main queue with the sink; (5) return `noErr`. A release of the Stop chord (id 2) or of Esc (id 3) is OWN but IGNORED: `outcome` returns nil, the sink is not called, and the callback still returns `noErr` (the key belongs to us; swallowing its release is correct).
- **`HotKeyOutcome` and the two pure functions (all in `CarbonPushToTalk.swift`, tested).**

  ```swift
  enum HotKeyOutcome: Equatable, Sendable { case talkPressed, talkReleased, stopChord, escPressed }

  extension CarbonHotKeyBox {
      static let signature: OSType = 0x4453_5643              // 'DSVC'
      /// true only for signature 'DSVC' and id 1, 2 or 3; everything else is another handler's key.
      static func isOwn(signature: OSType, id: UInt32) -> Bool
      /// nil for a foreign key AND for the ignored releases of ids 2 and 3.
      /// id 1: press -> .talkPressed, release -> .talkReleased; id 2: press -> .stopChord; id 3: press -> .escPressed.
      static func outcome(signature: OSType, id: UInt32, isRelease: Bool) -> HotKeyOutcome?
  }

  extension PressTracker {
      /// The main-queue mapping from an outcome to the event the coordinator sees. `time` is the uptime captured in the callback.
      /// .talkPressed  -> press(at: time) and, only if it returned true, .pressed (a duplicate/auto-repeat press yields nil);
      /// .talkReleased -> release(at: time) and, only if non-nil, .released(heldSeconds: that value);
      /// .stopChord    -> .stopKey (not touching the tracker); .escPressed -> .cancelKey.
      mutating func event(for outcome: HotKeyOutcome, at time: TimeInterval) -> PushToTalkEvent?
  }
  ```

  The sink body is `MainActor.assumeIsolated { if let event = self.tracker.event(for: outcome, at: time) { self.continuation.yield(event) } }` (through `[weak self]`). Tests (`CarbonHotKeyOutcomeTests`, declared in `PressTrackerTests.swift` next to `PressTrackerTests`, plain non-`@MainActor` class because both functions are pure and `nonisolated`): `isOwn` is true for `('DSVC', 1/2/3)` and false for `('DSVC', 0)`, `('DSVC', 4)`, `('DSNT', 1)` (the show-notch registrar), `(0, 1)`; `outcome` for all six own (id, isRelease) combinations (`(1,false) -> .talkPressed`, `(1,true) -> .talkReleased`, `(2,false) -> .stopChord`, `(2,true) -> nil`, `(3,false) -> .escPressed`, `(3,true) -> nil`) and nil for `('DSNT', 1, false)`, `('DSNT', 1, true)` and `('DSVC', 9, false)`; `PressTracker.event(for:at:)`: press at 100.0 then release at 100.75 gives `.pressed` then `.released(heldSeconds: 0.75)`; a duplicate `.talkPressed` while down gives nil; `.talkReleased` with no press gives nil; `.stopChord` gives `.stopKey` and `.escPressed` gives `.cancelKey` without changing a tracker that is mid-hold (a later release still reports the full hold).
- The signature here is `'DSVC'` (0x44535643); the S2 spike below uses a different one (0x44535632). That is harmless: the spike is a separate process.
- The handler feeds a `PressTracker` (pure) to produce events (the mapping above): talk key press -> `.pressed`; release -> `.released(heldSeconds:)`; stop chord press -> `.stopKey`; Esc press -> `.cancelKey`.
- **Lifecycle, one rule: the instance is single-use.** `events` is an `AsyncStream<PushToTalkEvent>` created once in `init`. **How to hold the continuation WITHOUT a force unwrap (rule 3 bans `!`):** `let (stream, continuation) = AsyncStream<PushToTalkEvent>.makeStream()` in `init`, then assign `self.events = stream` and `self.continuation = continuation` (both `let` properties). `AsyncStream.makeStream()` exists since Swift 5.9, so CI's 5.10 has it; it also compiles for `-target arm64-apple-macos13.0` (verified). The contract stub `UnavailablePushToTalk` in `VoiceStubs.swift` uses exactly this pattern (copy it). `start()` registers and returns `.active`; **`start()` while already started is idempotent and returns `.active`**; `stop()` unregisters everything, removes the handler, finishes the stream, and **`start()` after `stop()` returns `.unavailable` and registers nothing** (the finished stream cannot be reused). The coordinator therefore creates a NEW instance whenever `voiceHotkey` changes (`keys.stop(); keys = makeKeys(newChoice)`). **`setCancelKeyArmed(_:)` outside the started window:** called BEFORE `start()` it only records the flag (Esc is then registered by `start()`, best effort, if the flag is true); called AFTER `stop()` it is a no-op (nothing is registered, the flag is not recorded); called while started it registers or unregisters Esc immediately and idempotently.
- **Registration failures.** A FAILED `start()` leaves the instance NOT started (it is not stopped: the stream is still open), so a later `start()` on the same instance may retry (WP-HERMES builds a fresh instance on each enable anyway). `start()` returns `.unavailable` if the talk key OR the stop chord cannot be registered, after unregistering whatever it did register: voice must never run without its global kill-switch layer (the pill Stop button and the status menu remain either way). Failing to register Esc (id 3) is silent and best-effort (it never changes the returned status).
- `VoiceHotkeyMap.swift` (pure; its test file needs `import Carbon.HIToolbox` for `controlKey`, `cmdKey` and the `kVK_*` constants): `VoiceHotkeyMap.binding(for: VoiceHotkeyChoice) -> HotKeyBinding` using the existing `HotKeyBinding` type (`keyCode`, `carbonModifiers`, `keyLabel`): `optionCommandV` -> `kVK_ANSI_V`, `cmdKey|optionKey`, "V"; `shiftOptionCommandV` -> `kVK_ANSI_V`, `cmdKey|optionKey|shiftKey`, "V"; `optionCommandJ` -> `kVK_ANSI_J`, `cmdKey|optionKey`, "J". Tests check `VoiceHotkeyMap.binding(for:).displayString` is exactly `⌥⌘V`, `⌥⇧⌘V`, `⌥⌘J` (in the order of the three choices above). The Shift variant is `⌥⇧⌘V`, NOT `⇧⌥⌘V`: the existing `HotKeyBinding.displayString` (`App/GlobalHotKey.swift`, do not edit) emits the modifiers in the standard Apple order control, option, shift, command, so `cmdKey|optionKey|shiftKey` prints `⌥⇧⌘`. Never hand-roll a display string and never assert the other order. WP-UI's `VoiceSettingsWords.hotkeyLabel` returns the same three literals, and WP-HERMES pins the agreement with a cross-package test (its A.9 list). The tests also check that none equals `HotKeyBinding.default` (⌥⌘N), none uses `controlKey`, and the three are pairwise distinct.
- `PressTracker` (pure, tested, in `CarbonPushToTalk.swift`): `struct PressTracker { static let staleAfter: TimeInterval = 35; mutating func press(at: TimeInterval) -> Bool; mutating func release(at: TimeInterval) -> Double? }`. `press` returns true only if no press is currently down (a duplicate press while down returns false and does not reset the start time) **or the press that is down is older than `staleAfter` (35 s, the 30 s hold cap plus grace), in which case it counts as released: the start time is reset and `press` returns true** (a lost `kEventHotKeyReleased`, for example when the user lifts ⌥ or ⌘ before V, must not leave the talk key dead until restart); `release` returns the held seconds (>= 0, clamped) and clears the state, or nil if no press was down. Tests (use binary-exact times such as 100.0, 100.75, 100.5, 0.25, or compare with `accuracy: 0.0001`: a difference like `100.8 - 100.0` is NOT exactly `0.8` in `Double`, so an exact-equality assertion on it fails): normal hold 0.75 s (press at 100.0, release at 100.75); duplicate press ignored; release without press nil; release before press time (clock went backward) returns 0; two cycles in a row; a duplicate press at 34.9 s is still ignored; a press at 35.1 s after an unreleased press returns true and the following release reports the seconds since the NEW press. **Lifecycle tests with no hardware** (class `CarbonPushToTalkLifecycleTests`, declared in `PressTrackerTests.swift` next to the other two as `@MainActor final class CarbonPushToTalkLifecycleTests: XCTestCase`; none of them calls a `start()` that could register a real hot key): `testInitRegistersNothingAndDropIsSafe` (create a `CarbonPushToTalk(choice: .optionCommandV)` and let it go out of scope; no crash), `testStopIsIdempotent` (`stop()` twice on a never-started instance), `testStartAfterStopIsUnavailable` (`stop()` then `start() == .unavailable`) and `testCancelKeyArmingAfterStopIsANoOp` (`stop()` then `setCancelKeyArmed(true)` and `setCancelKeyArmed(false)` do not crash and register nothing).
- **Spike S2 (human-run; you do NOT run it).** It asks three OS questions: (1) does `kEventHotKeyReleased` arrive for an Option-Command hot key; (2) when the user lifts Option and Command BEFORE V, does a release still arrive (the 35 s `PressTracker.staleAfter` rule depends on the answer; a lost release is why that rule exists); (3) does Carbon accept a bare Esc (no modifiers) as a hot key, which the cancel key and the UI copy "Esc cancels" depend on? It needs a physical key press and a running application event loop, and a scratch executable cannot import our internal types (and cannot live in the tree), so the recipe is a standalone program independent of our code. Do this: (1) write it to a scratch directory that is not tracked: `S2DIR="$(mktemp -d)"` (outside the repository), or `S2DIR="$PWD/.build/s2"` with `mkdir -p "$S2DIR"` when a sandbox restricts you to your worktree (`.build/` is gitignored, so nothing enters the tree), and the file `$S2DIR/s2.swift` (do not assume a scratchpad directory exists), (2) compile it with `swiftc "$S2DIR/s2.swift" -o "$S2DIR/s2"` (it must compile with no error; this is the only part you run), (3) in your report list it as `BLOCKED: human-run` and give the path; the human runs `./s2`, presses and releases Option-Command-V a few times, then holds V and lifts Option and Command first, then presses Esc. The first line must show `bareEsc=0` (accepted); the expected output has an `Option-Command-V pressed` and an `Option-Command-V RELEASED` line per normal cycle, and an `Esc pressed` line for Esc. Report which lines are missing (a missing `RELEASED` after the modifiers-first cycle is expected to be possible and is exactly what the 35 s stale rule covers). The program:

  ```swift
  import AppKit
  import Carbon.HIToolbox

  func say(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
  var hotKeyRef: EventHotKeyRef?
  var escRef: EventHotKeyRef?
  var handlerRef: EventHandlerRef?
  var started = ProcessInfo.processInfo.systemUptime
  let callback: EventHandlerUPP = { _, event, _ in
      guard let event else { return noErr }
      var hotKeyID = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      let name = hotKeyID.id == 2 ? "Esc" : "Option-Command-V"
      let kind = GetEventKind(event)
      let now = ProcessInfo.processInfo.systemUptime - started
      say(String(format: "%.3f %@ %@", now, name, kind == UInt32(kEventHotKeyReleased) ? "RELEASED" : "pressed"))
      return noErr
  }
  var types = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
  ]
  let installStatus = InstallEventHandler(GetApplicationEventTarget(), callback, 2, &types, nil, &handlerRef)
  let registerStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey),
                                           EventHotKeyID(signature: 0x4453_5632, id: 1),
                                           GetApplicationEventTarget(), 0, &hotKeyRef)
  let escStatus = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x4453_5632, id: 2),
                                      GetApplicationEventTarget(), 0, &escRef)
  say("install=\(installStatus) register=\(registerStatus) bareEsc=\(escStatus) (0 = ok)")
  say("1) press and release Option-Command-V normally, 2) hold V and lift Option and Command BEFORE V, 3) press Esc; exiting in 40 s")
  NSApplication.shared.setActivationPolicy(.accessory)
  Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { _ in
      if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
      if let escRef { UnregisterEventHotKey(escRef) }
      say("done")
      NSApplication.shared.terminate(nil)
  }
  started = ProcessInfo.processInfo.systemUptime
  NSApplication.shared.run()
  ```

### 3.4 `ScreenLockMonitor` (+ `LockFlags`): `LockStateProviding`

`@MainActor final class ScreenLockMonitor: LockStateProviding`. Pure core:

```swift
struct LockFlags: Equatable {
    var screenLocked: Bool
    var screensaverActive: Bool
    var onConsole: Bool            // false = a different user session is in front (fast user switching)
    var isLocked: Bool { screenLocked || screensaverActive || !onConsole }
    static let unknown = LockFlags(screenLocked: true, screensaverActive: false, onConsole: false)   // literally this; isLocked == true
    static func from(sessionDictionary: [String: Any]?) -> LockFlags
}
```

**Merge rule (safety-relevant, exact; it must never fail open and never fail permanently closed).** There are two sources and the screen counts as locked if EITHER says so:

- `dictionaryLocked`: from the injected `sessionDictionary()` (default `CGSessionCopyCurrentDictionary()`; key `"CGSSessionScreenIsLocked"` present and true = locked); `onConsole` comes ONLY from the dictionary (`kCGSSessionOnConsoleKey` = `"kCGSSessionOnConsoleKey"`, must be present and true; a dictionary without it is "not on console", i.e. locked). If the dictionary is nil -> `LockFlags.unknown` (locked).
- `notificationLocked` and `screensaverActive`: stored booleans set by `DistributedNotificationCenter` notifications `com.apple.screenIsLocked` (set), `com.apple.screenIsUnlocked` (clear), `com.apple.screensaver.didstart` (`screensaverActive = true`) and `com.apple.screensaver.didstop` (clear), all observed on the injected `notificationCenter`. They are `false` at `init` and whenever no observers are installed.
- `screenLocked = dictionaryLocked || notificationLocked`. Re-read the dictionary on every notification, but never let a not-yet-flipped dictionary override a lock notification (the pure re-read would fail open when `screenIsLocked` arrives before the dictionary flips). Because the dictionary can also lag behind `screenIsUnlocked`, and the live `screensaverRunning()` check can still be true for a moment after `com.apple.screensaver.didstop` (the Engine process is still exiting), re-read once more 0.5 s after EACH of those two notifications (`screenIsUnlocked` and `screensaver.didstop`): one `DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in MainActor.assumeIsolated { self?.recomputeAndEmitIfChanged() } }` (not a repeating timer; the same private `recomputeAndEmitIfChanged()` that every notification handler calls recomputes `isLocked` and yields to the streams only when it differs from the last emitted value).

**`isLocked` is a pure recomputation on EVERY call, with no cached result and no side effect:**
`LockFlags.merged(dictionary: LockFlags.from(sessionDictionary: sessionDictionary()), notificationLocked: notificationLocked, screensaverActive: screensaverActive || screensaverRunning()).isLocked`.
Consequences that the tests pin down: (1) before any notification has ever arrived, and with no observers installed, `isLocked` is decided by the dictionary alone: an unlocked console dictionary gives `false` (it must NOT be seeded with `LockFlags.unknown`, which would make every talk press end in "Screen is locked" until some notification fired), a nil dictionary gives `true`, a locked dictionary gives `true`; (2) the `screensaverRunning()` seam (default: `NSWorkspace.shared.runningApplications` contains bundle id `com.apple.ScreenSaver.Engine`, public API) is consulted live, so a screensaver that was already running when voice was enabled is seen even though no `didstart` notification was observed; (3) a getter has no side effects: reading `isLocked` never installs observers (otherwise the coordinator's last read after it dropped its stream would re-install them and nothing would ever remove them).

**Observation is lazy and tied to streams.** `init` adds no observer (the monitor is built at launch even with voice off). Build each stream with `let (stream, continuation) = AsyncStream<Bool>.makeStream()` (Swift 5.9+; no force unwrap, rule 3), set `continuation.onTermination`, store the continuation in the array (with its id) and return `stream`. `changes` is a COMPUTED property returning a NEW `AsyncStream<Bool>` on every access (AsyncStream is single-consumer, and the coordinator and the UI may both want it, and the coordinator accesses it again each time voice is re-enabled); the monitor keeps the continuations in an array. The first stream installs the observers (idempotent), seeds `screensaverActive = screensaverRunning()` and seeds its last-emitted value from the SAME `isLocked` computation (so an unchanged state is not re-emitted and a new stream does not replay the current value). When the LAST stream terminates (`onTermination`) the observers are removed AND `notificationLocked = false` and `screensaverActive = false` are reset, so a later re-add starts from the dictionary and the live screensaver check, never from stale flags. A stream yields the new merged `isLocked` Bool only when it changes (not on every notification). No timers other than the one-shot above. The coordinator (WP-HERMES) must hold exactly one `changes` stream for as long as voice is enabled (A.5).

**Threading (exact).** The `DistributedNotificationCenter` observers are added with `queue: .main` and their block re-enters the monitor with `MainActor.assumeIsolated { ... }` (the pattern `ClipboardController` and `BatteryController` use), NOT with `Task { @MainActor in ... }`: task ordering is not guaranteed, and a `screenIsLocked` / `screenIsUnlocked` pair must be applied in the order it was delivered. A stream's `onTermination` closure runs off the main actor: it removes ITS continuation by id (each continuation is stored with a fresh `UUID` or counter id) through `Task { @MainActor [weak self] in self?.removeContinuation(id) }`, and the removal of the observers plus the flag reset happen inside that main-actor method when the last continuation goes (never directly in `onTermination`).

Tests (`LockFlagsTests`): all 8 combinations of the three flags -> `isLocked`; `.unknown.isLocked == true` and `.unknown == LockFlags(screenLocked: true, screensaverActive: false, onConsole: false)`; the pure helper `LockFlags.from(sessionDictionary:)`: nil -> unknown; `["kCGSSessionOnConsoleKey": true]` -> unlocked console; with `"CGSSessionScreenIsLocked": true` -> locked; `onConsole == false` -> locked; a dictionary missing the console key -> locked (fail closed). Put the merge in a pure function too (`LockFlags.merged(dictionary: LockFlags, notificationLocked: Bool, screensaverActive: Bool) -> LockFlags`, defined in `ScreenLockMonitor.swift` next to `LockFlags`; it returns `screenLocked = dictionary.screenLocked || notificationLocked`, `screensaverActive = dictionary.screensaverActive || screensaverActive` and `onConsole = dictionary.onConsole`) and test: a lock notification wins over an unlocked dictionary; an unlock notification does not clear a locked dictionary. The class is `@MainActor`, so the test class is `@MainActor final class ScreenLockMonitorTests: XCTestCase` (declare it in `LockFlagsTests.swift` next to `LockFlagsTests`, one class per declaration line) and builds `ScreenLockMonitor(sessionDictionary: { dict }, screensaverRunning: { running })` with a captured `var`: with NO observers, an unlocked console dictionary gives `isLocked == false`; a nil dictionary gives `true`; `["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": true]` gives `true`; a console dictionary plus `screensaverRunning` returning true gives `true`; changing the captured dictionary between two reads changes the answer (the dictionary is re-read on every call); creating and dropping a `changes` stream leaves `isLocked` dictionary-driven (flags reset). **The test that drives the notification path for real (not a trivially-true create-and-drop) is the `async` method `testLockAndUnlockNotificationsReachTheStream` on the `@MainActor` class and waits on the STREAM, never on the main queue and never on a sleep.** `drainMainQueue()` only waits for blocks that are ALREADY queued, and a `DistributedNotificationCenter` observer registered with `queue: .main` fires on a LATER run-loop turn (measured: after a main-queue sentinel drain the observer had not fired yet, it fired about 10 ms later), so "post, drain, assert" is red even when the monitor is correct. Write it exactly like this (the pattern was checked in a scratch program against a monitor of the same shape: it yields `true` on the lock post and `false` on the unlock post):

```swift
func testLockAndUnlockNotificationsReachTheStream() async {
    let center = NotificationCenter()                 // a PRIVATE center: nothing is posted system-wide, so no other app sees a fake lock
    let monitor = ScreenLockMonitor(sessionDictionary: { ["kCGSSessionOnConsoleKey": true] }, screensaverRunning: { false },
                                    notificationCenter: center)
    let stream = monitor.changes                      // creating the stream installs the observers; keep it alive in a local
    var iterator = stream.makeAsyncIterator()
    center.post(name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    let locked = await iterator.next()
    XCTAssertEqual(locked, true)
    XCTAssertTrue(monitor.isLocked)
    center.post(name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    let unlocked = await iterator.next()              // the injected dictionary is unlocked, so this yields false at once
    XCTAssertEqual(unlocked, false)
    XCTAssertFalse(monitor.isLocked)
}
```

The 0.5 s re-read after `screenIsUnlocked` is NOT awaited (the dictionary is already unlocked, so it changes nothing). Rules for this test: the dictionary closure returns an UNLOCKED console dictionary the whole time, `await` the first element of the stream and assert on that element, and no `Task.sleep`, no `drainMainQueue()`. Note for the implementer: the test posts to the private `NotificationCenter()` it injected, never to `DistributedNotificationCenter`, so no other app on the Mac sees a fake lock and the test needs no `distnoted`; observers are removed through the same center. (The observer blocks use `queue: .main`, so they run on the main queue after `post` returns; the `await` on the stream is what waits for them.) Pure and monitor tests together: at least 14 test methods in the file (`check-test-names.sh WP-PLATFORM` counts `func test`): write ONE method per case or bullet above, never a loop over a table of cases (folding the 8 flag combinations into one method would fail the count).

### 3.5 `SystemLocalExecutor`: `LocalExecuting`

`@MainActor final class SystemLocalExecutor: LocalExecuting`. It never shells out, never runs AppleScript, never opens URLs or documents.
Inject small seams (internal protocols, each with a real implementation and a test fake), so every branch is unit-tested. **File placement (a naming guess otherwise):** the four seam protocols `VolumeControlling`, `MediaTransporting`, `TimerControlling`, `AppLaunching` and their real implementations `SystemVolumeControl`, `NowPlayingTransport`, `WorkspaceAppLauncher` (and the `FocusTimerController` extension) all live in `SystemLocalExecutor.swift`; `LockFlags` lives in `ScreenLockMonitor.swift`; `HotKeyOutcome`, `CarbonHotKeyBox` and `PressTracker` live in `CarbonPushToTalk.swift`:

```swift
@MainActor protocol VolumeControlling { func current() -> Float?; func adjust(by delta: Float) -> Float? }   // real: SystemVolumeControl
@MainActor protocol MediaTransporting { func play(); func pause(); func next(); func previous() }          // real: NowPlayingTransport(controller:)
@MainActor protocol TimerControlling { var isActive: Bool { get }; func start(minutes: Int) -> Bool; func cancel() }  // real: FocusTimerController (extension)
@MainActor protocol AppLaunching { func launch(bundleID: String) async -> Bool }                           // real: WorkspaceAppLauncher
```

The real adapters, with their exact initializers, are in the table at the top of section 3. `NowPlayingTransport`: `play()`/`pause()` -> `MediaRemoteBridge.shared.send(.play / .pause)`; `next()`/`previous()` -> `NowPlayingController.next()/previous()` (they keep the optimistic UI state). `WorkspaceAppLauncher.launch`: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`, then `openApplication(at:configuration:)` with `NSWorkspace.OpenConfiguration()` (`activates = true`); no URL/file arguments; returns false if not found.

`execute(_:)` per intent (all return typed results, never throw):

| Intent | Behavior | Success `spoken` | Failure |
|---|---|---|---|
| `.mediaPlay/.mediaPause/.mediaNext/.mediaPrevious` | call the transport | `nil` | - |
| `.volumeSet(percent)` | `p = min(max(percent, 0), 100)` (the executor clamps an out-of-range percent, it never passes it on); `cur = current()`; target `Float(p)/100`; `adjust(by: target - cur)` (the seam is relative-only) | `"Volume \(p)"` | `current()` or `adjust` nil -> `.executionFailed("volume_unavailable")` |
| `.volumeStep(delta)` | `adjust(by: Float(delta)/100)` | `"Volume \(Int((new*100).rounded()))"` | nil -> `.executionFailed("volume_unavailable")` |
| `.mute` | `cur = current()`; `MuteMemory.mute(current: cur)` decides the target; if it returns a target, `adjust(by: target - cur)`; if it returns nil (already muted) do nothing and STILL succeed | `"Muted"` | `current()` or `adjust` nil -> `.executionFailed("volume_unavailable")` |
| `.unmute` | same with `MuteMemory.unmute(current:)`; nil (the user already raised it) -> do nothing and STILL succeed | `"Unmuted"` | as above |
| `.openApp(bundleID, name)` | `launch(bundleID:)` | `"Opening \(name)"` | false -> `.executionFailed("app_not_found")` |
| `.timerStart(minutes)` | `start(minutes:)` (the real one calls `FocusTimerController.start(duration: minutes*60)`) | `"Timer \(minutes) minutes"` | false -> `.executionFailed("timer_unavailable")` |
| `.timerCancel` | if `isActive` then `cancel()` | `"Timer cancelled"` or `"No timer running"` | - |

`MuteMemory` (pure struct, in `SystemLocalExecutor.swift`, tested in `MuteMemoryTests`): `mutating func mute(current: Float) -> Float?` returns the target volume to set (`0`) and remembers `current` when `current > 0.01`; returns `nil` (nothing to do) when already at or below 0.01. `mutating func unmute(current: Float) -> Float?` returns the remembered level when `current <= 0.01` (and forgets it); when `current <= 0.01` and nothing is remembered, returns `0.3`; returns `nil` when `current > 0.01` (the user already raised it) AND forgets any remembered level (the next mute overwrites it anyway, so a stale level can never be restored later). Tests cover: mute at 0.5 -> target 0, remembered; unmute at 0 -> 0.5 then forgotten; second unmute at 0 -> 0.3; unmute at 0.4 -> nil; mute at 0 -> nil and remembers nothing; mute twice keeps the first remembered level.

Tests (`SystemLocalExecutorTests`, which also DEFINES the shared fakes `FakeVolumeControl`, `FakeMediaTransport`, `FakeTimerControl`, `FakeAppLauncher`): one per row of the table using fakes (volume set 30 from 0.5 calls `adjust` with `-0.2 (±0.0001)`; failures map to the exact codes; `.openApp` passes the bundle id through untouched; `.timerStart(10)` calls `start(minutes: 10)`; cancel when inactive says "No timer running"; **`testVolumeSetClampsOutOfRangePercent`** (`.volumeSet(-1)` from 0.5 adjusts by `-0.5 (±0.0001)` and speaks "Volume 0"; `.volumeSet(101)` adjusts by `+0.5 (±0.0001)` and speaks "Volume 100"); `.mute` when already muted succeeds with "Muted" and calls no `adjust`; no seam is called for an intent that does not own it).

### 3.6 `VolumeDucker`: `MediaDucking`

`@MainActor final class VolumeDucker: MediaDucking`, with a `VolumeControlling` seam: designated `init(volume: VolumeControlling)` plus `convenience init() { self.init(volume: SystemVolumeControl()) }` (never a default argument that calls the `@MainActor` `SystemVolumeControl.init`, see the constructor table). `duck()`: if `current() > 0.15` remember `original` and set the volume to `0.15` (remember `ducked = the value actually set`); no-op if already ducked or the device has no settable volume. `restore()`: if ducked and `abs(current() - ducked) <= 0.02` set back to `original`; if the user changed the volume meanwhile leave it; always forget the state. Idempotent. Tests (`VolumeDuckerTests`, reusing `FakeVolumeControl` from `SystemLocalExecutorTests.swift`; every `Float` comparison uses `XCTAssertEqual(_, _, accuracy: 0.0001)`): duck from 0.6 -> 0.15; restore -> 0.6; user changed to 0.4 meanwhile -> restore leaves 0.4; duck at 0.1 -> no-op, restore -> no-op; double duck keeps the first original; unsettable device -> no state.

### 3.7 Audit: `AuditChain`, `FileAuditLogger`, `DiskFileWriter`: `AuditLogging`, `FileWriting`

**Format** (one JSON object per line, `JSONEncoder` with `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`, the `AuditRecord` type from the contract):

- `hash = lowercase hex SHA-256 (CryptoKit) of the UTF-8 bytes of: prevHash + "\n" + canonicalJSON`, where `canonicalJSON` is the record encoded with `hash` set to the empty string `""`. The very first record has `prevHash == ""`.
- `seq` starts at 1 and increments by 1. `timestamp` is `ISO8601DateFormatter` with `[.withInternetDateTime]`, UTC, from the injected `VoiceClock`.
- `transcriptHash` = SHA-256 hex of `draft.transcript` after `trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`, or nil when `draft.transcript` is nil or EMPTY AFTER TRIMMING (a whitespace-only transcript trims to empty and gives nil, never the hash of the empty string). Name the hash helper `sha256Hex` (not `fingerprint`: the final-check patterns are word-anchored, but do not tempt them) and declare it `private static func sha256Hex(_:)` on `AuditChain` (or file-private), never a module-level function, so it cannot collide with a helper of a later package. The transcript text itself is NEVER stored. `counters` are copied as-is (only keys given by the caller; the logger never invents text). `decision`/`outcome` strings are first reduced to the characters `[A-Za-z0-9_.:-]`: every UNICODE SCALAR outside that set becomes exactly ONE `_` (iterate `unicodeScalars`, not `Character`s, so a combining sequence or an emoji with a variation selector yields one `_` per scalar and the output length is deterministic), so no control character, `/` or non-ASCII ever reaches the JSON and the Swift encoder and `verify-audit.py` agree byte for byte on the canonical form; the result is then truncated to 64 characters. Counter keys are caller-controlled constants (`input_tokens`, ...) and are not user text. `tier` is an `Int?`: `record.tier = draft.tier?.rawValue` (never a string).

`AuditChain.swift` (pure, tested in `AuditChainTests`):

```swift
enum AuditChain {
    /// Builds the record AND fills in `hash`. Throws when the JSON encoding fails (never returns an unverifiable record).
    static func makeRecord(from draft: AuditDraft, seq: Int, timestamp: String, prevHash: String) throws -> AuditRecord
    static func line(for record: AuditRecord) throws -> String            // sorted-keys JSON, no trailing newline
    /// Uses `record.prevHash` (there is no separate prevHash argument that could disagree). Computed with `hash` set to "".
    static func hash(for record: AuditRecord) throws -> String
    static func verify(lines: [String]) -> AuditVerification
}
```

`makeRecord` builds the record with `hash == ""`, calls `hash(for:)`, and returns the record with the hash set. In `FileAuditLogger`, any throw from `makeRecord`/`line` makes `append` return `false`; an empty hash is never written.

`verify`: decode each line (a line that does not decode, or whose `seq` is not previous+1, or whose `prevHash` is not the previous record's `hash`, or whose recomputed hash differs, breaks the chain: `isValid == false`, `firstBrokenSeq` = that record's `seq` if decodable else the 1-based line number; `recordCount` = the number of consecutive GOOD records before the break (all records when valid); `headHash` = hash of the last GOOD record, `""` when there is none). Exact results: for a 5-record chain, altering record 3's `decision` gives `(isValid false, recordCount 2, firstBrokenSeq 3, headHash r2.hash)`; deleting record 2 gives lines `[r1, r3, r4, r5]`, so line 2 has `seq 3 != 2`: `(false, 1, 3, r1.hash)`; swapping records 2 and 3 gives `[r1, r3, r2, r4, r5]`: `(false, 1, 3, r1.hash)`; a garbage line at line 4 gives `(false, 3, 4, r3.hash)`. **The first record may have ANY `seq` and ANY `prevHash`** (a log continues across rotation and restarts; only the links between consecutive records are checked). Empty input -> `AuditVerification.empty`. **Blank lines are skipped, never counted as a break:** `verify(lines:)` ignores any element that is empty after trimming whitespace (the 1-based line number for a garbage line is counted over the NON-blank lines), and `DiskFileWriter.readLines` drops empty lines, so a trailing newline or a blank line never reports a break that the Python verifier (`verify-audit.py`, which also ignores blank lines) does not report.
Tests: building 5 records verifies valid with `recordCount == 5` and `headHash == last.hash`; changing one byte of record 3's `decision` -> `firstBrokenSeq == 3`; deleting record 2 -> broken at 3 (seq gap); swapping records -> broken; garbage line -> broken at that line; first record with non-empty `prevHash` and `seq == 7` is accepted (rotation continuity); the encoded line never contains the transcript text, a path, or the word you passed as `draft.transcript` (assert with a distinctive string); `transcriptHash` equals a known SHA-256 vector (`"hello"` -> `2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824`) for transcript `"  Hello \n"`; `record.tier` is the integer 2 for a `.t2` draft; a blank line between two records and a trailing blank line do not break the chain; a whitespace-only `draft.transcript` gives `transcriptHash == nil`; a `decision` with one emoji, one `/` and one combining accent comes out with one `_` per offending unicode scalar.

`FileAuditLogger: AuditLogging, @unchecked Sendable` (lock-guarded; constructor in the table at the top of this section). **`append` and `verify` are `async` protocol methods, so they must not call `lock()`/`unlock()` themselves (global rule 2).** Put ALL locked work in private SYNCHRONOUS helpers, `private func appendLocked(_ draft: AuditDraft) -> Bool` (lazy start, `makeRecord`, rotation, `appendLine`, `restrictToOwner`, state update; it takes and releases the lock) and `private func verifyLocked() -> AuditVerification`, and write `func append(_ draft: AuditDraft) async -> Bool { appendLocked(draft) }` and `func verify() async -> AuditVerification { verifyLocked() }`. **Lazy start:** nothing touches the disk until the first `append`: then `ensureDirectory` + `restrictToOwner` (0700 dir), and load the last record of the live file (to continue `seq` and `prevHash`; if the live file is absent or empty, load the last record of the newest rotated file `<name>.1.<ext>` instead; if the existing file does not verify, continue anyway from its last decodable record but make `verify()` report the break). Keep `seq` and `lastHash` in memory afterwards.

**Each append, in EXACTLY this order (the order is what keeps the hash chain consistent when something throws; do not reorder, and do not "tidy" the state update to the end):**

1. Lazy start if it has not run (a throw there returns `false`, leaves "started" false so the next append retries, and has appended nothing). Build the record and its line (`makeRecord`, `line`); a throw returns `false` with state unchanged.
2. If `fileSize(live) >= maxFileBytes`, **rotate** (algorithm below). On a rotation throw return `false` and leave `seq` and `lastHash` UNCHANGED (the live file is never lost by a failed rotation; the next append retries it).
3. `appendLine(line, to: live)`. On a throw return `false` with `seq` and `lastHash` unchanged (nothing reached the disk).
4. IMMEDIATELY after `appendLine` succeeds, set `seq = record.seq` and `lastHash = record.hash`. The line is on disk now, so the in-memory state must describe it, whatever happens next.
5. Then `restrictToOwner(live)` (0600), best effort. If it throws, return `false` (the coordinator then refuses risky actions, `auditWritable`) but KEEP the state from step 4: the record IS in the file, and an append that reused its `seq` and `prevHash` would make `verify()` report a permanent break that looks like tampering. Otherwise return `true`.

The new live file's first record keeps `prevHash` = the last hash and `seq` continues. No error ever escapes: `append` never throws.

**Rotation algorithm (exact).** Rotated name: insert `.N` before the extension: `rotatedName(n)` = `voice-audit.N.jsonl` for the default `fileName` (`"voice-audit.jsonl"`); for any `fileName` split at the last `.` (`base`, `ext`), `base + "." + N + "." + ext`, and `base + "." + N` when there is no extension. Let `K = max(1, keepRotated)`. Rotate:

1. for `i` from `K` down to `2`, written EXACTLY as `for i in stride(from: K, through: 2, by: -1)` (never `(2...K).reversed()`, which traps when `K == 1` because `2...1` is an invalid range; with `K == 1` the loop body must simply not run): `src = rotated(i - 1)`, `dst = rotated(i)`; if `fileSize(src) > 0` then `moveItem(at: src, to: dst)` (a rotated file that does not exist yet has size 0 and is skipped, because `FileManager.moveItem` throws on a missing source; the oldest file is overwritten by the move);
2. then `moveItem(at: live, to: rotated(1))`.

`DiskFileWriter.moveItem(at:to:)` is defined as **remove the destination if it exists, then move** (`FileManager.moveItem` fails when the destination exists). The `FileWriting` protocol has no `exists`; `fileSize > 0` is the presence test.

`verify()` reads the current (live) file and returns `AuditChain.verify`. The default directory helper: `FileAuditLogger.defaultDirectory()` = `~/Library/Application Support/desnotch/voice` built from `FileManager` (not a string literal, not a machine-specific path); never force-unwrap `urls(for:in:)[0]`: use `.first` and fall back to `URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")`.
Tests (`FileAuditLoggerTests`, with the contract's `InMemoryFileWriter` and `FakeVoiceClock(_:)`; the throwing double `ThrowingFileWriter` is defined in this file): append 3 -> 3 lines, verify valid; a second logger instance on the same writer continues `seq == 4` with the right `prevHash`; a writer that throws -> `append` false and no crash; rotation at a tiny `maxFileBytes` creates the rotated file (`voice-audit.1.jsonl`) and the chain continues across it, and a SECOND rotation shifts `.1` to `.2` without throwing on the missing `.2`/`.3`; `keepRotated: 1` (K == 1) rotates without trapping and keeps only `.1`; `keepRotated: 0` behaves as 1; **`testAppendAfterARestrictFailureKeepsTheChainContinuous`** (a double `RestrictOnceFailingFileWriter`, defined in this file, wraps an `InMemoryFileWriter` and makes `restrictToOwner` throw ONCE, on the first call whose `url.pathExtension` is `jsonl`, i.e. the FILE restrict of the first append; the directory restrict of the lazy start is not a `.jsonl` url and is unaffected): append A returns `false`, append B returns `true`, the writer holds both lines, and `verify()` is valid with `recordCount == 2` and consecutive `seq` values (A's `seq`, then A's `seq + 1`) and B's `prevHash` equal to A's `hash`; **`testPythonVerifierAgreesWithTheSwiftChain`** (turns the Swift/Python canonical-form agreement into an automated check; it needs no app): in a UUID temp directory write a log with the REAL `FileAuditLogger` + `DiskFileWriter` (a small `maxFileBytes`, at least 6 appends including a draft with a transcript, one with a `/` and a non-ASCII `outcome`, and AT LEAST one rotation so a `.1` file exists; with a tiny `maxFileBytes` several rotations happen and `.2`/`.3` appear, which is fine: pass only the `.1` file and then the live file, because `.1` immediately precedes the live file), then run `/usr/bin/python3 -I <repo>/scripts/voice-harness/verify-audit.py <rotated .1 file> <live file>` (oldest first) with `Process` and a `Pipe`, and assert exit status 0 and output starting with `verify-audit: ok`. **Repo-root lookup (exact; do NOT copy `PillSourceGuardTests`'s 6-level loop, it is too short for the harness layout).** In `FileAuditLoggerTests.swift` define `private func findVerifierScript(from filePath: String = #filePath) -> URL?`: start at the DIRECTORY of `filePath` (level 0), and walk up at most 12 levels (`deletingLastPathComponent()` each step); return the first `<dir>/scripts/voice-harness/verify-audit.py` that exists (`FileManager.default.fileExists`), else `nil`. It must work in both layouts the test runs in: the CI layout `<repo>/Tests/DesnotchCoreTests/Voice/Platform/FileAuditLoggerTests.swift` (the repo is 4 levels up) and the default harness layout `<repo>/.build/voice-harness/Sources/runner/Tests/Voice/Platform/FileAuditLoggerTests.swift` (the repo is 7 levels up; `run.sh` compiles the copy under `$HARNESS_DIR`, and `#filePath` is that copy's path). With `HARNESS_DIR` pointing OUTSIDE the repo (the `mktemp -d` warning check of section 4) the script is not reachable, `findVerifierScript` returns nil, and the test must `return` after a comment saying "layout unknown (HARNESS_DIR outside the repo)" (no `XCTSkip`, no `XCTFail`). If `/usr/bin/python3` does not exist, or the `Process` cannot be launched, `return` after a comment saying why (no `XCTSkip`); a launched process with a non-zero exit FAILS the test. Also tamper with one byte of the live file and assert the verifier exits 1. **A second test, `testVerifierLookupSucceedsInTheStandardLayouts`**, guards against the first one passing vacuously: if `#filePath` contains `/.build/voice-harness/` (default harness) or `/Tests/DesnotchCoreTests/Voice/Platform/` (CI, or a worktree), `XCTAssertNotNil(findVerifierScript())`; in any other layout it returns without asserting. **Gate for the package:** the default-directory run must PRINT the pass line, not merely have no failure: `scripts/voice-harness/run.sh --filter FileAuditLoggerTests 2>&1 | grep -E '^ok +FileAuditLoggerTests\.(testPythonVerifierAgreesWithTheSwiftChain|testVerifierLookupSucceedsInTheStandardLayouts)$'` must print exactly those two lines (section 4). `NullAuditLogger` contract (returns false) is NOT your concern. `DiskFileWriter` (`FileWriting`, real `FileManager`/`FileHandle`, creates files with 0600 and directories with 0700, `appendLine` writes `line + "\n"` atomically per call, `readLines` of an absent file returns `[]`, `moveItem` removes an existing destination first) tests (`DiskFileWriterTests`) use a UUID temp directory: round trip, permissions (`attributesOfItem` `posixPermissions` 0o600 / 0o700), absent file, move onto an existing destination replaces it, `fileSize` of an absent file is 0.

### 3.8 `SystemVoicePermissions` + `PermissionSnapshot`: `VoicePermissionProviding`

`@MainActor final class SystemVoicePermissions: VoicePermissionProviding`. `status()` is non-prompting: `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()` mapped by pure functions with these exact signatures: `nonisolated static func state(forMicrophone status: AVAuthorizationStatus) -> VoicePermissionState` and `nonisolated static func state(forSpeech status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermissionState` (and `nonisolated static func hasUsageDescription(info: [String: Any]?, key: String) -> Bool`). Because the class is `@MainActor`, declare these helpers and `hasUsageDescription` as **`nonisolated static func`** (they touch no state), so the pure-table tests may call them from a plain (non-`@MainActor`) `XCTestCase`; otherwise declare `SystemVoicePermissionsTests` as `@MainActor final class`. Either shape compiles; the unannotated mix ("static on a `@MainActor` class, called from a nonisolated test") does not on Swift 5.10. (`PermissionSnapshot` is a plain `Sendable` struct, so its `microphoneState(for:)` / `speechState(for:)` need no annotation; the file gains `import AVFoundation` and `import Speech`.)

**The two enums have DIFFERENT raw values. Do not share one table and do not switch on `rawValue`; switch on the enum cases, with an `@unknown default` branch returning `.unknown`.**

| Raw value | `AVAuthorizationStatus` (microphone) | `SFSpeechRecognizerAuthorizationStatus` (speech) |
|---|---|---|
| 0 | `notDetermined` | `notDetermined` |
| 1 | `restricted` | `denied` |
| 2 | `denied` | `restricted` |
| 3 | `authorized` | `authorized` |
| 99 | `unknown` (both initializers `init(rawValue: 99)` return non-nil, and the `@unknown default` branch handles it) | `unknown` |

`request()` asks for microphone then speech (`AVCaptureDevice.requestAccess(for: .audio)` and `SFSpeechRecognizer.requestAuthorization`, wrapped in `withCheckedContinuation`), skipping a prompt whose state is already determined, and returns the new `status()`. It is called only from the Settings "Allow Access…" button; never at launch. **TCC guard:** both request APIs abort the process (a TCC crash) when the host bundle's Info.plist lacks the matching usage string, which is the case under `swift run` or the test runner. Before each prompt check `Bundle.main.object(forInfoDictionaryKey:)` for `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` through a pure helper `SystemVoicePermissions.hasUsageDescription(info: [String: Any]?, key: String) -> Bool` (true only for a non-empty string); if the key is absent skip that prompt and return `status()` unchanged.
`PermissionSnapshot` gains `microphone` and `speech` (type `AuthorizationState`, mapped from the same statuses; add `static func microphoneState(for: AVAuthorizationStatus)` / `speechState(for: SFSpeechRecognizerAuthorizationStatus)`, switching on the enum cases with `@unknown default` -> `.unknown`; do NOT copy the rawValue switch of `calendarState`). The stored properties are declared in this order, after the existing ones: `accessibility, calendar, reminders, microphone, speech` (the tests construct the struct with labelled memberwise arguments), included in the Codable JSON with the keys `"microphone"` and `"speech"`. Update `PermissionSnapshotTests` (the JSON-labels test now expects five keys; add mapping tests for every case of both enums). `scripts/permission-status.sh` extracts `microphone` and `speech` with `plutil -extract` into variables and prints each on its own labelled line (`echo "microphone: $microphone"`, `echo "speech: $speech"`) so no variable is unused (shellcheck SC2034), and does NOT require them under `REQUIRE_GRANTED`.
Tests (`SystemVoicePermissionsTests`): the two mapping tables above via `AVAuthorizationStatus(rawValue:)` / `SFSpeechRecognizerAuthorizationStatus(rawValue:)` (0, 1, 2, 3, and 99 -> `.unknown` for both), and `hasUsageDescription` (nil info, missing key, empty string, non-string value, a real string).

### 3.9 Packaging

Make these exact changes (keep style; `bash -n` must pass; keep `shellcheck`-clean quoting):

- `scripts/build-app.sh` Info.plist: add `<key>NSMicrophoneUsageDescription</key><string>desnotch listens while you hold the voice shortcut and turns what you say into a command on this Mac. Audio is never saved or sent anywhere.</string>` and `<key>NSSpeechRecognitionUsageDescription</key><string>desnotch uses on-device speech recognition to turn what you say into text. Nothing is sent to Apple.</string>`; in the hardened-runtime section assert the signed entitlements contain `com.apple.security.device.audio-input` (same style as the existing calendars assertion, with a `fail` message).
- `scripts/desnotch.entitlements`: add `com.apple.security.device.audio-input` = true with a comment like the calendars one (hardened runtime blocks the microphone prompt without it).
- `scripts/smoke-test.sh` has TWO branches and each gets its own addition. (a) The unconditional Info.plist block (used in the normal AND the hardened run): add `/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$PLIST" >/dev/null` and the same for `:NSSpeechRecognitionUsageDescription` next to the calendar prints. (b) The `if [[ "$signed_info" == *flags=*runtime* ]]` block (hardened run only): inside it, right after the existing calendars assertion and USING the `signed_entitlements` variable that block already assigned (do not run `codesign -d --entitlements` a second time), add `[[ "$signed_entitlements" == *com.apple.security.device.audio-input* ]] || { echo "error: hardened-runtime app lacks the audio-input entitlement" >&2; exit 1; }`. The same applies to `scripts/build-app.sh`: its existing hardened assertion (around `signed_entitlements="$(codesign -d --entitlements - --xml ...)"`) gets the audio-input check next to the calendars one with a `fail` message, reusing that variable.
- `scripts/permission-status.sh`: print `microphone`/`speech` as described in 3.8; optional strictness not added.

## 4. Tests and verification

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

  In a sandbox that only allows writes inside the worktree use `W="$PWD/.build/scratch-check"; rm -rf "$W"` instead of `mktemp -d` (`.build/` is gitignored; remove `$W` afterwards). Commands this package needs to be allowed to run (the full list, because the S2 spike, the two packaging runs and the harness scripts use all of them): `swift`, `swiftc` (the S2 spike compile), `rsync`, `python3`, `/usr/bin/python3` (the audit test), `rg`, `grep`, `sed`, `awk`, `bash`, `plutil`, `codesign`, `/usr/libexec/PlistBuddy`, `lipo`, `file`, `find`, `shasum`, `ditto`, `xcrun`, `ps`, `xxd`, `cp`, `cmp`, `mkdir`, `mktemp`, `rm` (limited to `.build`, `dist` and the scratch directories) and read-only `git` (`status`, `diff`, `ls-files`, `describe`, `rev-list`, `log`; `check-ownership.sh` and `build-app.sh` use them). `swift build` also writes caches under `~/Library/Caches` and `~/.cache/clang`; a worktree-only sandbox must allow those or the build cannot run. If `rm -rf` of a scratch directory reports "Directory not empty" right after a build, wait for `swift-build` to exit and rerun the `rm`.

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

**Sandbox note.** `swift build` also writes the SwiftPM and clang module caches under `~/Library/Caches` and `~/.cache`, and `DiskFileWriterTests`, `FileAuditLoggerTests` and the Python agreement test write under `FileManager.default.temporaryDirectory`, which is `$TMPDIR`, outside the worktree. If your tool is confined to the worktree, allow those locations, or run `export TMPDIR="$PWD/.build/tmp"; mkdir -p "$TMPDIR"` before the runs (and use `$PWD/.build/...` for `HARNESS_DIR` and `--scratch-path`). A command allowlist applies to the top-level command only: the harness scripts call `tee`, `tail`, `head`, `sort`, `tr`, `cat`, `dirname`, `wc`, `ls`, `awk`, `grep`, `rg` and `python3` internally.

Run and report:

```sh
swift build 2>&1 | grep -E "warning:|error:|Build complete"
scripts/voice-harness/run.sh --filter LevelMeterTests
scripts/voice-harness/run.sh --filter VoiceHotkeyMapTests
scripts/voice-harness/run.sh --filter PressTrackerTests
scripts/voice-harness/run.sh --filter CarbonHotKeyOutcomeTests
scripts/voice-harness/run.sh --filter CarbonPushToTalkLifecycleTests   # a substring filter: --filter PressTrackerTests does NOT match this class
scripts/voice-harness/run.sh --filter LockFlagsTests
scripts/voice-harness/run.sh --filter SystemLocalExecutorTests
scripts/voice-harness/run.sh --filter MuteMemoryTests
scripts/voice-harness/run.sh --filter VolumeDuckerTests
scripts/voice-harness/run.sh --filter AuditChainTests
scripts/voice-harness/run.sh --filter FileAuditLoggerTests 2>&1 | grep -E '^ok +FileAuditLoggerTests\.(testPythonVerifierAgreesWithTheSwiftChain|testVerifierLookupSucceedsInTheStandardLayouts)$|^harness:'   # must show BOTH ok lines (the Python agreement test really ran) and 0 failed
scripts/voice-harness/run.sh --filter DiskFileWriterTests
scripts/voice-harness/run.sh --filter SystemVoicePermissionsTests
scripts/voice-harness/run.sh --filter SpeechDecisionTests
scripts/voice-harness/run.sh --filter CaptureBookTests
scripts/voice-harness/run.sh --filter ScreenLockMonitorTests
scripts/voice-harness/run.sh --filter PermissionSnapshotTests
scripts/voice-harness/run.sh
scripts/voice-harness/lint-lite.sh Sources/DesnotchCore/Voice/Platform/*.swift Tests/DesnotchCoreTests/Voice/Platform/*.swift Sources/DesnotchCore/App/PermissionSnapshot.swift Tests/DesnotchCoreTests/PermissionSnapshotTests.swift
scripts/voice-harness/check-ownership.sh WP-PLATFORM
scripts/voice-harness/check-test-names.sh WP-PLATFORM      # every mandated test name, class and count exists (PLAN gate G7)
# forbidden patterns (PLAN section 12, "Final checks"): each must print nothing, comments included
rg -n '\bprint\(|\bNSLog\(|\bos_log|\bLogger\(|\.onHover|repeatForever|serve --stop|pkill|killall|hermes pause|osascript|auth\.json|AXIsProcessTrusted' Sources/DesnotchCore/Voice/Platform
rg -n 'AVAudioFile|SFSpeechURLRecognitionRequest|URLSession|setVoiceProcessingEnabled|allow_session|allow_always|deny_always|NSAppleScript|AXUIElement' Sources/DesnotchCore/Voice/Platform
rg -n 'requiresOnDeviceRecognition = true' Sources/DesnotchCore/Voice/Platform/AppleSpeechRecognizer.swift     # must print exactly one hit (comments count: never write that assignment, or AVAudioFile, URLSession, setVoiceProcessingEnabled, in a comment; say "on-device-only flag" and so on)
git diff origin/main -- Sources | rg '^\+.*(\bprint\(|\bNSLog\(|\bos_log|\bLogger\()'                         # PermissionSnapshot.swift too; must print nothing
for f in scripts/build-app.sh scripts/smoke-test.sh scripts/permission-status.sh; do bash -n "$f" && echo "ok $f"; done
plutil -lint scripts/desnotch.entitlements
VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
HARDENED_RUNTIME=1 VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
```

(`dist/` and `.build/` are gitignored. The two packaging runs prove the Info.plist keys and the hardened entitlement; each `build-app.sh` run takes about 60 s with a warm `.build`, but a fresh worktree does a COLD release build that takes noticeably longer and can hit a shell tool's timeout: run `swift build -c release 2>&1 | grep -E 'warning:|error:|Build complete'` once first (and pass a long timeout, 10 minutes), then the two packaging runs. Do not abort them. If `scripts/smoke-test.sh` needs variables, read its header and use them. `shellcheck` is not installed on this Mac but CI runs it on `scripts/*.sh`: keep every variable used and every expansion quoted.)

Done means: build clean; the warning check of section 4 prints nothing; every class above `0 failed`; full suite no failures beyond the two baseline ones; lint clean; the packaged app passes `smoke-test.sh` in both modes; `git status` shows only the files of section 2.

## 5. Manual checklist (report each as DONE / NOT DONE / BLOCKED and what you saw; none can be automated by an agent)

Items 1 to 6 need a physical key press, a spoken sentence, a microphone, TCC grants, or a running application event loop that no agent session has. **Report items 1 to 6 as `BLOCKED: human-run`** (item 1 with the compiled spike path from section 3.3, item 2 onward with what the human has to do); they are not an acceptance criterion for you, and they move to the human's section 15 (S2, S3, S5). Item 7 you DO run. Items that launch the packaged app need the installed `/Applications/desnotch.app` to be quit by the human (single-instance guard); never quit or kill it yourself.

On the Mac mini (Command Line Tools, no notch, external or built-in microphone), for the human:

1. S2: `kEventHotKeyReleased` arrives for Option-Command-V (run the standalone `s2` program from 3.3; the result goes in the human's report).
2. A scratch harness that starts `AppleSpeechRecognizer` for `en-US` prints (for the human's eyes only; never committed) partial/final text for a spoken sentence; `.captureStarted` precedes everything; `.level` arrives at about 15 Hz. `en-US` supports on-device recognition on this Mac.
3. Same for `id-ID`: on this Mac `supportsOnDeviceRecognition` is false ("No Assistant asset for language id-ID"), so the stream must fail with `.unavailable(.recognizer)` and NEVER record to a server; confirm that.
4. Denied microphone permission yields `.permissionDenied(.microphone)` and no prompt.
5. `cancel()` mid-capture leaves no running engine (the orange mic indicator goes out); a silent capture ends with `.final("")` (the pill says "no speech", not "Voice isn't available").
6. `VolumeDucker` and the executor intents against the real volume/media/timer/app launch (Safari, Music).
7. (You run this.) Packaged app: Settings-less check that `Info.plist` has both usage strings and the hardened build carries the audio-input entitlement (`scripts/smoke-test.sh dist/desnotch.app` in both modes).

## 6. Global rules

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
   spec above shows one. Holding an `AsyncStream` continuation is done with `let (stream, continuation) = AsyncStream<T>.makeStream()` (3.3 and 3.4), never with a captured optional and `!`; the contract stub `VoiceStubs.swift` shows the pattern.
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
   `docs/voice/*`, `scripts/voice-harness/*`, `.github/*`, or anything under `Sources/DesnotchCore/MediaRemote/Vendor/`.
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
   prefix your package doc prescribes). **File-scope (column 0) helper FUNCTIONS and constants are `private` too** (`private func step(...)`, `private let t0`): an internal helper with the same signature as a `private` one in another file of the module is an "invalid redeclaration" error, while two `private` ones coexist (WP-LOGIC's `env`, `ctx`, `step`, `runScript`, `t0` are `private` for that reason), and before naming any type run `rg -n "class <Name>|struct <Name>" Tests` and change the name
   **Never name a file-scope helper (or a method you add to a test class) after an `XCTestCase`/`XCTest` member** (`run`, `name`, `record`, `measure`, `wait`, `expectation`, `setUp`, `tearDown`, `invokeTest`, `addTeardownBlock`, `continueAfterFailure`): an unqualified call inside a test method resolves to the inherited instance member first and fails to compile under real XCTest ("use of 'run' refers to instance method rather than global function"), and the local stub harness cannot catch it. Use specific names (`runScript`, `env`, `ctx`, `step`, `t0`, `assertParse`, `checkCase`).
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

## 7. DO NOT

- Do NOT use `osascript`, `NSAppleScript`, `Process`/`posix_spawn` for ANY of the local intents, Accessibility APIs (`AXUIElement`, `AXIsProcessTrusted` prompts), screen capture, or `NSWorkspace.open(_ url:)` with arbitrary URLs.
- Do NOT use server-side recognition, `SFSpeechURLRecognitionRequest` on a file, `AVAudioFile`, or write audio anywhere. Do NOT enable voice processing / AEC (`setVoiceProcessingEnabled`) in this phase.
- Do NOT request any permission from `start()`, `init` or at app launch. Only `SystemVoicePermissions.request()` prompts.
- Do NOT edit `App/GlobalHotKey.swift`, `Audio/SystemVolume.swift`, `FocusTimerController`, `NowPlayingController`, `MediaRemoteBridge`, `SubprocessRunner`, or any UI file; use them through their public API.
- Do NOT store transcripts, commands, paths or audio metadata in the audit log. Do NOT make the audit file world-readable.
- Do NOT add polling timers or leave observers/hotkeys registered after `stop()`/`deinit`.
- Do NOT touch `SettingsStore.swift`, `AppComposition.swift`, `Package.swift`, `AGENTS.md`, the contracts, or other work packages' files.
- Do NOT leave debug logging, temporary executables or preview code in the tree.
- Do NOT run `git add/commit/push/...`.
