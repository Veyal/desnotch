# WP-UI: the voice section in the notch pill, wings, status menu, Settings and cues

> Self-contained prompt for an external coding agent. You have NOT seen the conversation that produced this plan.
> Implementer: Cursor agent CLI (strong model). Work in your own git worktree; do not commit.

## 1. Background

desnotch is a macOS menu-bar app (SwiftPM, macOS 13+, library target `DesnotchCore`, executable `desnotch`) that draws a
"notch" pill at the top of the screen with sections (now playing, timer, agents, ...). We are adding **voice control**: the
user holds a hotkey, speaks, and either a fixed local command runs (volume, play/pause, open an app, timer) or the request goes
to a cloud agent (Hermes). The whole feature is OFF by default (`SettingsStore.voiceEnabled == false`).

Other work packages are building, in parallel with you: the pure state machine (WP-LOGIC), the microphone/speech/hotkey/
executor/audit code (WP-PLATFORM), and later the coordinator that connects everything and the Hermes link (WP-HERMES). **You build
everything the user sees and touches**, driven only by one presentation object that already exists:
`VoiceSessionModel` in `Sources/DesnotchCore/Voice/Contracts/VoiceSessionModel.swift`. You never talk to the recognizer, the
agent or the audit log. Until WP-HERMES lands, nothing updates the model, so you test with hand-built models.

Before anything else read, completely:

1. `AGENTS.md` (repo root). The sections "Pill visibility", "Notch geometry", "Other pill sections", "Motion vocabulary" and
   "Review-remediation notes" are load-bearing: single hover authority, fixed expanded width, one
   `PillContentSizePreferenceKey`, motion tokens in `UI/PillMotion.swift`, no animation at idle, the status menu as the only
   keyboard path, privacy mode redaction, nothing under 10pt.
2. `docs/voice/PLAN.md` (state machine, tiers, ownership) and `Sources/DesnotchCore/Voice/Contracts/VoiceTypes.swift`
   and `VoiceSessionModel.swift` (the types you render).
3. `Sources/DesnotchCore/UI/NotchPillView+Battery.swift` (smallest section; copy its structure), `NotchPillView.swift`
   (`pillContent`, `reveal`, `PillStructuralAnimationState`, `hasSection`), `PillMotion.swift`, `PillStyle.swift`,
   `PillControls.swift`, `WingIndicator.swift`, `NotchPillView+Compact.swift`, `PillInteractionPolicy.swift`,
   `NotchWindowController.swift` (`updateInteractivity`), `StatusMenuBuilder.swift`, `SettingsView.swift`.

## 2. What you build

### 2.1 The model you bind to (frozen, read-only for you)

```swift
@MainActor public final class VoiceSessionModel: ObservableObject {
    @Published private(set) var state: VoiceState          // idle, armed, listening, transcribing, review, thinking,
                                                           // acting, awaitingApproval, speaking, error, paused
    @Published private(set) var levels: [Float]            // 0...5 bars, 0...1 each, empty unless capturing
    @Published private(set) var partialTranscript: String
    @Published private(set) var finalTranscript: String
    @Published private(set) var reviewDeadline: Date?      // end of the 1.5 s review window
    @Published private(set) var steps: [VoiceStep]         // tool chips (kind is a category word), newest last
    @Published private(set) var stepsStarted: Int
    @Published private(set) var pendingConfirmation: ConfirmationRequest?
    @Published private(set) var lane: VoiceLane?           // .local / .hermes
    @Published private(set) var routeSummary: String?      // desnotch-authored: "Set volume to 30%" or "Send to Hermes (cloud)"
    @Published private(set) var errorText: String?         // generic, secret-free
    @Published private(set) var errorSeverity: VoiceFailure.Severity   // .info / .warning / .alert
    @Published private(set) var reply: String
    @Published private(set) var interruptListening: Bool   // stop-only capture while an agent runs
    @Published private(set) var survivors: [String]        // process names still alive after a hard stop
    @Published private(set) var permissions: VoicePermissionStatus
    @Published private(set) var hermesLaneStatus: HermesLaneStatus
    @Published private(set) var hotkeyStatus: PushToTalkStatus   // .unavailable when another app owns the shortcut
    var isActive: Bool, isPaused: Bool, usesCloud: Bool, isCapturing: Bool   // derived
    func stopAll(); func resume(); func approve(nonce: String); func deny(nonce: String)
    func cancelReview(); func toggleTalk(); func submitTyped(_ text: String); func requestPermissions()
    // writers (coordinator/tests/previews): apply(_:reviewDeadline:), setLevels, setPermissions,
    // setHermesLaneStatus, setHotkeyStatus, setSurvivors
}
```

