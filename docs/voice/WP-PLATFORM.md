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

### 3.1 `AppleSpeechRecognizer` (+ `LevelMeter`): `SpeechRecognizing`

Class `AppleSpeechRecognizer: SpeechRecognizing, @unchecked Sendable` guarding ALL state with one serial `DispatchQueue`.

`start(localeIdentifier:contextualStrings:)` (returns the stream; calling it while a capture is active first cancels that capture):

1. Check permissions WITHOUT prompting: `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()`. Not `.authorized` -> yield `.failed(.permissionDenied(.microphone))` or `.permissionDenied(.speech)` and finish.
2. `SFSpeechRecognizer(locale: Locale(identifier:))`; nil or `!isAvailable` -> `.failed(.unavailable(.recognizer))`. **`supportsOnDeviceRecognition == false` -> `.failed(.unavailable(.recognizer))`** (never use server recognition).
3. `SFSpeechAudioBufferRecognitionRequest`: `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`, `taskHint = .dictation`, `contextualStrings = contextualStrings`, `addsPunctuation = false` (macOS 13+).
4. `AVAudioEngine`: install a tap on `inputNode` (`bufferSize: 1024`, the input node's format), append each buffer to the request. On the FIRST buffer yield `.captureStarted` (this is when the "listening" earcon plays). Compute `rms` per buffer, feed `LevelMeter`, and yield `.level(x)` at most `VoiceLimits.meterMaxHz` (15) times per second. Audio buffers are only handed to the request; never write them anywhere.
5. Recognition results: non-final -> `.partial(text)`; final (`result.isFinal`) -> `.final(text)`, then stop the engine, remove the tap, finish the stream. A recognition error AFTER `endAudio()` with a non-empty last partial -> treat the last partial as the final (Apple sometimes errors at the end). An error otherwise -> `.failed(.unavailable(.recognizer))` and finish.
6. `endAudio()`: `request.endAudio()`, stop the engine, remove the tap. The final result then arrives. `cancel()`: cancel the task, stop the engine, remove the tap, finish the stream with NO final. Both are idempotent and safe to call when nothing is active. Never leave the engine running or the tap installed after the stream finished.

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

`AVSpeechSynthesizer`. `speak(_:localeIdentifier:)` creates an `AVSpeechUtterance` with `AVSpeechSynthesisVoice(language: localeIdentifier)` (nil voice -> default), speaks, and returns when the delegate reports `didFinish` (true) or `didCancel` (false). `stop()` calls `stopSpeaking(at: .immediate)`. A second `speak` while speaking stops the first (returns false for it). Only one synthesizer instance, created lazily on first use (not at init). The delegate bridging is guarded by one lock; call into AVSpeechSynthesizer on the main thread (hop with `Task { @MainActor }`).
Text longer than `VoiceLimits.maxReplyCharacters` is cut to that length. No tests (hardware); covered by the manual checklist.

### 3.3 `CarbonPushToTalk` (+ `VoiceHotkeyMap`, `PressTracker`): `PushToTalkSource`

Follow `CarbonHotKeyRegistrar` in `App/GlobalHotKey.swift` (do NOT edit that file). `@MainActor final class CarbonPushToTalk: PushToTalkSource`.

- Registers three Carbon hot keys with signature `'DSVC'` (0x44535643): id 1 = the talk key (from `VoiceHotkeyMap`), id 2 = the stop chord **⌥⌘.** (`kVK_ANSI_Period`, `cmdKey | optionKey`), id 3 = **Esc** (`kVK_Escape`, no modifiers), registered ONLY while `setCancelKeyArmed(true)`; `setCancelKeyArmed(false)` unregisters it.
- Installs ONE event handler for BOTH `kEventHotKeyPressed` and `kEventHotKeyReleased` (two `EventTypeSpec`s). This is the key difference from the existing registrar, which only handles presses.
- The handler hops to the main queue and feeds a `PressTracker` (pure) to produce events: talk key press -> `.pressed`; release -> `.released(heldSeconds:)`; stop chord press -> `.stopKey`; Esc press -> `.cancelKey`. Time comes from `ProcessInfo.processInfo.systemUptime` (injectable `() -> TimeInterval` for tests).
- `events` is an `AsyncStream<PushToTalkEvent>` created once in `init`; `start()` registers and returns `.active`, or `.unavailable` if the talk key could not be registered (another app owns it). `stop()` unregisters everything, removes the handler, finishes the stream. The settings key `voiceHotkey` is read by the coordinator, which creates a new instance (or calls `start()` after `stop()`) when it changes: accept `init(choice: VoiceHotkeyChoice, uptime: @escaping () -> TimeInterval = ...)`.
- `VoiceHotkeyMap.swift` (pure): `VoiceHotkeyMap.binding(for: VoiceHotkeyChoice) -> HotKeyBinding` using the existing `HotKeyBinding` type (`keyCode`, `carbonModifiers`, `keyLabel`): `optionCommandV` -> `kVK_ANSI_V`, `cmdKey|optionKey`, "V"; `shiftOptionCommandV` -> `kVK_ANSI_V`, `cmdKey|optionKey|shiftKey`, "V"; `optionCommandJ` -> `kVK_ANSI_J`, `cmdKey|optionKey`, "J". Tests check `displayString` is `⌥⌘V`, `⇧⌥⌘V`, `⌥⌘J`, that none equals `HotKeyBinding.default` (⌥⌘N), none uses `controlKey`, and the three are pairwise distinct.
- `PressTracker` (pure, tested): `struct PressTracker { mutating func press(at: TimeInterval) -> Bool; mutating func release(at: TimeInterval) -> Double? }`. `press` returns true only if no press is currently down (a duplicate press while down returns false and does not reset the start time); `release` returns the held seconds (>= 0, clamped) and clears the state, or nil if no press was down. Tests: normal hold 0.8 s; duplicate press ignored; release without press nil; release before press time (clock went backward) returns 0; two cycles in a row.
- **Spike S2 (manual, report the result):** confirm on this Mac that `kEventHotKeyReleased` actually arrives for a registered Option-Command combination (log once during development with a temporary local `os.Logger` line that you REMOVE before finishing). Put the observed result in your final report. If release events do not arrive, say so prominently: the plan then switches to toggle-only talk.

### 3.4 `ScreenLockMonitor` (+ `LockFlags`): `LockStateProviding`

`@MainActor final class ScreenLockMonitor: LockStateProviding`. Pure core:

```swift
struct LockFlags: Equatable {
    var screenLocked: Bool
    var screensaverActive: Bool
    var onConsole: Bool            // false = a different user session is in front (fast user switching)
    var isLocked: Bool { screenLocked || screensaverActive || !onConsole }
    static let unknown: LockFlags  // screenLocked: true, others as needed so that isLocked == true
}
```

Source of truth: `DistributedNotificationCenter.default()` notifications `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` and `com.apple.screensaver.didstart` / `com.apple.screensaver.didstop`; the initial value and the console check from `CGSessionCopyCurrentDictionary()` (keys `"CGSSessionScreenIsLocked"` (present and true = locked) and `kCGSSessionOnConsoleKey` (`"kCGSSessionOnConsoleKey"`, must be true)). If the dictionary is nil -> `LockFlags.unknown` (locked). Re-read the dictionary on every notification (do not trust the notification name alone). `isLocked` returns the current flags' `isLocked`; `changes` yields the new Bool whenever it changes (not on every notification). Observers are added in `init`/`start()` and removed in `deinit`/`stop()`; no timers.
Tests (`LockFlagsTests`): all 8 combinations of the three flags -> `isLocked`; `.unknown.isLocked == true`; a pure helper `LockFlags.from(sessionDictionary: [String: Any]?)` that you also write: nil -> unknown; `["kCGSSessionOnConsoleKey": true]` -> unlocked console; with `"CGSSessionScreenIsLocked": true` -> locked; `onConsole == false` -> locked; a dictionary missing the console key -> locked (fail closed).

### 3.5 `SystemLocalExecutor`: `LocalExecuting`

`@MainActor final class SystemLocalExecutor: LocalExecuting`. It never shells out, never runs AppleScript, never opens URLs or documents.
Inject small seams (internal protocols, each with a real implementation and a test fake), so every branch is unit-tested:

```swift
@MainActor protocol VolumeControlling { func current() -> Float?; func adjust(by delta: Float) -> Float? }   // real: SystemVolume
@MainActor protocol MediaTransporting { func play(); func pause(); func next(); func previous() }          // real: NowPlayingTransport(controller:)
@MainActor protocol TimerControlling { var isActive: Bool { get }; func start(minutes: Int) -> Bool; func cancel() }  // real: FocusTimerController
@MainActor protocol AppLaunching { func launch(bundleID: String) async -> Bool }                           // real: NSWorkspace
```

`NowPlayingTransport`: `play()`/`pause()` -> `MediaRemoteBridge.shared.send(.play / .pause)`; `next()`/`previous()` -> `NowPlayingController.next()/previous()` (they keep the optimistic UI state). The `AppLaunching` real implementation: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`, then `openApplication(at:configuration:)` with `NSWorkspace.OpenConfiguration()` (`activates = true`); no URL/file arguments; returns false if not found.

`execute(_:)` per intent (all return typed results, never throw):

| Intent | Behavior | Success `spoken` | Failure |
|---|---|---|---|
| `.mediaPlay/.mediaPause/.mediaNext/.mediaPrevious` | call the transport | `nil` | - |
| `.volumeSet(percent)` | `cur = current()`; target `Float(percent)/100`; `adjust(by: target - cur)` | `"Volume \(percent)"` | `current()` or `adjust` nil -> `.executionFailed("volume_unavailable")` |
| `.volumeStep(delta)` | `adjust(by: Float(delta)/100)` | `"Volume \(Int((new*100).rounded()))"` | nil -> `.executionFailed("volume_unavailable")` |
| `.mute` | `MuteMemory.mute(current:)` decides the target; set it | `"Muted"` | volume unavailable -> `.executionFailed("volume_unavailable")` |
| `.unmute` | `MuteMemory.unmute(current:)` decides the target (or nothing) | `"Unmuted"` | as above |
| `.openApp(bundleID, name)` | `launch(bundleID:)` | `"Opening \(name)"` | false -> `.executionFailed("app_not_found")` |
| `.timerStart(minutes)` | `start(minutes:)` (the real one calls `FocusTimerController.start(duration: minutes*60)`) | `"Timer \(minutes) minutes"` | false -> `.executionFailed("timer_unavailable")` |
| `.timerCancel` | if `isActive` then `cancel()` | `"Timer cancelled"` or `"No timer running"` | - |

`MuteMemory` (pure struct, in `SystemLocalExecutor.swift`, tested in `MuteMemoryTests`): `mutating func mute(current: Float) -> Float?` returns the target volume to set (`0`) and remembers `current` when `current > 0.01`; returns `nil` (nothing to do) when already at or below 0.01. `mutating func unmute(current: Float) -> Float?` returns the remembered level when `current <= 0.01` (and forgets it); when `current <= 0.01` and nothing is remembered, returns `0.3`; returns `nil` when `current > 0.01` (the user already raised it). Tests cover: mute at 0.5 -> target 0, remembered; unmute at 0 -> 0.5 then forgotten; second unmute at 0 -> 0.3; unmute at 0.4 -> nil; mute at 0 -> nil and remembers nothing; mute twice keeps the first remembered level.

Tests (`SystemLocalExecutorTests`): one per row of the table using fakes (volume set 30 from 0.5 calls `adjust` with `-0.2 (±0.0001)`; failures map to the exact codes; `.openApp` passes the bundle id through untouched; `.timerStart(10)` calls `start(minutes: 10)`; cancel when inactive says "No timer running"; no seam is called for an intent that does not own it).

### 3.6 `VolumeDucker`: `MediaDucking`

`@MainActor final class VolumeDucker: MediaDucking`, with a `VolumeControlling` seam. `duck()`: if `current() > 0.15` remember `original` and set the volume to `0.15` (remember `ducked = the value actually set`); no-op if already ducked or the device has no settable volume. `restore()`: if ducked and `abs(current() - ducked) <= 0.02` set back to `original`; if the user changed the volume meanwhile leave it; always forget the state. Idempotent. Tests (`VolumeDuckerTests`): duck from 0.6 -> 0.15; restore -> 0.6; user changed to 0.4 meanwhile -> restore leaves 0.4; duck at 0.1 -> no-op, restore -> no-op; double duck keeps the first original; unsettable device -> no state.

### 3.7 Audit: `AuditChain`, `FileAuditLogger`, `DiskFileWriter`: `AuditLogging`, `FileWriting`

**Format** (one JSON object per line, `JSONEncoder` with `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`, the `AuditRecord` type from the contract):

- `hash = lowercase hex SHA-256 (CryptoKit) of the UTF-8 bytes of: prevHash + "\n" + canonicalJSON`, where `canonicalJSON` is the record encoded with `hash` set to the empty string `""`. The very first record has `prevHash == ""`.
- `seq` starts at 1 and increments by 1. `timestamp` is `ISO8601DateFormatter` with `[.withInternetDateTime]`, UTC, from the injected `VoiceClock`.
- `transcriptHash` = SHA-256 hex of `draft.transcript` after `trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`, or nil when `draft.transcript` is nil or empty. The transcript text itself is NEVER stored. `counters` are copied as-is (only keys given by the caller; the logger never invents text). `decision`/`outcome` strings are truncated to 64 characters.

`AuditChain.swift` (pure, tested in `AuditChainTests`):

```swift
enum AuditChain {
    static func makeRecord(from draft: AuditDraft, seq: Int, timestamp: String, prevHash: String) -> AuditRecord
    static func line(for record: AuditRecord) throws -> String            // sorted-keys JSON, no trailing newline
    static func hash(for record: AuditRecord, prevHash: String) throws -> String   // computed with record.hash == ""
    static func verify(lines: [String]) -> AuditVerification
}
```

`verify`: decode each line (a line that does not decode, or whose `seq` is not previous+1, or whose `prevHash` is not the previous record's `hash` (the first record may have any `prevHash`), or whose recomputed hash differs, breaks the chain: `isValid == false`, `firstBrokenSeq` = that record's `seq` if decodable else the 1-based line number; `headHash` = hash of the last GOOD record). Empty input -> `AuditVerification.empty`.
Tests: building 5 records verifies valid with `recordCount == 5` and `headHash == last.hash`; changing one byte of record 3's `decision` -> `firstBrokenSeq == 3`; deleting record 2 -> broken at 3 (seq gap); swapping records -> broken; garbage line -> broken at that line; first record with non-empty `prevHash` is accepted (rotation continuity); the encoded line never contains the transcript text, a path, or the word you passed as `draft.transcript` (assert with a distinctive string); `transcriptHash` equals a known SHA-256 vector (`"hello"` -> `2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824`) for transcript `"  Hello \n"`.

`FileAuditLogger: AuditLogging, @unchecked Sendable` (lock-guarded): `init(directory: URL, fileName: String = "voice-audit.jsonl", writer: FileWriting, clock: VoiceClock, maxFileBytes: Int = 1_048_576, keepRotated: Int = 4)`. On the first `append` (lazy): `ensureDirectory` + `restrictToOwner` (0700 dir), load the existing file's last record (to continue `seq` and `prevHash`; if the existing file does not verify, continue anyway from its last decodable record but make `verify()` report the break). Each append: if `fileSize >= maxFileBytes` rotate (`voice-audit.N.jsonl`, shifting 1..keepRotated, dropping the oldest; the new file's first record keeps `prevHash` = last hash, `seq` continues), then `appendLine`, `restrictToOwner` the file (0600). Any thrown error -> `append` returns false (and never throws). `verify()` reads the current file and returns `AuditChain.verify`. The default directory helper: `FileAuditLogger.defaultDirectory()` = `~/Library/Application Support/desnotch/voice` built from `FileManager` (not a string literal, not a machine-specific path).
Tests (`FileAuditLoggerTests`, with the contract's `InMemoryFileWriter` and `FakeVoiceClock`): append 3 -> 3 lines, verify valid; a second logger instance on the same writer continues `seq == 4` with the right `prevHash`; a writer that throws -> `append` false and no crash; rotation at a tiny `maxFileBytes` creates the rotated file and the chain continues across it; `NullAuditLogger` contract (returns false) is NOT your concern. `DiskFileWriter` (`FileWriting`, real `FileManager`/`FileHandle`, creates files with 0600 and directories with 0700, `appendLine` writes `line + "\n"` atomically per call, `readLines` of an absent file returns `[]`, `moveItem` replaces) tests (`DiskFileWriterTests`) use a UUID temp directory: round trip, permissions (`attributesOfItem` `posixPermissions` 0o600 / 0o700), absent file, move replaces.

### 3.8 `SystemVoicePermissions` + `PermissionSnapshot`: `VoicePermissionProviding`

`@MainActor final class SystemVoicePermissions: VoicePermissionProviding`. `status()` is non-prompting: `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()` mapped by pure functions `SystemVoicePermissions.state(forMicrophone:)` / `state(forSpeech:)` to `VoicePermissionState` (`notDetermined -> .notDetermined`, `restricted -> .restricted`, `denied -> .denied`, `authorized -> .authorized`, anything else `.unknown`). `request()` asks for microphone then speech (`AVCaptureDevice.requestAccess(for: .audio)` and `SFSpeechRecognizer.requestAuthorization`, wrapped in `withCheckedContinuation`), skipping a prompt whose state is already determined, and returns the new `status()`. It is called only from the Settings "Allow Access…" button; never at launch.
`PermissionSnapshot` gains `microphone` and `speech` (type `AuthorizationState`, mapped from the same raw statuses; add `static func microphoneState(for:)` / `speechState(for:)`), included in the Codable JSON with the keys `"microphone"` and `"speech"`. Update `PermissionSnapshotTests` (the JSON-labels test now expects five keys; add mapping tests for every raw status 0...3 and an out-of-range one). `scripts/permission-status.sh` prints the extra keys but does NOT require them under `REQUIRE_GRANTED`.
Tests (`SystemVoicePermissionsTests`): the mapping tables via `AVAuthorizationStatus(rawValue:)` / `SFSpeechRecognizerAuthorizationStatus(rawValue:)` (0 notDetermined, 1 restricted, 2 denied, 3 authorized, 99 unknown).

### 3.9 Packaging

Make these exact changes (keep style; `bash -n` must pass; keep `shellcheck`-clean quoting):

- `scripts/build-app.sh` Info.plist: add `<key>NSMicrophoneUsageDescription</key><string>desnotch listens while you hold the voice shortcut and turns what you say into a command on this Mac. Audio is never saved or sent anywhere.</string>` and `<key>NSSpeechRecognitionUsageDescription</key><string>desnotch uses on-device speech recognition to turn what you say into text. Nothing is sent to Apple.</string>`; in the hardened-runtime section assert the signed entitlements contain `com.apple.security.device.audio-input` (same style as the existing calendars assertion, with a `fail` message).
- `scripts/desnotch.entitlements`: add `com.apple.security.device.audio-input` = true with a comment like the calendars one (hardened runtime blocks the microphone prompt without it).
- `scripts/smoke-test.sh`: add `PlistBuddy -c "Print :NSMicrophoneUsageDescription"` and `:NSSpeechRecognitionUsageDescription` checks next to the calendar ones, and the hardened-runtime entitlement assertion for `audio-input`.
- `scripts/permission-status.sh`: print `microphone`/`speech`; optional strictness not added.

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
scripts/voice-harness/lint-lite.sh
for f in scripts/build-app.sh scripts/smoke-test.sh scripts/permission-status.sh; do bash -n "$f" && echo "ok $f"; done
plutil -lint scripts/desnotch.entitlements
VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
HARDENED_RUNTIME=1 VERSION=0.0.1 scripts/build-app.sh && scripts/smoke-test.sh dist/desnotch.app
```

(`dist/` is gitignored. The two packaging runs prove the Info.plist keys and the hardened entitlement; each takes a few minutes. If `scripts/smoke-test.sh` needs variables, read its header and use them.)

Done means: build clean; every class above `0 failed`; full suite no failures beyond the two baseline ones; lint clean; the packaged app passes `smoke-test.sh` in both modes; `git status` shows only the files of section 2.

## 5. Manual checklist (report each as DONE / NOT DONE / BLOCKED and what you saw; none can be automated)

Items that launch the packaged app need the installed `/Applications/desnotch.app` to be quit by the human (single-instance guard); never quit or kill it yourself. Items that only use a scratch executable or the unit harness do not.

On the Mac mini (Command Line Tools, no notch, external or built-in microphone):

1. S2: `kEventHotKeyReleased` arrives for ⌥⌘V (result goes in the report).
2. A scratch executable or a temporary test harness that starts `AppleSpeechRecognizer` for `en-US` prints (for your eyes only; REMOVE before finishing) partial/final text for a spoken sentence; `.captureStarted` precedes everything; `.level` arrives at about 15 Hz.
3. Same for `id-ID`: report whether on-device recognition is supported (`supportsOnDeviceRecognition`). If not, the stream must fail with `.unavailable(.recognizer)` and NEVER record to a server.
4. Denied microphone permission yields `.permissionDenied(.microphone)` and no prompt.
5. `cancel()` mid-capture leaves no running engine (the orange mic indicator goes out).
6. `VolumeDucker` and the executor intents against the real volume/media/timer/app launch (Safari, Music).
7. Packaged app: Settings-less check that `Info.plist` has both usage strings and the hardened build carries the audio-input entitlement.

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
