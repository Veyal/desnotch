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
`PressTrackerTests.swift`, `LockFlagsTests.swift`, `SystemLocalExecutorTests.swift`, `MuteMemoryTests.swift`, `VolumeDuckerTests.swift`,
`AuditChainTests.swift`, `FileAuditLoggerTests.swift`, `DiskFileWriterTests.swift`, `SystemVoicePermissionsTests.swift`.
**Changed test**: `Tests/DesnotchCoreTests/PermissionSnapshotTests.swift`.

## 3. Components

For every component: the type is `internal` (no `public`) unless stated, named exactly as below, and implements the protocol from `Contracts/Protocols.swift`. Logic that is not hardware is split into a small **pure** type so it is unit-tested;
the hardware glue around it is verified by the manual checklist in section 5.

**Constructors are part of the contract.** WP-HERMES builds these objects in `AppComposition` without reading your code, and every one of them is built eagerly at launch even when voice is OFF, so every `init` below must be **side-effect free**: no `AVAudioEngine`, no observers, no hot-key registration, no permission calls, no directory creation. Real work starts in `start()` / on the first call.

| Type | Exact initializer(s) | Notes |
|---|---|---|
| `AppleSpeechRecognizer` | `init()` | creates the `AVAudioEngine` inside `start(...)`, never here |
| `AppleSpeechSynthesizer` | `init()` | creates the `AVSpeechSynthesizer` lazily on the first `speak` |
| `CarbonPushToTalk` | `init(choice: VoiceHotkeyChoice, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })` | `PressTracker` lives in `CarbonPushToTalk.swift` |
| `ScreenLockMonitor` | `init()` | observers are added lazily (3.4) |
| `SystemLocalExecutor` | designated `init(volume: VolumeControlling, media: MediaTransporting, timer: TimerControlling, apps: AppLaunching)`; `convenience init(nowPlaying: NowPlayingController, focusTimer: FocusTimerController)` building the real adapters below | |
| `SystemVolumeControl` | `init()` | `: VolumeControlling`; wraps the `SystemVolume` static functions (`SystemVolume` is an enum of static functions and cannot conform to a protocol itself) |
| `NowPlayingTransport` | `init(controller: NowPlayingController)` | `: MediaTransporting`; in `SystemLocalExecutor.swift` |
| `WorkspaceAppLauncher` | `init()` | `: AppLaunching`; in `SystemLocalExecutor.swift` |
| `FocusTimerController` | `extension FocusTimerController: TimerControlling` in `SystemLocalExecutor.swift` | `isActive` is true when `state` is `.running` or `.paused`; `start(minutes:)` = `start(duration: TimeInterval(minutes * 60))`; `cancel()` is the existing method |
| `VolumeDucker` | `init(volume: VolumeControlling = SystemVolumeControl())` | |
| `SystemVoicePermissions` | `init()` | |
| `DiskFileWriter` | `init()` | |
| `FileAuditLogger` | `init(directory: URL, fileName: String = "voice-audit.jsonl", writer: FileWriting, clock: VoiceClock, maxFileBytes: Int = 1_048_576, keepRotated: Int = 4)`, plus `static func defaultDirectory() -> URL` | |
| `LevelMeter` / `EmitThrottle` | `EmitThrottle` lives in `LevelMeter.swift` | |

**Test doubles are shared by file name, so they must not collide.** All test files of the whole package share one module. The fakes for `VolumeControlling`, `MediaTransporting`, `TimerControlling` and `AppLaunching` are defined ONCE, in `SystemLocalExecutorTests.swift`, with these exact names: `FakeVolumeControl`, `FakeMediaTransport`, `FakeTimerControl`, `FakeAppLauncher` (internal, not `private`). `VolumeDuckerTests.swift` reuses `FakeVolumeControl` and must NOT declare its own. The throwing `FileWriting` double (`ThrowingFileWriter`) is defined once, in `FileAuditLoggerTests.swift`. Before you name any other helper type run `rg -n "class <Name>|struct <Name>" Tests` and rename on a collision; a duplicate declaration only shows up when CI builds the whole test module.

### 3.1 `AppleSpeechRecognizer` (+ `LevelMeter`): `SpeechRecognizing`

