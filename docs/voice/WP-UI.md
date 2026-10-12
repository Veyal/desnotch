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
| `VoiceSectionPresentation.swift` | pure values: `VoiceSectionSnapshot`, `VoiceSectionPresentation` (title, lines, glyph names, button set, tint, a11y label), `VoiceCardLayout`, `VoiceStateWords`, `VoiceRiskWords`. All copy lives here so it is unit-testable (signatures in 2.3). |
| `VoiceSectionView.swift` | the SwiftUI section (`@MainActor struct`), renders a `VoiceSectionPresentation`. Includes `VoiceMeter` (5 bars), `VoiceApproveButton` (hold-to-approve) and `VoiceSectionHost` (the only view that observes the model). |
| `NotchPillView+Voice.swift` | `extension NotchPillView`: `voiceSection`, `hasVoice`, the wing glyph view, `static func voiceCompactLabel(_:)`, and the VoiceOver announcement observers. **No haptics here**: haptics belong to `VoiceCuePlayer`, which the coordinator calls; calling `PillHaptics` from the view would double-fire. |
| `VoiceCuePlayer.swift` | `@MainActor final class VoiceCuePlayer: VoiceCuePlaying` (earcon + haptic per cue). |
| `VoiceSettingsSection.swift` | `@MainActor struct VoiceSettingsSection: View` used by `SettingsView`. |

**Changed (existing files)**: `UI/PillMotion.swift`, `UI/NotchPillPresentation.swift`, `UI/WingIndicator.swift`,
`UI/PillInteractionPolicy.swift`, `UI/NotchPillView.swift`, `UI/NotchPillView+Compact.swift`, `UI/NotchPillView+Shared.swift`,
`UI/PillStackBudget.swift`, `UI/PillHaptics.swift`, `UI/NotchWindowController.swift`, `Support/AccessibilityAnnouncer.swift`
(add `PillAnnouncements` strings), `App/StatusMenuBuilder.swift`, `App/StatusMenuBuilder+Actions.swift`,
`App/StatusMenuText.swift`, `App/SettingsView.swift`, `App/WindowCoordinator.swift` (pass the model into `SettingsView`).

**Tests** (new, under `Tests/DesnotchCoreTests/Voice/UI/`): `VoiceSectionPresentationTests.swift`, `VoiceSectionRenderTests.swift`,
`VoiceWingSelectionTests.swift`, `VoiceHoverPolicyTests.swift`, `VoiceStatusMenuTextTests.swift`, `VoiceCuePlayerTests.swift`,
`VoiceAccessibilityTextTests.swift`. **Existing tests you must update because your API changes break them** (you own exactly these
five files and may edit only what the change requires): `PillInteractionPolicyTests.swift`, `PillSectionMotionTests.swift`,
`WingMetricsTests.swift`, `PillStackBudgetTests.swift`, `NotchPillPresentationTests.swift`. Do NOT edit `PillMotionTests.swift` (it
is not yours; it passes unchanged because `voice` is declared first, see 2.3). Any OTHER existing test that breaks is not in
`ownership.tsv`, so `check-ownership.sh WP-UI` would reject the edit: do not edit it, report `AMENDMENT REQUEST: <file>` instead (the plan
owner checked that `PillMotionTests` and `NowPlayingMotionTests` only iterate `allCases` and existing cases, so none is expected).

Test helpers: `Tests/DesnotchCoreTests/Voice/VoiceTestSupport.swift` (frozen) has `FakeVoiceClock`, `ScriptedRecognizer`,
`RecordingExecutor`, `ScriptedBackend`, `InMemoryFileWriter`; UI tests rarely need them. They build a `VoiceSessionModel` and call
`model.apply(context, reviewDeadline:)`. **Writer-order trap:** `apply` clears `levels` outside `armed`/`listening` (unless
`interruptListening`) and `survivors` outside `paused`, so call `setLevels(...)` and `setSurvivors(...)` AFTER `apply`.

### 2.3 Behavior of each state (the section content)