`NotchWindowController` and `NotchPillView` already receive the model (`voice`); the base commit plumbed it through, and
`AppComposition` owns it as `voiceModel`. You use `model.apply(context, reviewDeadline:)` in tests to put it in a state.

### 2.2 Files

You own exactly these files. Anything not listed is off limits.

**New** (under `Sources/DesnotchCore/UI/` unless noted):

| File | Purpose |
|---|---|
| `VoiceSectionPresentation.swift` | pure value: given a snapshot of the model + privacy flag, the title, lines, glyph names, button set, tint, a11y label. All copy lives here so it is unit-testable. |
| `VoiceSectionView.swift` | the SwiftUI section (`@MainActor struct`), renders a `VoiceSectionPresentation`. Includes `VoiceMeter` (5 bars) and `VoiceApproveButton` (hold-to-approve). |
| `NotchPillView+Voice.swift` | `extension NotchPillView`: `voiceSection`, wing glyph view, `hasVoice`, the haptic/announcement observers. |
| `VoiceCuePlayer.swift` | `@MainActor final class VoiceCuePlayer: VoiceCuePlaying` (earcon + haptic per cue). |
| `VoiceSettingsSection.swift` | `@MainActor struct VoiceSettingsSection: View` used by `SettingsView`. |

**Changed (existing files)**: `UI/PillMotion.swift`, `UI/NotchPillPresentation.swift`, `UI/WingIndicator.swift`,
`UI/PillInteractionPolicy.swift`, `UI/NotchPillView.swift`, `UI/NotchPillView+Compact.swift`, `UI/NotchPillView+Shared.swift`,
`UI/PillStackBudget.swift`, `UI/PillHaptics.swift`, `UI/NotchWindowController.swift`, `Support/AccessibilityAnnouncer.swift`
(add `PillAnnouncements` strings), `App/StatusMenuBuilder.swift`, `App/StatusMenuBuilder+Actions.swift`,
`App/StatusMenuText.swift`, `App/SettingsView.swift`, `App/WindowCoordinator.swift` (pass the model into `SettingsView`).

**Tests** (new, under `Tests/DesnotchCoreTests/Voice/UI/`): `VoiceSectionPresentationTests.swift`, `VoiceSectionRenderTests.swift`,
`VoiceWingSelectionTests.swift`, `VoiceHoverPolicyTests.swift`, `VoiceStatusMenuTextTests.swift`, `VoiceCuePlayerTests.swift`,
`VoiceAccessibilityTextTests.swift`. **Existing tests you must update because your API changes break them** (you own these
files and may edit only what the change requires): `PillInteractionPolicyTests.swift`, `PillSectionMotionTests.swift`,
`WingMetricsTests.swift`, `PillStackBudgetTests.swift`, `NotchPillPresentationTests.swift`, and any other existing test file that
fails to compile because of a UI-owned signature you changed.

### 2.3 Behavior of each state (the section content)