Class `AppleSpeechRecognizer: SpeechRecognizing, @unchecked Sendable` guarding ALL mutable state with one `NSLock` (the tap callback takes it briefly; never hold it while calling out to Speech or yielding to the continuation more than a plain `yield`).

**Capture token.** Every `start` creates a new capture with a fresh token. Every callback (audio tap, Speech result handler, engine completion) captures its token and, under the lock, ignores itself unless it is still the current token. `cancel()`, a finished stream, `endAudio` completion and a new `start` clear or replace the current token. This is what stops a late cancellation error from becoming a bogus `.failed`, or a second `.final`, after the capture is over.

`start(localeIdentifier:contextualStrings:)` (returns the stream; calling it while a capture is active first cancels that capture):

1. Check permissions WITHOUT prompting: `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()`. Not `.authorized` -> yield `.failed(.permissionDenied(.microphone))` or `.permissionDenied(.speech)` and finish.
2. `SFSpeechRecognizer(locale: Locale(identifier:))`; nil or `!isAvailable` -> `.failed(.unavailable(.recognizer))`. **`supportsOnDeviceRecognition == false` -> `.failed(.unavailable(.recognizer))`** (never use server recognition). (On this Mac `id-ID` has no on-device asset, so it always fails here; that is correct.)
3. `SFSpeechAudioBufferRecognitionRequest`: `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`, `taskHint = .dictation`, `contextualStrings = contextualStrings`, `addsPunctuation = false` (macOS 13+).
4. `AVAudioEngine` (created here): `let format = engine.inputNode.outputFormat(forBus: 0)`. **If `format.sampleRate > 0 && format.channelCount > 0` does not hold (no input device), yield `.failed(.unavailable(.recognizer))` and finish BEFORE `installTap`: `installTap` with a zero-rate format raises an `NSException` that kills the process.** Then install the tap (`bufferSize: 1024`, that format) and `engine.start()`; if `engine.start()` throws, remove the tap, yield `.failed(.unavailable(.recognizer))` and finish. In the tap, under the lock, check the token and call `request.append(buffer)` right there (do not hop asynchronously with the buffer, the engine may reuse it). On the FIRST buffer yield `.captureStarted` (this is when the "listening" earcon plays). Compute `rms` per buffer, feed `LevelMeter`, and yield `.level(x)` at most `VoiceLimits.meterMaxHz` (15) times per second (`EmitThrottle`). Audio buffers are only handed to the request; never write them anywhere.
5. Set `continuation.onTermination = { [weak self] _ in self?.cancel(token: token) }`: a consumer that drops the stream (for example a cancelled `Task`) must stop the engine and clear the tap, and it must cancel only ITS capture, not a newer one.
6. Recognition results (token-checked):
   - non-final -> remember the text as `lastPartial` and yield `.partial(text)`;
   - final (`result.isFinal`) -> yield `.final(text)`, tear down (stop engine, remove tap), finish;
   - an error AFTER `endAudio()` was called (the user ended the capture): with a non-empty `lastPartial` yield `.final(lastPartial)`; with an empty `lastPartial` yield `.final("")` (a normal "the user said nothing" ends in an error; the reducer turns the empty final into the "no speech" message, R50, not into "Voice isn't available"); then tear down and finish;
   - an error BEFORE `endAudio()` was called -> `.failed(.unavailable(.recognizer))`, tear down, finish.
7. `endAudio()`: record that the user ended the capture, `request.endAudio()`, stop the engine, remove the tap. The final result (or the error handled above) then arrives. `cancel()`: clear the token, cancel the task, stop the engine, remove the tap, finish the stream with NO final and NO failure. Both are idempotent and safe to call when nothing is active. Never leave the engine running or the tap installed after the stream finished.

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

Tests (`LevelMeterTests`): `level(fromRMS: 0) == 0`; `1.0 -> 1.0`; `0.00316 (-50 dB) -> 0 (±0.001)`; `0.0316 (-30 dB) -> 0.4 (±0.01)`; `0.1 (-20 dB) -> 0.6 (±0.01)`; `2.0 -> 1` (clamped); negative or NaN -> 0; `bars([])` is five zeros; `bars([0.5])` is `[0,0,0,0,0.5]`; seven values keep the last five in order; `EmitThrottle(maxHz: 15)`: first call true, call at +0.03 false, at +0.07 true (>= 0.0667 since last true), non-monotonic time (earlier than last) false.