**Position and kind.** The section is `PillSectionKind.voice`, rank 0 (above `notification`), shown whenever the voice state is not
`idle`. In `enum PillSectionKind` (PillMotion.swift) declare `case voice` FIRST, before `notification`, and give it `order` 0; every other
kind's `order` shifts by one (notification 1 ... tray 11). `PillMotionTests.testNaturalRankFollowsStackOrder` and
`testSectionOrderIsTheStackPosition` require `allCases` index == `order` for every case; declaring `voice` first keeps them true.
In `PillSectionMotionTests.swift` add `testVoiceIsFirstAndEveryOtherKindShiftsByOne` (`allCases.count == 12`, `voice.order == 0`,
`notification.order == 1`, ... `tray.order == 11`). Also add `.voice` to `hasSection`, to the staged mount, and to the
`PillFlashKind` switches (`holdDuration` 3.0, `spotlight` `.voice`, `rim` `(.cyan, 0.5)`); the existing `PillFlashKind` tests tolerate it.
The section has the pill's fixed width and never scrolls, and is always built from a `VoiceSectionPresentation`.

**Observation (performance).** `NotchPillView` must NOT observe the whole model: today it has `@ObservedObject public var voice`, and
every `levels` publish (15 Hz while listening) or partial transcript would re-evaluate the whole 12-section pill body. Change it to
`public let voice: VoiceSessionModel` plus `@State private var voiceState: VoiceState` (initialised from `voice.state` in `init` via
`_voiceState = State(initialValue: voice.state)`), updated by `.onReceive(voice.$state.removeDuplicates()) { voiceState = $0 }` on the root view.
`hasVoice` is `voiceState != .idle`; the wings and the structural animation use `voiceState`. The section itself is a
`VoiceSectionHost` (`@MainActor struct`, `@ObservedObject var model: VoiceSessionModel`) that builds the snapshot and renders it; only
that host re-evaluates at 15 Hz while listening (accepted cost, nothing runs at idle).

**Presentation API (exact names; all pure, in `VoiceSectionPresentation.swift`):**

```swift
struct VoiceSectionSnapshot: Equatable {
    var state: VoiceState
    var partialTranscript: String, finalTranscript: String, reply: String
    var reviewDeadline: Date?
    var steps: [VoiceStep], stepsStarted: Int
    var pending: ConfirmationRequest?
    var routeSummary: String?, errorText: String?
    var errorSeverity: VoiceFailure.Severity
    var lane: VoiceLane?, usesCloud: Bool
    var interruptListening: Bool
    var survivors: [String]
    @MainActor init(model: VoiceSessionModel)     // copies the fields above
}
struct VoiceSectionPresentation: Equatable {
    init(_ snapshot: VoiceSectionSnapshot, privacyMode: Bool, now: Date)
    // title, bodyLines, leftGlyph, rightGlyph, tint, chips, buttons: [VoiceButtonSpec], card: VoiceCardPresentation?, accessibilityLabel
}
enum VoiceCardLayout {
    static let maxVisibleCharacters = 240
    static let maxVisibleLines = 6                 // hard newlines
    static let sectionHeightBudget: CGFloat = 112  // every state except awaitingApproval
    static let approvalHeightBudget: CGFloat = 260 // awaitingApproval (the literal is never clipped, see below)
    static func isLiteralReviewable(_ literal: String) -> Bool   // count <= 240 && hard-newline lines <= 6
}
```

The views call `VoiceSectionPresentation` only; they never read the model fields directly. `VoiceSectionView(presentation:levels:width:motion:contrast:reduceTransparency:actions:)`
takes `motion: NotchAnimation.Motion`, `contrast: ColorSchemeContrast`, `reduceTransparency: Bool` (the values `NotchPillView` already has) and an
`actions: VoiceSectionActions` struct of closures (`stop`, `resume`, `cancel`, `approve(nonce)`, `deny(nonce)`), wired to the model's `stopAll`/`resume`/`cancelReview`/`approve`/`deny` by `VoiceSectionHost`.