The section is `PillSectionKind.voice`, **rank 0** (above `notification`), shown whenever `model.state != .idle`. It follows the
`reveal(_:)` choreography like every other section (add the kind to `PillSectionKind` and `order`, renumber to 0...11, to
`hasSection`, to the staged mount, and to `PillStructuralAnimationState` as `hasVoice`). It has a fixed width (the pill's) and
never scrolls. It is always built from a `VoiceSectionPresentation`.

Colors and type come from the existing tokens (`PillTextStyle`, `PillSpace`, `PillRowHeight`, `PillRowLeading`, `PillPalette`,
`PillSurface.highlight`, `PillFocusRing`); nothing under 10pt; all motion from `motion.*` tokens; no `repeatForever`, no
`.onHover`, no animation while the state is unchanged.

| State | Left wing | Right wing | Body (all text through `privacyRedacted`) |
|---|---|---|---|
| `armed` | `mic.fill` glyph, dimmed | - | "Starting…" |
| `listening` | `mic.fill`, white | 5-bar `VoiceMeter` driven by `model.levels` | partial transcript, max 2 lines (truncate with `…`), or "Listening…" while empty; a caption "Esc cancels" |
| `transcribing` | `ellipsis` glyph | - | "Transcribing…" |
| `review` | `checkmark.circle` glyph | - | "Heard: <final transcript, 2 lines max>" and a second line `routeSummary` (e.g. "Set volume to 30%"); a determinate thin countdown bar from `reviewDeadline` (finite, derived from the time, no looping); a "Cancel" icon button |
| `thinking` | `ellipsis` glyph | - | "Thinking…" with the cloud badge |
| `acting` | gear/tool glyph | - | local: `routeSummary`; agent: up to 3 chips from `steps` (`VoiceLimits.visibleStepChips`), "+N" when more, using `PillChip` |
| `awaitingApproval` | amber `bolt.fill` | amber dot | the approval card (below) |
| `speaking` | `speaker.wave.2.fill` | - | `reply`, max 3 lines; nothing to speak means the reply is just shown |
| `error` | `exclamationmark.triangle.fill` (amber for `.warning`/`.info`, red for `.alert`) | - | `errorText` (not redacted: it is generic) and, for `.info` severity, calm styling with no rim |
| `paused` | red `pause.fill` | - | "Agent stopped" + (if `survivors` is not empty) "N still running: name, name" (names are process basenames, redact in privacy mode) + a "Resume" button |

Rules for all states:

- **Stop-only capture**: while `model.interruptListening` is true (an agent is busy and the user is holding the key), add a line "Say “abort agent” to stop" with the `mic.fill` glyph and the meter to the busy state's body. It never replaces the busy content.

- **Cloud badge**: whenever `model.usesCloud`, show a small "cloud" glyph + "Hermes" next to the title. In `review` with a remote route it reads
  "Sending to Hermes (cloud)" because `routeSummary` says so.
- **Stop button**: an icon button (`stop.fill`), visible in every state except `idle`, calls `model.stopAll()`. In `listening`, `review` and `awaitingApproval`
  there is also a Cancel/Deny affordance as specified in the table/card. All controls use `PillButtonStyle` and `pillFocusRing`.
- **Privacy mode** (`SettingsStore.shared.privacyModeEnabled`): partial/final transcript, reply and the approval literal are replaced via
  `privacyRedacted(_:fallback:)` with fallbacks "Voice command", "Reply", "Command". The state words ("Listening…") and `routeSummary` for local intents are generic and stay;
  a remote `routeSummary` stays. `survivors` names are redacted.
- **Reduce Motion / Minimal**: the meter shows a static bar set (no per-bar animation), state changes are opacity-only (existing token behavior).
  The meter updates at most at the rate `levels` arrives (the coordinator throttles to 15 Hz); animate bar height with `motion.direct` only when `motion.allowsGeometry`.
- **The approval card** (`awaitingApproval`, `pendingConfirmation != nil`): tier chip (`request.tier.label`, plus risk-flag words such as "network", "pipe",
  "chained" derived from `request.risk`), the `summary` line, and the `literal` in a monospaced block of at most **6 lines / 240 characters**
  (`VoiceCardLayout.maxVisibleCharacters = 240`, define it in `VoiceSectionPresentation.swift`). The pill never scrolls (scroll adjusts volume), so if
  `literal.count > 240` the card shows the first 240 characters + "…", shows the line "Too long to review here", and **Approve is disabled**. Approve is also disabled when
  `!request.canApprove` (truncated by the scanner, auto-deny flags, tier T3). Buttons: **Deny** (click) and **Approve**. For a card with `source == .hermes`, Approve is
  **hold-to-approve** (600 ms ring fill on `motion.direct`; releasing early cancels; a plain click does nothing). For `source == .local` (volume above 70%), Approve is a click.
  Both call `model.approve(nonce: request.nonce)` / `model.deny(nonce: request.nonce)` with the nonce of the card that is on screen, captured at render time.
  The ripple (`PillRipple`) plays `attentionPulseCount` times (0 under Reduce Motion), then the amber tint stays static.
- **No voice anywhere approves.** There is no "say yes" copy or affordance.

### 2.4 Wings

Add `WingIndicator.voice` and `WingInputs.voiceState: VoiceState?` (nil when idle). Extend `WingSelection.select` (pure; keep it a pure function) so that:

| `voiceState` | left wing | right wing |
|---|---|---|
| `nil` | unchanged | unchanged |
| `armed`, `transcribing`, `review`, `thinking`, `acting`, `speaking`, `error`, `paused` | `.voice` | unchanged |
| `listening`, `awaitingApproval` | `.voice` | `.voice` |

`.voice` outranks every other left-wing indicator including `.volume`; on the right it outranks `.volume` only in `listening`/`awaitingApproval`. The wing indicator is
glyph-only: `WingMetrics.contentWidth(of: .voice) == 16`, `inset(of: .voice) == persistentInset`, so `extraWidth` stays 0. Left glyph by state as in the table; right wing shows the
`VoiceMeter` (listening) or the amber dot (awaitingApproval). `compactAccessibilityLabel` gains "Voice: <state word>" (never a transcript).

### 2.5 Hover and pill behavior

`PillInteractionPolicy.wantsHover(cursorInside:pinnedOpen:voiceActive:)`: add the third parameter (**required, no default**), `= cursorInside || pinnedOpen || voiceActive`.
Update every call site and test. `NotchWindowController` stores `isVoiceActive`, subscribes to `voice.$state` (Combine, `[weak self]`, main actor) and calls the existing
`updateInteractivity()` when `voice.isActive` changes. This is an extra INPUT to the one hover decision, not a second hover source. `acceptsMouse` is unchanged (the panel still
takes mouse events only while the cursor is over the pill).
Add `PillFlashKind.voice` (hold 3.0 s, spotlight `.voice`, rim `.cyan` at 0.5) and have `NotchWindowController` call `presentation.flashOpen(kind: .voice)` when the state enters
`.error` or `.speaking` (so the result is visible even if the user moved the pointer away). Keep it generation-safe: call it only on a real state change.

### 2.6 Cues and announcements

`VoiceCuePlayer` implements `VoiceCuePlaying.play(_:)`:

| Cue | Sound (`NSSound(named:)`) | Haptic (`PillHaptics.Event`, new cases) |
|---|---|---|
| `captureStart` | `Tink` | `voiceStart` (.alignment) |
| `captureEnd` | `Pop` | none |
| `commit` | none | `voiceCommit` (.generic) |
| `needsConfirmation` | `Ping` | `voiceNeedsConfirm` (.levelChange) |
| `approved` | `Pop` | `voiceApproved` (.levelChange) |
| `done` | none | `voiceCommit` |
| `error` | `Basso` | `voiceError` (.levelChange, tapCount 2) |

Inject the sound and haptic closures (`init(playSound: @escaping (String) -> Void, haptic: @escaping (PillHaptics.Event) -> Void)`) so the mapping is unit-testable; the convenience
`init()` uses `NSSound` and `PillHaptics`. A sound that does not exist falls back to `NSSound.beep()` only for `error`; otherwise silent.
VoiceOver: add `PillAnnouncements.voiceNeedsApproval = "Voice command needs approval"`, `voiceFailed = "Voice command failed"`, `voiceStopped = "Voice agent stopped"`.
`NotchPillView+Voice.swift` observes `voice.state` and announces ONLY on entering `awaitingApproval` (priority `.high`), `error` with severity `.warning`/`.alert`, and `paused`. Never announce listening,
transcripts, replies or command text, and never announce on `armed` (the mic would capture it).

### 2.7 Status menu (the keyboard / VoiceOver path)

The pill is non-activating and never key, so every voice action must be mirrored in `StatusMenuBuilder` (rebuilt on every open). Only when `SettingsStore.shared.voiceEnabled`
(otherwise add nothing):

- A disabled info item "Voice: <state title>" (`Idle`, `Listening`, ... generic words only; from a pure function in `StatusMenuText.swift`).
- "Talk" (toggle) -> `voice.toggleTalk()` while `idle`, `speaking`, `error`, `listening`; title "Stop Listening" while `listening`.
- While `awaitingApproval`: "Approve: <summary>" and "Deny", each bound to the nonce rendered at menu build time via `representedObject` (see AGENTS.md "Notification menu actions bind the app name they rendered"); the
  handler re-checks that the nonce still equals `voice.pendingConfirmation?.nonce` before calling `approve`/`deny`; Approve is disabled when `!canApprove`; the summary is `request.summary` (desnotch-authored for local;
  for agent cards use the generic title "Approve agent action" and NEVER the literal, since menus may be screen-shared).
- While `review` or `listening`: "Cancel" -> `voice.cancelReview()`.
- While `state != .idle && state != .paused`: "Stop Voice Agent" -> `voice.stopAll()`.
- While `paused`: "Resume Voice" -> `voice.resume()`.
- Only when env `DESNOTCH_VOICE_DEBUG == "1"`: "Type a Voice Command…" which opens a small `NSAlert` with a text field and calls `voice.submitTyped(text)` (empty text does nothing).

### 2.8 Settings

`VoiceSettingsSection` (added to `SettingsView.content` after the notification section) shows:

- Toggle "Voice control" bound to `settings.voiceEnabled`, with a `SettingsNote`: "Off by default. Hold the shortcut to speak. Uses the microphone and on-device speech recognition; audio is never saved."
- When on: two permission rows (Microphone, Speech Recognition) from `model.permissions` ("Allowed" / "Not allowed" / "Not asked yet"), a "Allow Access…" button -> `model.requestPermissions()`, and a link to System Settings (Privacy & Security) when denied.
- Picker "Language" over `SettingsStore.supportedVoiceLocales` ("English (US)", "Bahasa Indonesia"), Picker "Shortcut" over `VoiceHotkeyChoice` ("⌥⌘V", "⇧⌥⌘V", "⌥⌘J") with a warning-colored note "Another app uses this shortcut" when `model.hotkeyStatus == .unavailable` (only while voice is enabled), Toggle "Speak replies" (`voiceTTSEnabled`, note: "Silent in Privacy mode"), Toggle "Lower other audio while listening" (`voiceDuckMedia`).
- Toggle "Send other requests to the Hermes agent (cloud)" bound to `voiceHermesLane`, with a note in the warning color: "Anything that is not a built-in command is sent to the cloud-routed Hermes agent. Requires the locked 'voice' Hermes profile." and the status line from `model.hermesLaneStatus` ("Off", "Checking…", "Ready", "Refused: <reason word>").
- Use `SettingsHeader`/`SettingsNote` like the rest of the file. Settings are NOT exported (do not touch `SettingsTransfer`).

## 3. Tests to write (named; each is a test method)

- `VoiceSectionPresentationTests`: one test per state (`testListeningShowsPartialAndMeter`, `testReviewShowsHeardAndRouteSummary`, `testAwaitingApprovalCardDisablesApproveWhenLiteralTooLong`, `testHermesCardRequiresHold`, `testLocalCardApprovesWithClick`,
  `testTruncatedRequestCannotBeApproved`, `testTier3RequestCannotBeApproved`, `testPausedShowsSurvivorsAndResume`, `testErrorSeverityStyling`, `testCloudBadgeWhenLaneIsHermes`, ...). Plus `testPrivacyModeRedactsTranscriptReplyAndLiteral` (assert none of the secret strings appear anywhere in the presentation), `testNoPresentationOffersASpokenApproval`.
- `VoiceSectionRenderTests`: render `VoiceSectionView` for every `VoiceState` (use `NSHostingView` offscreen like `ArtworkGlowRenderTests`; assert a non-zero fitting size, width == the pill width you pass, height <= 240) with representative models. Follow the existing render-test pattern; use `drainMainQueue()`.
- `VoiceWingSelectionTests`: the table in 2.4 (every row, both wings), plus "voice beats volume on the left", plus an unchanged-behavior test with `voiceState == nil` for three of the existing combinations, plus `WingMetrics` width/inset/extraWidth for `.voice`.
- `VoiceHoverPolicyTests`: the full truth table of `wantsHover` (8 rows) and `acceptsMouse` unchanged.
- `VoiceStatusMenuTextTests`: for each state the list of item titles/enabled flags that `StatusMenuText` returns (make the menu composition a pure function returning `[VoiceMenuItemSpec]`, then the builder maps specs to `NSMenuItem`s).
- `VoiceCuePlayerTests`: the mapping table above with fake closures; `error` fallback beep.
- `VoiceAccessibilityTextTests`: `compactAccessibilityLabel` and announcements never contain transcript/reply/literal text.
- Update `PillSectionMotionTests` (12 kinds, `.voice` order 0, others +1), `PillInteractionPolicyTests`, `WingMetricsTests`, `PillStackBudgetTests` (voice height estimate is included in the stack; row caps still fit), `NotchPillPresentationTests` (`PillFlashKind.voice`).
- `PillSourceGuardTests` (existing, in `PillPolishTests.swift`) must keep passing: no `.onHover`, no `repeatForever`, in any `UI/` file.

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

Run these and report their last lines:

```sh
swift build 2>&1 | grep -E "warning:|error:|Build complete"
scripts/voice-harness/run.sh --filter Voice
scripts/voice-harness/run.sh --filter Pill
scripts/voice-harness/run.sh --filter Wing
scripts/voice-harness/run.sh
scripts/voice-harness/lint-lite.sh
```

Done means: build clean; the full suite has no failures beyond the two documented baseline ones; every class in section 3 exists and passes; lint clean; `git status` shows changes only in the files of 2.2.

Visual check: the app cannot be driven by the mic yet. If you have a display, you MAY add a temporary local-only preview in a render test that writes PNGs to `NSTemporaryDirectory()` for the 11 states and look at them; do not commit
the PNGs or any preview code. Describe in your report what you looked at. Final on-screen review happens after WP-HERMES lands (typed debug command).

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

Additional UI rules: tokens only (no raw durations/curves/fonts in views), minimum 10pt, 8pt grid spacing from `PillSpace`, WCAG AA contrast through `PillPalette`, every interactive element has a VoiceOver label and `pillFocusRing`,
Reduce Motion / Reduce Transparency / Increase Contrast honored through the existing environment values, no new `PreferenceKey`, no second size callback, no broad `.animation` on a root view.

## 6. DO NOT

- Do NOT use `.onHover` or `repeatForever` anywhere (CI test `PillSourceGuardTests` fails). Do NOT add a second hover source.
- Do NOT make the panel key window, and do NOT add anything that takes keyboard focus from the frontmost app.
- Do NOT edit any `Voice/Contracts/*` file, `SettingsStore.swift`, `SettingsTransfer.swift`, `AppComposition.swift`, `AppDelegate.swift`, `Package.swift`, scripts, `AGENTS.md`, or anything under `Voice/Logic`, `Voice/Platform`, `Voice/Hermes`, `Voice/Coordinator`.
- Do NOT call the recognizer, agent, audit log or any executor. Do NOT import `Speech`, `AVFoundation` (except what `NSSound` needs from AppKit).
- Do NOT show or announce a transcript, reply, command text or file path outside `privacyRedacted`; do NOT put them in the status menu.
- Do NOT add spoken/typed approval ("say yes"). Do NOT add "always allow" or "allow for session" anywhere.
- Do NOT add a setting, a defaults key or a settings-export field (the contract already has all of them).
- Do NOT run `git add/commit/push/...`.