### 3.2 `AppleSpeechSynthesizer`: `SpeechSynthesizing`

`AVSpeechSynthesizer`. `speak(_:localeIdentifier:)` creates an `AVSpeechUtterance` with `AVSpeechSynthesisVoice(language: localeIdentifier)` (nil voice -> default), speaks, and returns when the delegate reports `didFinish` (true) or `didCancel` (false). `stop()` calls `stopSpeaking(at: .immediate)`. Only one synthesizer instance, created lazily on first use (not at init). The delegate bridging is guarded by one lock; call into AVSpeechSynthesizer on the main thread (hop with `Task { @MainActor }`).
**Continuations are keyed by utterance identity** (`ObjectIdentifier(utterance)`), not held in a single slot: a second `speak` while speaking stops the first, resumes the superseded caller with `false` IMMEDIATELY, and the old utterance's asynchronous `didCancel` then finds no entry and does nothing (a single slot would resolve the wrong caller).
Text longer than `VoiceLimits.maxReplyCharacters` is cut to that length. No tests (hardware); covered by the manual checklist.

### 3.3 `CarbonPushToTalk` (+ `VoiceHotkeyMap`, `PressTracker`): `PushToTalkSource`

Follow `CarbonHotKeyRegistrar` in `App/GlobalHotKey.swift` (do NOT edit that file). `@MainActor final class CarbonPushToTalk: PushToTalkSource`.