Colors and type come from the existing tokens (`PillTextStyle`, `PillSpace`, `PillRowHeight`, `PillRowLeading`, `PillPalette`,
`PillSurface.highlight`, `PillFocusRing`); nothing under 10pt; all motion from `motion.*` tokens (the only exception is the countdown bar below);
no `repeatForever`, no `.onHover`, no animation while the state is unchanged. `.onChange(of:)` must use the single-parameter macOS 13 form, like the existing code.

| State | Left wing | Right wing | Body (all text through `privacyRedacted`) |
|---|---|---|---|
| `armed` | `mic.fill` glyph, dimmed | - | "Starting…" |
| `listening` | `mic.fill`, white | 5-bar `VoiceMeter` driven by `model.levels` | partial transcript, max 2 lines (truncate with `…`), or "Listening…" while empty; a caption "Esc cancels". Buttons: Stop only (no Cancel button; Esc cancels) |
| `transcribing` | `ellipsis` glyph | - | "Transcribing…" |
| `review` | `checkmark.circle` glyph | - | "Heard: <final transcript, 2 lines max>" and a second line `routeSummary` verbatim (e.g. "Set volume to 30%", "Send to Hermes (cloud)"); a determinate thin countdown bar from `reviewDeadline`; a "Cancel" icon button |
| `thinking` | `ellipsis` glyph | - | "Thinking…" with the cloud badge |
| `acting` | `gearshape.fill` | - | local: `routeSummary`; agent: up to 3 chips from `steps` (`VoiceLimits.visibleStepChips`), "+N" when more, using `PillChip` |
| `awaitingApproval` | amber `bolt.fill` | amber dot | the approval card (below) |
| `speaking` | `speaker.wave.2.fill` | - | `reply`, max 3 lines; nothing to speak means the reply is just shown |
| `error` | `exclamationmark.triangle.fill` (amber for `.warning`/`.info`, red for `.alert`) | - | `errorText` (not redacted: it is generic) and, for `.info` severity, calm styling with no rim |
| `paused` | red `pause.fill` | - | "Agent stopped" + (if `survivors` is not empty) "N still running: name, name" (names are process basenames, redact in privacy mode) + a "Resume" button (no Stop button: `stopAll` is a no-op while paused, R03) |

Rules for all states:

- **Stop-only capture**: while `model.interruptListening` is true (an agent is busy and the user is holding the key), add a line "Say “abort agent” to stop" with the `mic.fill` glyph and the meter to the busy state's body. It never replaces the busy content.
- **Cloud badge**: whenever `model.usesCloud`, show a small "cloud" glyph + "Hermes" next to the title. In `review` with a remote route the second line is `routeSummary` verbatim, "Send to Hermes (cloud)" (no extra word added).
- **Stop button**: an icon button (`stop.fill`), visible in every state except `idle` and `paused`, calls `model.stopAll()`. The only other affordances are the ones in the table (Cancel in `review`, Deny/Approve in the card, Resume in `paused`); `listening` has no Cancel button. All controls use `PillButtonStyle` and `pillFocusRing`.
- **Privacy mode** (`SettingsStore.shared.privacyModeEnabled`): partial/final transcript, reply and the approval literal are replaced via
  `privacyRedacted(_:fallback:)` with fallbacks "Voice command", "Reply", "Command". For a card with `source == .hermes` the `summary` is model-authored, so it is redacted too (fallback "Agent action"); a `.local` card's `summary` is desnotch-authored and stays. The state words ("Listening…") and `routeSummary` stay (generic; a remote `routeSummary` is fixed text). `survivors` names are redacted.
- **Reduce Motion / Minimal**: the meter shows a static bar set (no per-bar animation), state changes are opacity-only (existing token behavior).
  The meter updates at most at the rate `levels` arrives (the coordinator throttles to 15 Hz); animate bar height with `motion.direct` only when `motion.allowsGeometry`.
- **Countdown bar (review)**: the one place a raw duration is allowed, because the bar is determinate: when `motion.allowsGeometry`, animate its width from the
  current remaining fraction to 0 with `.linear(duration: remaining)` (the pattern `PillMarquee`/`PillControls` use for finite progress); under Reduce Motion / Minimal it is a static bar showing the remaining fraction at render time. No looping.
- **Risk-flag chip words** (`VoiceRiskWords.word(for:)`, shown on the card in this order, at most 4, then "+N"): `.url` "network", `.pipe` "pipe", `.chaining` "chained", `.redirect` "redirect",
  `.destructive` "destructive", `.sudo` "sudo", `.protectedPath` "protected path", `.pipeToInterpreter` "pipe to shell", `.base64Decode` "base64", `.evalUse` "eval",
  `.commandSubstitution` "substitution", `.hiddenCharacters` "hidden characters", `.unscanned` "unscanned".
- **The approval card** (`awaitingApproval`, `pendingConfirmation != nil`): tier chip (`request.tier.label` plus the risk-flag words above), the `summary` line, and the `literal` in a monospaced block.
  **The literal is never clipped**: render it with NO `lineLimit` and `.fixedSize(horizontal: false, vertical: true)` (10pt monospaced at the pill's content width needs 6 lines for 240 characters at the default width, and 7 at the supported minimum
  width, so a `lineLimit(6)` would silently hide text that Approve covers). Approve is enabled only when the whole literal is on screen and reviewable:
  `request.canApprove && VoiceCardLayout.isLiteralReviewable(request.literal)` (`literal.count <= 240` and at most 6 hard-newline lines). Otherwise the card shows the first 240 characters (and at most the first 6 lines) + "…", shows the line "Too long to review here", and **Approve is disabled**.
  Approve is also disabled when `!request.canApprove` (truncated by the scanner, auto-deny flags, tier T3). Buttons: **Deny** (click) and **Approve**. For a card with `source == .hermes`, Approve is
  **hold-to-approve** (600 ms ring fill on `motion.direct`; releasing early cancels; a plain click does nothing). For `source == .local` (volume above 70%), Approve is a click.
  Both call `model.approve(nonce: request.nonce)` / `model.deny(nonce: request.nonce)` with the nonce of the card that is on screen, captured at render time.
  The ripple (`PillRipple`) plays `attentionPulseCount` times (0 under Reduce Motion), then the amber tint stays static.
  Height: the approval state has its own budget, `VoiceCardLayout.approvalHeightBudget = 260`; every other state must fit `sectionHeightBudget = 112`. These two numbers are the ones `PillStackEstimate` uses (2.3.1) and the render tests assert.
- **No voice anywhere approves.** There is no "say yes" copy or affordance.

#### 2.3.1 Pill-stack integration (exact)

`NotchPillView.swift`, `pillContent`: the voice block is the FIRST child of the `VStack`, above the existing `if hasNotification, let banner = ...` block (which stays byte-for-byte, because `PillSourceGuardTests.testNotificationDividerIgnoresTheTrayAndPrivacyRows` text-matches the span from `reveal(.notification)` to `revealDivider(.media)`, requires `hasMiddleSection` inside it and no `trayEnabled`):

```swift
if hasVoice {
    reveal(.voice) { voiceSection }
    // Only content that renders between the voice section and the privacy row needs this rule. When the voice
    // section is the only content, `hasContentBeforePrivacyAction` draws the single divider before the privacy row.
    if hasNotification || hasMiddleSection {
        revealDivider(.notification)
    }
}
```

`NotchPillView+Shared.swift`: `hasContentBeforePrivacyAction` becomes `hasVoice || hasNotification || hasMiddleSection`. The "previous content" chains of the later sections (`hasMedia || hasTimer || ...`) do not mention the notification today, and must not mention voice either: the voice block and the notification block own their own dividers. Add `let hasVoice: Bool` to `PillStructuralAnimationState` (and set it where the state is built).