- Registers three Carbon hot keys with signature `'DSVC'` (0x44535643): id 1 = the talk key (from `VoiceHotkeyMap`), id 2 = the stop chord **⌥⌘.** (`kVK_ANSI_Period`, `cmdKey | optionKey`), id 3 = **Esc** (`kVK_Escape`, no modifiers), registered ONLY while `setCancelKeyArmed(true)`; `setCancelKeyArmed(false)` unregisters it.
- Installs ONE event handler for BOTH `kEventHotKeyPressed` and `kEventHotKeyReleased` (two `EventTypeSpec`s). This is the key difference from the existing registrar, which only handles presses.
- **Swift 5.10 pattern (follow `GlobalHotKey.swift`):** the C callback does its work in a non-isolated helper; it captures the timestamp (`uptime()`) INSIDE the callback, before any hop; it hops with `DispatchQueue.main.async` (FIFO, so a press and its release stay ordered) and re-enters with `MainActor.assumeIsolated`. Do NOT use `Task { @MainActor }` for press/release: task ordering is not guaranteed. Do not call the `@MainActor` `stop()` from `deinit`: `deinit` releases the Carbon refs through non-isolated stored properties only.
- The handler feeds a `PressTracker` (pure) to produce events: talk key press -> `.pressed`; release -> `.released(heldSeconds:)`; stop chord press -> `.stopKey`; Esc press -> `.cancelKey`.
- **Lifecycle, one rule: the instance is single-use.** `events` is an `AsyncStream<PushToTalkEvent>` created once in `init`. `start()` registers and returns `.active`; **`start()` while already started is idempotent and returns `.active`**; `stop()` unregisters everything, removes the handler, finishes the stream, and **`start()` after `stop()` returns `.unavailable` and registers nothing** (the finished stream cannot be reused). The coordinator therefore creates a NEW instance whenever `voiceHotkey` changes (`keys.stop(); keys = makeKeys(newChoice)`).
- **Registration failures.** `start()` returns `.unavailable` if the talk key OR the stop chord cannot be registered, after unregistering whatever it did register: voice must never run without its global kill-switch layer (the pill Stop button and the status menu remain either way). Failing to register Esc (id 3) is silent and best-effort (it never changes the returned status).
- `VoiceHotkeyMap.swift` (pure): `VoiceHotkeyMap.binding(for: VoiceHotkeyChoice) -> HotKeyBinding` using the existing `HotKeyBinding` type (`keyCode`, `carbonModifiers`, `keyLabel`): `optionCommandV` -> `kVK_ANSI_V`, `cmdKey|optionKey`, "V"; `shiftOptionCommandV` -> `kVK_ANSI_V`, `cmdKey|optionKey|shiftKey`, "V"; `optionCommandJ` -> `kVK_ANSI_J`, `cmdKey|optionKey`, "J". Tests check `displayString` is `⌥⌘V`, `⇧⌥⌘V`, `⌥⌘J`, that none equals `HotKeyBinding.default` (⌥⌘N), none uses `controlKey`, and the three are pairwise distinct.
- `PressTracker` (pure, tested, in `CarbonPushToTalk.swift`): `struct PressTracker { mutating func press(at: TimeInterval) -> Bool; mutating func release(at: TimeInterval) -> Double? }`. `press` returns true only if no press is currently down (a duplicate press while down returns false and does not reset the start time); `release` returns the held seconds (>= 0, clamped) and clears the state, or nil if no press was down. Tests: normal hold 0.8 s; duplicate press ignored; release without press nil; release before press time (clock went backward) returns 0; two cycles in a row.
- **Spike S2 (human-run; you do NOT run it).** It asks one OS question: does `kEventHotKeyReleased` arrive for an Option-Command hot key? It needs a physical key press and a running application event loop, and a scratch executable cannot import our internal types (and cannot live in the tree), so the recipe is a standalone program independent of our code. Do this: (1) write it to a scratch directory OUTSIDE the repository (for example under your scratchpad), (2) compile it with `swiftc s2.swift -o s2` (it must compile with no error; this is the only part you run), (3) in your report list it as `BLOCKED: human-run` and give the path; the human runs `./s2` and presses and releases Option-Command-V a few times. Expected output has a `pressed` and a `RELEASED` line per cycle. The program:

  ```swift
  import AppKit
  import Carbon.HIToolbox

  func say(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
  var hotKeyRef: EventHotKeyRef?
  var handlerRef: EventHandlerRef?
  var started = ProcessInfo.processInfo.systemUptime
  let callback: EventHandlerUPP = { _, event, _ in
      let kind = event.map { GetEventKind($0) } ?? 0
      let now = ProcessInfo.processInfo.systemUptime - started
      say(String(format: "%.3f %@", now, kind == UInt32(kEventHotKeyReleased) ? "RELEASED" : "pressed"))
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
  say("install=\(installStatus) register=\(registerStatus) (0 = ok); press and release Option-Command-V now, exiting in 25 s")
  NSApplication.shared.setActivationPolicy(.accessory)
  Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in
      if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
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

**Merge rule (safety-relevant, exact; it must never fail open).** There are two sources and the screen counts as locked if EITHER says so:

- `dictionaryLocked`: from `CGSessionCopyCurrentDictionary()` (key `"CGSSessionScreenIsLocked"` present and true = locked); `onConsole` comes ONLY from the dictionary (`kCGSSessionOnConsoleKey` = `"kCGSSessionOnConsoleKey"`, must be present and true; a dictionary without it is "not on console", i.e. locked). If the dictionary is nil -> `LockFlags.unknown`.
- `notificationLocked` and `screensaverActive`: stored booleans set by `DistributedNotificationCenter` notifications `com.apple.screenIsLocked` (set), `com.apple.screenIsUnlocked` (clear), `com.apple.screensaver.didstart` (`screensaverActive = true`) and `com.apple.screensaver.didstop` (clear).
- `screenLocked = dictionaryLocked || notificationLocked`. Re-read the dictionary on every notification, but never let a not-yet-flipped dictionary override a lock notification (the pure re-read would fail open when `screenIsLocked` arrives before the dictionary flips). Because the dictionary can also lag behind `screenIsUnlocked`, re-read it once more 0.5 s after that notification (one `DispatchQueue.main.asyncAfter`, not a repeating timer).
- `isLocked` returns the current merged flags' `isLocked`.

**Observation is lazy.** `init()` adds no observer (the monitor is built at launch even with voice off). `changes` returns a NEW `AsyncStream<Bool>` per access (AsyncStream is single-consumer, and the coordinator and the UI may both want it); the monitor keeps the continuations in an array, adds its notification observers when the first one is created and removes them when the last one terminates (`onTermination`). A stream yields the new merged `isLocked` Bool only when it changes (not on every notification). No timers other than the one-shot above.

Tests (`LockFlagsTests`): all 8 combinations of the three flags -> `isLocked`; `.unknown.isLocked == true` and `.unknown == LockFlags(screenLocked: true, screensaverActive: false, onConsole: false)`; the pure helper `LockFlags.from(sessionDictionary:)`: nil -> unknown; `["kCGSSessionOnConsoleKey": true]` -> unlocked console; with `"CGSSessionScreenIsLocked": true` -> locked; `onConsole == false` -> locked; a dictionary missing the console key -> locked (fail closed). Put the merge in a pure function too (`LockFlags.merged(dictionary: LockFlags, notificationLocked: Bool, screensaverActive: Bool) -> LockFlags`) and test: a lock notification wins over an unlocked dictionary; an unlock notification does not clear a locked dictionary.

### 3.5 `SystemLocalExecutor`: `LocalExecuting`

`@MainActor final class SystemLocalExecutor: LocalExecuting`. It never shells out, never runs AppleScript, never opens URLs or documents.
Inject small seams (internal protocols, each with a real implementation and a test fake), so every branch is unit-tested:

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
| `.volumeSet(percent)` | `cur = current()`; target `Float(percent)/100`; `adjust(by: target - cur)` (the seam is relative-only) | `"Volume \(percent)"` | `current()` or `adjust` nil -> `.executionFailed("volume_unavailable")` |
| `.volumeStep(delta)` | `adjust(by: Float(delta)/100)` | `"Volume \(Int((new*100).rounded()))"` | nil -> `.executionFailed("volume_unavailable")` |
| `.mute` | `cur = current()`; `MuteMemory.mute(current: cur)` decides the target; if it returns a target, `adjust(by: target - cur)`; if it returns nil (already muted) do nothing and STILL succeed | `"Muted"` | `current()` or `adjust` nil -> `.executionFailed("volume_unavailable")` |
| `.unmute` | same with `MuteMemory.unmute(current:)`; nil (the user already raised it) -> do nothing and STILL succeed | `"Unmuted"` | as above |
| `.openApp(bundleID, name)` | `launch(bundleID:)` | `"Opening \(name)"` | false -> `.executionFailed("app_not_found")` |
| `.timerStart(minutes)` | `start(minutes:)` (the real one calls `FocusTimerController.start(duration: minutes*60)`) | `"Timer \(minutes) minutes"` | false -> `.executionFailed("timer_unavailable")` |
| `.timerCancel` | if `isActive` then `cancel()` | `"Timer cancelled"` or `"No timer running"` | - |

`MuteMemory` (pure struct, in `SystemLocalExecutor.swift`, tested in `MuteMemoryTests`): `mutating func mute(current: Float) -> Float?` returns the target volume to set (`0`) and remembers `current` when `current > 0.01`; returns `nil` (nothing to do) when already at or below 0.01. `mutating func unmute(current: Float) -> Float?` returns the remembered level when `current <= 0.01` (and forgets it); when `current <= 0.01` and nothing is remembered, returns `0.3`; returns `nil` when `current > 0.01` (the user already raised it). Tests cover: mute at 0.5 -> target 0, remembered; unmute at 0 -> 0.5 then forgotten; second unmute at 0 -> 0.3; unmute at 0.4 -> nil; mute at 0 -> nil and remembers nothing; mute twice keeps the first remembered level.

Tests (`SystemLocalExecutorTests`, which also DEFINES the shared fakes `FakeVolumeControl`, `FakeMediaTransport`, `FakeTimerControl`, `FakeAppLauncher`): one per row of the table using fakes (volume set 30 from 0.5 calls `adjust` with `-0.2 (±0.0001)`; failures map to the exact codes; `.openApp` passes the bundle id through untouched; `.timerStart(10)` calls `start(minutes: 10)`; cancel when inactive says "No timer running"; `.mute` when already muted succeeds with "Muted" and calls no `adjust`; no seam is called for an intent that does not own it).

### 3.6 `VolumeDucker`: `MediaDucking`

`@MainActor final class VolumeDucker: MediaDucking`, with a `VolumeControlling` seam (`init(volume: VolumeControlling = SystemVolumeControl())`). `duck()`: if `current() > 0.15` remember `original` and set the volume to `0.15` (remember `ducked = the value actually set`); no-op if already ducked or the device has no settable volume. `restore()`: if ducked and `abs(current() - ducked) <= 0.02` set back to `original`; if the user changed the volume meanwhile leave it; always forget the state. Idempotent. Tests (`VolumeDuckerTests`, reusing `FakeVolumeControl` from `SystemLocalExecutorTests.swift`): duck from 0.6 -> 0.15; restore -> 0.6; user changed to 0.4 meanwhile -> restore leaves 0.4; duck at 0.1 -> no-op, restore -> no-op; double duck keeps the first original; unsettable device -> no state.

### 3.7 Audit: `AuditChain`, `FileAuditLogger`, `DiskFileWriter`: `AuditLogging`, `FileWriting`

**Format** (one JSON object per line, `JSONEncoder` with `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`, the `AuditRecord` type from the contract):

- `hash = lowercase hex SHA-256 (CryptoKit) of the UTF-8 bytes of: prevHash + "\n" + canonicalJSON`, where `canonicalJSON` is the record encoded with `hash` set to the empty string `""`. The very first record has `prevHash == ""`.
- `seq` starts at 1 and increments by 1. `timestamp` is `ISO8601DateFormatter` with `[.withInternetDateTime]`, UTC, from the injected `VoiceClock`.
- `transcriptHash` = SHA-256 hex of `draft.transcript` after `trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`, or nil when `draft.transcript` is nil or empty. The transcript text itself is NEVER stored. `counters` are copied as-is (only keys given by the caller; the logger never invents text). `decision`/`outcome` strings are truncated to 64 characters. `tier` is an `Int?`: `record.tier = draft.tier?.rawValue` (never a string).

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

`verify`: decode each line (a line that does not decode, or whose `seq` is not previous+1, or whose `prevHash` is not the previous record's `hash`, or whose recomputed hash differs, breaks the chain: `isValid == false`, `firstBrokenSeq` = that record's `seq` if decodable else the 1-based line number; `headHash` = hash of the last GOOD record). **The first record may have ANY `seq` and ANY `prevHash`** (a log continues across rotation and restarts; only the links between consecutive records are checked). Empty input -> `AuditVerification.empty`.
Tests: building 5 records verifies valid with `recordCount == 5` and `headHash == last.hash`; changing one byte of record 3's `decision` -> `firstBrokenSeq == 3`; deleting record 2 -> broken at 3 (seq gap); swapping records -> broken; garbage line -> broken at that line; first record with non-empty `prevHash` and `seq == 7` is accepted (rotation continuity); the encoded line never contains the transcript text, a path, or the word you passed as `draft.transcript` (assert with a distinctive string); `transcriptHash` equals a known SHA-256 vector (`"hello"` -> `2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824`) for transcript `"  Hello \n"`; `record.tier` is the integer 2 for a `.t2` draft.

`FileAuditLogger: AuditLogging, @unchecked Sendable` (lock-guarded; constructor in the table at the top of this section). **Lazy start:** nothing touches the disk until the first `append`: then `ensureDirectory` + `restrictToOwner` (0700 dir), and load the last record of the live file (to continue `seq` and `prevHash`; if the live file is absent or empty, load the last record of the newest rotated file `<name>.1.<ext>` instead; if the existing file does not verify, continue anyway from its last decodable record but make `verify()` report the break). Keep `seq` and `lastHash` in memory afterwards.

Each append: build the record (`makeRecord`), then if `fileSize(live) >= maxFileBytes` **rotate** (algorithm below), then `appendLine`, then `restrictToOwner` the file (0600). The new live file's first record keeps `prevHash` = the last hash and `seq` continues. Any thrown error -> `append` returns false (and never throws).

**Rotation algorithm (exact).** Rotated name: insert `.N` before the extension: `rotatedName(n)` = `voice-audit.N.jsonl` for the default `fileName` (`"voice-audit.jsonl"`); for any `fileName` split at the last `.` (`base`, `ext`), `base + "." + N + "." + ext`, and `base + "." + N` when there is no extension. Let `K = max(1, keepRotated)`. Rotate:

1. for `i` from `K` down to `2`: `src = rotated(i - 1)`, `dst = rotated(i)`; if `fileSize(src) > 0` then `moveItem(at: src, to: dst)` (a rotated file that does not exist yet has size 0 and is skipped, because `FileManager.moveItem` throws on a missing source; the oldest file is overwritten by the move);
2. then `moveItem(at: live, to: rotated(1))`.

`DiskFileWriter.moveItem(at:to:)` is defined as **remove the destination if it exists, then move** (`FileManager.moveItem` fails when the destination exists). The `FileWriting` protocol has no `exists`; `fileSize > 0` is the presence test.

`verify()` reads the current (live) file and returns `AuditChain.verify`. The default directory helper: `FileAuditLogger.defaultDirectory()` = `~/Library/Application Support/desnotch/voice` built from `FileManager` (not a string literal, not a machine-specific path).
Tests (`FileAuditLoggerTests`, with the contract's `InMemoryFileWriter` and `FakeVoiceClock(_:)`; the throwing double `ThrowingFileWriter` is defined in this file): append 3 -> 3 lines, verify valid; a second logger instance on the same writer continues `seq == 4` with the right `prevHash`; a writer that throws -> `append` false and no crash; rotation at a tiny `maxFileBytes` creates the rotated file (`voice-audit.1.jsonl`) and the chain continues across it, and a SECOND rotation shifts `.1` to `.2` without throwing on the missing `.2`/`.3`; `NullAuditLogger` contract (returns false) is NOT your concern. `DiskFileWriter` (`FileWriting`, real `FileManager`/`FileHandle`, creates files with 0600 and directories with 0700, `appendLine` writes `line + "\n"` atomically per call, `readLines` of an absent file returns `[]`, `moveItem` removes an existing destination first) tests (`DiskFileWriterTests`) use a UUID temp directory: round trip, permissions (`attributesOfItem` `posixPermissions` 0o600 / 0o700), absent file, move onto an existing destination replaces it, `fileSize` of an absent file is 0.

### 3.8 `SystemVoicePermissions` + `PermissionSnapshot`: `VoicePermissionProviding`

`@MainActor final class SystemVoicePermissions: VoicePermissionProviding`. `status()` is non-prompting: `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()` mapped by pure functions `SystemVoicePermissions.state(forMicrophone:)` / `state(forSpeech:)` to `VoicePermissionState`.

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
- `scripts/smoke-test.sh`: add `PlistBuddy -c "Print :NSMicrophoneUsageDescription"` and `:NSSpeechRecognitionUsageDescription` checks next to the calendar ones, and the hardened-runtime entitlement assertion for `audio-input`.
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
scripts/voice-harness/run.sh --filter LevelMeterTests
scripts/voice-harness/run.sh --filter VoiceHotkeyMapTests
scripts/voice-harness/run.sh --filter PressTrackerTests
scripts/voice-harness/run.sh --filter LockFlagsTests
scripts/voice-harness/run.sh --filter SystemLocalExecutorTests
scripts/voice-harness/run.sh --filter MuteMemoryTests
scripts/voice-harness/run.sh --filter VolumeDuckerTests
scripts/voice-harness/run.sh --filter AuditChainTests
scripts/voice-harness/run.sh --filter FileAuditLoggerTests
scripts/voice-harness/run.sh --filter DiskFileWriterTests
scripts/voice-harness/run.sh --filter SystemVoicePermissionsTests
scripts/voice-harness/run.sh --filter PermissionSnapshotTests
scripts/voice-harness/run.sh
scripts/voice-harness/lint-lite.sh Sources/DesnotchCore/Voice/Platform/*.swift Tests/DesnotchCoreTests/Voice/Platform/*.swift Sources/DesnotchCore/App/PermissionSnapshot.swift Tests/DesnotchCoreTests/PermissionSnapshotTests.swift
scripts/voice-harness/check-ownership.sh WP-PLATFORM
for f in scripts/build-app.sh scripts/smoke-test.sh scripts/permission-status.sh; do bash -n "$f" && echo "ok $f"; done
plutil -lint scripts/desnotch.entitlements
VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
HARDENED_RUNTIME=1 VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
```

(`dist/` and `.build/` are gitignored. The two packaging runs prove the Info.plist keys and the hardened entitlement; each `build-app.sh` run takes about 60 s, do not abort it. If `scripts/smoke-test.sh` needs variables, read its header and use them. `shellcheck` is not installed on this Mac but CI runs it on `scripts/*.sh`: keep every variable used and every expansion quoted.)

Done means: build clean; every class above `0 failed`; full suite no failures beyond the two baseline ones; lint clean; the packaged app passes `smoke-test.sh` in both modes; `git status` shows only the files of section 2.

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