`PillStackBudget.swift`: `PillStackEstimate` gains, AFTER the existing stored properties and WITH defaults (the budget tests build it with labelled memberwise arguments and must keep compiling): `var hasVoice = false`, `var voiceState: VoiceState? = nil`, `static let voiceHeight = VoiceCardLayout.sectionHeightBudget` (112) and `static let voiceApprovalHeight = VoiceCardLayout.approvalHeightBudget` (260). In `height(caps:)` insert FIRST in `sections`: `if hasVoice { sections.insert(voiceState == .awaitingApproval ? Self.voiceApprovalHeight : Self.voiceHeight, at: 0) }`. `stackEstimate` (in `+Shared`) sets `hasVoice: hasVoice, voiceState: voiceState`. `PillStackBudgetTests` adds "voice height estimate included" (idle estimate unchanged; `hasVoice` adds 112 plus one divider; `.awaitingApproval` adds 260 plus one divider).

### 2.4 Wings

Add `WingIndicator.voice` and `WingInputs.voiceState: VoiceState?` (nil when idle; it defaults to nil). Extend `WingSelection.select` (pure; keep it a pure function) so that:

| `voiceState` | left wing | right wing |
|---|---|---|
| `nil` | unchanged | unchanged |
| `armed`, `transcribing`, `review`, `thinking`, `acting`, `speaking`, `error`, `paused` | `.voice` | unchanged |
| `listening`, `awaitingApproval` | `.voice` | `.voice` |

`.voice` outranks every other left-wing indicator including `.volume`; on the right it outranks `.volume` only in `listening`/`awaitingApproval`. The wing indicator is
glyph-only: `WingMetrics.contentWidth(of: .voice) == 16`, `inset(of: .voice) == persistentInset`, so `extraWidth` stays 0. Left glyph by state as in the table; right wing shows the
`VoiceMeter` (listening) or the amber dot (awaitingApproval). Note for reviewers: while voice is active the pill is held open (2.5), so the collapsed wings show only during the exit grace period; the wing code is still specified and tested as a pure function.

**Accessibility text (pure).** Provide `static func voiceCompactLabel(_ state: VoiceState?) -> String?` (in `NotchPillView+Voice.swift`; returns nil for nil/idle, else "Voice: <word>") and use it in
`compactAccessibilityLabel`. One word table (`VoiceStateWords` in `VoiceSectionPresentation.swift`) feeds the label, the status menu and the tests; it never contains transcript, reply or literal text:

| State | Wing / accessibility word | Status-menu title |
|---|---|---|
| `idle` | (none) | Idle |
| `armed` | starting | Starting |
| `listening` | listening | Listening |
| `transcribing` | transcribing | Transcribing |
| `review` | confirming | Confirming |
| `thinking` | thinking | Thinking |
| `acting` | working | Working |
| `awaitingApproval` | needs approval | Needs Approval |
| `speaking` | speaking | Speaking |
| `error` | error | Error |
| `paused` | stopped | Stopped |

### 2.5 Hover and pill behavior

`PillInteractionPolicy.wantsHover(cursorInside:pinnedOpen:voiceActive:)`: add the third parameter (**required, no default**), `= cursorInside || pinnedOpen || voiceActive`.
Update every call site and test. This is an extra INPUT to the one hover decision, not a second hover source; `acceptsMouse` is unchanged (the panel still takes mouse events only while the cursor is over the pill).

`NotchWindowController` (not `@MainActor`; `voice` and `presentation` are) stores `private var isVoiceActive = false` and `private var voiceObserver: AnyCancellable?`, and uses `isVoiceActive` in `updateInteractivity()`. Exact subscription, in `init` after the existing observers (follow `displaySettingObserver`):

```swift
isVoiceActive = MainActor.assumeIsolated { voice.isActive }        // seed: the model may already be active
voiceObserver = MainActor.assumeIsolated { voice.$state }
    .removeDuplicates()
    .dropFirst()
    .sink { [weak self] state in
        guard let self else { return }
        // `$state` emits BEFORE the value is stored: use the emitted `state`, never `voice.state` / `voice.isActive`, in here.
        self.isVoiceActive = (state != .idle)
        self.updateInteractivity()
        if state == .error || state == .speaking {          // only a REAL transition into these states (removeDuplicates)
            MainActor.assumeIsolated { self.presentation.flashOpen(kind: .voice) }
        }
    }
```

`wantsHover(voiceActive:)` already holds the pill open for every state except `idle`, so the flash on `.error`/`.speaking` adds only the 3 s cyan rim and the `.voice` spotlight (it is not what keeps the pill open). Add `PillFlashKind.voice` as in 2.3.

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

Exact initializer (all three closures are `@MainActor`, so the default closures may call the `@MainActor` `PillHaptics.play` under Swift 5.10):

```swift
init(
    playSound: @escaping @MainActor (String) -> Bool,        // returns false when the named sound does not exist
    haptic: @escaping @MainActor (PillHaptics.Event) -> Void,
    beep: @escaping @MainActor () -> Void
)
convenience init()   // playSound: { NSSound(named: NSSound.Name($0))?.play() ?? false }, haptic: { PillHaptics.play($0) }, beep: { NSSound.beep() }
```

`play(_ cue:)`: call `playSound(name)` only for cues that have a sound; if it returns `false` and `cue == .error`, call `beep()` once; a missing sound for any other cue is silent. Call `haptic(...)` for cues that have one. `VoiceCuePlayerTests`: the whole mapping table with fake closures, the missing-sound-error beep (once), missing sound on `captureStart` (no beep), `commit`/`done`/`captureEnd` call the right side only.
Add `voiceStart`, `voiceCommit`, `voiceNeedsConfirm`, `voiceApproved`, `voiceError` to `PillHaptics.Event` (patterns and `tapCount` as the table says), and update `PillSectionMotionTests.testOnlyTimerCompletionIsADoubleTap` to expect `tapCount == 2` for exactly `{.timerComplete, .voiceError}` and 1 for every other event.

VoiceOver: add `PillAnnouncements.voiceNeedsApproval = "Voice command needs approval"`, `voiceFailed = "Voice command failed"`, `voiceStopped = "Voice agent stopped"`.
`NotchPillView+Voice.swift` observes `voiceState` and announces ONLY on entering `awaitingApproval` (priority `.high`), `error` with severity `.warning`/`.alert`, and `paused`. Never announce listening,
transcripts, replies or command text, and never announce on `armed` (the mic would capture it). It makes no `PillHaptics` calls.

### 2.7 Status menu (the keyboard / VoiceOver path)

The pill is non-activating and never key, so every voice action must be mirrored in `StatusMenuBuilder` (rebuilt on every open; the builder reaches the model through `composition.voiceModel`). Only when `SettingsStore.shared.voiceEnabled`
(otherwise add nothing). Make the composition a pure function in `StatusMenuText.swift`:

```swift
enum VoiceMenuAction: Equatable { case talk, stopListening, approve, deny, cancel, stopAgent, resume, typeCommand }
struct VoiceMenuItemSpec: Equatable { var title: String; var isEnabled: Bool; var action: VoiceMenuAction?; var nonce: String? }   // action nil = disabled info line
static func voiceMenuItems(state: VoiceState, pending: ConfirmationRequest?, debugTyping: Bool) -> [VoiceMenuItemSpec]
static func voiceStateTitle(_ state: VoiceState) -> String          // the "Status-menu title" column of the word table in 2.4
```

The builder maps specs to `NSMenuItem`s; "Show Notch" is the existing item and stays where it is. The items:

- A disabled info item "Voice: <state title>".
- "Talk" (toggle) -> `voice.toggleTalk()` while `idle`, `speaking`, `error`, `listening`; title "Stop Listening" while `listening`.
- While `awaitingApproval`, for a card with `source == .local`: "Approve: <summary>" and "Deny", each bound to the nonce rendered at menu build time via `representedObject` (see AGENTS.md "Notification menu actions bind the app name they rendered"); Approve is disabled when `!canApprove`; the summary is `request.summary` (desnotch-authored: it IS the literal for local cards).
- While `awaitingApproval`, for a card with `source == .hermes`: ONLY "Deny" and the existing "Show Notch" item (so the card can be pinned open and read). **There is no Approve item for an agent card**: the menu would show a command it cannot show (menus may be screen-shared) and would bypass hold-to-approve. `VoiceStatusMenuTextTests` asserts there is no approve spec for an agent card.
- While `review` or `listening`: "Cancel" -> `voice.cancelReview()`.
- While `state != .idle && state != .paused`: "Stop Voice Agent" -> `voice.stopAll()`.
- While `paused`: "Resume Voice" -> `voice.resume()`.
- Only when env `DESNOTCH_VOICE_DEBUG == "1"`: "Type a Voice Command…" which opens a small `NSAlert` with a text field and calls `voice.submitTyped(text)` (empty text does nothing). In an accessory app call `NSApp.activate(ignoringOtherApps: true)` before `runModal()` and set `alert.window.initialFirstResponder = field`, or the field is unfocused.

Safety: the handler for Approve/Deny re-checks BOTH that the nonce still equals `voice.pendingConfirmation?.nonce` AND, for Approve, that `canApprove` is true, before calling `approve`/`deny` (`NSMenuItem.isEnabled` alone is not a gate: `NSMenu.autoenablesItems` re-enables items that have a target). Set `menu.autoenablesItems = false` if the builder already sets `isEnabled` explicitly on every item (check `StatusMenuBuilder.swift`); otherwise implement `validateMenuItem(_:)` in the action target and return false for a voice Approve whose nonce is not the current approvable card. The reducer (R72) is the final gate either way.

### 2.8 Settings

`VoiceSettingsSection` (added to `SettingsView.content` after the notification section) shows:

- Toggle "Voice control" bound to `settings.voiceEnabled`, with a `SettingsNote`: "Off by default. Hold the shortcut to speak. Uses the microphone and on-device speech recognition; audio is never saved."
- When on: two permission rows (Microphone, Speech Recognition) from `model.permissions` ("Allowed" / "Not allowed" / "Not asked yet"), a "Allow Access…" button -> `model.requestPermissions()`, and, when a permission is denied, buttons that open System Settings at `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` and `x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition` (`NSWorkspace.shared.open(URL)`).
- Picker "Language" over `SettingsStore.supportedVoiceLocales` ("English (US)", "Bahasa Indonesia"), Picker "Shortcut" over `VoiceHotkeyChoice` ("⌥⌘V", "⇧⌥⌘V", "⌥⌘J") with a warning-colored note "Another app uses this shortcut or the Stop shortcut ⌥⌘." when `model.hotkeyStatus == .unavailable` (only while voice is enabled), Toggle "Speak replies" (`voiceTTSEnabled`, note: "Silent in Privacy mode"), Toggle "Lower other audio while listening" (`voiceDuckMedia`).
- Toggle "Send other requests to the Hermes agent (cloud)" bound to `voiceHermesLane`, with a note in the warning color: "Anything that is not a built-in command is sent to the cloud-routed Hermes agent. Requires the locked 'voice' Hermes profile." and the status line from `model.hermesLaneStatus` ("Off", "Checking…", "Ready", "Refused: <reason word>").
- The pane is 300 pt wide (`SettingsView.contentWidth`): the section must fit it without horizontal scrolling.
- **Wiring.** `SettingsHeader` and `SettingsNote` are `private struct`s inside `App/SettingsView.swift` (around lines 411 and 431), so the new file cannot see them: you own `SettingsView.swift`, so change both to internal (drop `private`) and use them from `VoiceSettingsSection`. `SettingsView` gains `var voice: VoiceSessionModel?` (default nil, like `notificationMirror`), `WindowCoordinator` passes `voice: composition.voiceModel`, and `SettingsView.content` renders `VoiceSettingsSection(model:)` only when it is non-nil. Settings are NOT exported (do not touch `SettingsTransfer`).

## 3. Tests to write (named; each is a test method)

- `VoiceSectionPresentationTests`: one test per state (`testListeningShowsPartialAndMeter`, `testReviewShowsHeardAndRouteSummary`, `testAwaitingApprovalCardDisablesApproveWhenLiteralTooLong`, `testApproveDisabledWhenLiteralHasMoreThanSixLines`, `testHermesCardRequiresHold`, `testLocalCardApprovesWithClick`,
  `testTruncatedRequestCannotBeApproved`, `testTier3RequestCannotBeApproved`, `testPausedShowsSurvivorsAndResume`, `testPausedHasNoStopButtonAndListeningHasNoCancelButton`, `testErrorSeverityStyling`, `testCloudBadgeWhenLaneIsHermes`, `testReviewShowsRouteSummaryVerbatim`, `testRiskWordsOrderAndCap`, ...). Plus `testPrivacyModeRedactsTranscriptReplyAndLiteral` (assert none of the secret strings appear anywhere in the presentation, including an agent card's `summary`), `testNoPresentationOffersASpokenApproval`.
- `VoiceSectionRenderTests`: render `VoiceSectionView` for every `VoiceState` (use `NSHostingView` offscreen like `ArtworkGlowRenderTests`; `fittingSize` works headless; assert a non-zero size, width == the pill width you pass, and height <= `VoiceCardLayout.sectionHeightBudget` for every state except `awaitingApproval`, whose budget is `approvalHeightBudget`). Card cases, each at content widths 268 (default) AND 228 (supported minimum): a 240-character literal with no spaces; a 6-line literal; a 7-line literal (not reviewable: Approve disabled, "Too long to review here" shown). For the reviewable literals assert the full text is laid out: the literal block's fitting height >= the wrapped line count computed independently with `NSAttributedString(string: literal, attributes: [.font: <the 10pt monospaced NSFont>]).boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height` (nothing is clipped), and that the whole section height is <= 260. Follow the existing render-test pattern; use `drainMainQueue()`.
- `VoiceWingSelectionTests`: the table in 2.4 (every row, both wings), plus "voice beats volume on the left", plus an unchanged-behavior test with `voiceState == nil` for three of the existing combinations, plus `WingMetrics` width/inset/extraWidth for `.voice`.
- `VoiceHoverPolicyTests`: the full truth table of `wantsHover` (8 rows) and `acceptsMouse` unchanged.
- `VoiceStatusMenuTextTests`: for each state the list of item titles/enabled flags that `StatusMenuText.voiceMenuItems` returns, including a local card (Approve + Deny), an agent card (Deny only, NO approve spec), `canApprove == false` (Approve disabled), `debugTyping` on/off, and `voiceStateTitle` for all 11 states.
- `VoiceCuePlayerTests`: the mapping table above with fake closures; the `error` fallback beep.
- `VoiceAccessibilityTextTests`: `NotchPillView.voiceCompactLabel` for nil and all 11 states (exact words from the 2.4 table), the three `PillAnnouncements` strings, and that none of these ever contains a transcript/reply/literal string.
- Update `PillSectionMotionTests` (`testVoiceIsFirstAndEveryOtherKindShiftsByOne`, `testOnlyTimerCompletionIsADoubleTap` for `{.timerComplete, .voiceError}`), `PillInteractionPolicyTests`, `WingMetricsTests`, `PillStackBudgetTests` (voice height estimate is included in the stack; row caps still fit), `NotchPillPresentationTests` (`PillFlashKind.voice`: hold 3.0, spotlight `.voice`, rim `(.cyan, 0.5)`).
- `PillSourceGuardTests` (existing, in `PillPolishTests.swift`) must keep passing: no `.onHover`, no `repeatForever`, in any `UI/` file, and the notification-divider text match described in 2.3.1.

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

Run these and report their last lines:

```sh
swift build 2>&1 | grep -E "warning:|error:|Build complete"
scripts/voice-harness/run.sh --filter Voice
scripts/voice-harness/run.sh --filter Pill
scripts/voice-harness/run.sh --filter Wing
scripts/voice-harness/run.sh
scripts/voice-harness/lint-lite.sh Sources/DesnotchCore/UI/Voice*.swift Sources/DesnotchCore/UI/NotchPillView+Voice.swift Tests/DesnotchCoreTests/Voice/UI/*.swift   # plus every other UI file you changed
scripts/voice-harness/check-ownership.sh WP-UI
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
