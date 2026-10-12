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
| `VoiceSectionPresentation.swift` | pure values (no AppKit): `VoiceSectionSnapshot`, `VoiceSectionPresentation` and the small types it is built from (`VoiceGlyph`, `VoiceTint`, `VoiceWingRight`, `VoiceBodyLine`, `VoiceChipSpec`, `VoiceButtonSpec`, `VoiceCountdown`, `VoiceCardPresentation`), `VoiceCardLayout`, `VoiceStateWords`, `VoiceRiskWords`, `VoiceSettingsWords`, `VoiceAnnouncementPolicy`. All copy lives here so it is unit-testable (signatures and the per-state table in 2.3). |
| `VoiceSectionView.swift` | the SwiftUI section (`@MainActor struct`), renders a `VoiceSectionPresentation`. Includes `VoiceMeter` (5 bars), `VoiceApproveButton` (hold-to-approve), `VoiceLiteralBlock` (the internal view that draws the approval literal, so a test can size it), `VoiceSectionHost` (the only view that observes the model for the section), and `extension VoiceCardLayout` with the AppKit font (`literalNSFont`). |
| `NotchPillView+Voice.swift` | `extension NotchPillView`: `voiceSection`, `hasVoice`, the wing glyph view, `VoiceWingMeterHost` (the only view that observes `levels` for the wing), `static func voiceCompactLabel(_:)`, and the VoiceOver announcement modifier `VoiceAnnouncementModifier`. **No haptics here**: haptics belong to `VoiceCuePlayer`, which the coordinator calls; calling `PillHaptics` from the view would double-fire. |
| `VoiceCuePlayer.swift` | `@MainActor final class VoiceCuePlayer: VoiceCuePlaying` (earcon + haptic per cue). |
| `VoiceSettingsSection.swift` | `@MainActor struct VoiceSettingsSection: View` used by `SettingsView`. |

**Changed (existing files)**: `UI/PillMotion.swift` (the new `PillSectionKind.voice` AND the new motion token `approveHoldDuration`, 2.3), `UI/NotchPillPresentation.swift`, `UI/WingIndicator.swift`,
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

**Motion token for the safety gesture (PillMotion.swift is yours).** Add `let approveHoldDuration: TimeInterval` to `NotchAnimation.Motion` as its LAST stored property (the memberwise initializer takes arguments in declaration order, so pass `approveHoldDuration: 0.6` as the last argument of all three token sets `.minimal`, `.fluid`, `.lively`). It is `0.6` in EVERY set on purpose: the hold is a safety gesture and must neither shorten nor lengthen under Minimal / Reduce Motion. `motion.direct` is NOT this token (it is a 0.15 s `interactiveSpring` in Fluid/Lively and `nil` in Minimal); no raw duration appears in any view for the hold. Add `testApproveHoldDurationIsTheSameInEveryTokenSet` to `PillSectionMotionTests` (all three equal `0.6`).

**Observation (performance).** `NotchPillView` must NOT observe the whole model: today it has `@ObservedObject public var voice`, and
every `levels` publish (15 Hz while listening) or partial transcript would re-evaluate the whole 12-section pill body. Change it to
`public let voice: VoiceSessionModel` plus `@State var voiceState: VoiceState`. **`voiceState` is INTERNAL (no `private`)**: `hasVoice`, `voiceSection`, `stackEstimate`, the wing code and the announcement hook live in the extension files `+Voice`, `+Shared` and `+Compact`, and Swift `private` is file-scoped (`isDropTargeted` is declared the same way). Seed it in `init` with
`_voiceState = State(initialValue: MainActor.assumeIsolated { voice.state })`: `NotchPillView.init` is not `@MainActor` (`NotchWindowController.rebuildHosting` calls it from a non-isolated context) while `VoiceSessionModel.state` is, and `MainActor.assumeIsolated` is the pattern `NotchWindowController` already uses; it is safe whichever isolation the caller has, which the local Swift 6.1 compiler cannot prove for Swift 5.10. Update it with `.onReceive(voice.$state.removeDuplicates()) { voiceState = $0 }` on the root view.
`hasVoice` is `voiceState != .idle`; the wings and the structural animation use `voiceState`. The section itself is a
`VoiceSectionHost` (`@MainActor struct`, `@ObservedObject var model: VoiceSessionModel`, plus `let privacyMode: Bool` passed in from `NotchPillView`, which already observes `SettingsStore.shared`, so toggling Privacy mode re-renders the host) that builds the snapshot and renders it; only
that host re-evaluates at 15 Hz while listening (accepted cost, nothing runs at idle). The right-wing meter has its own host (2.4).

**Presentation API (exact names; all pure, in `VoiceSectionPresentation.swift`, no AppKit import).**

```swift
enum VoiceGlyph: String, Equatable {            // raw value = the SF Symbol name
    case mic = "mic.fill", ellipsis = "ellipsis", checkmark = "checkmark.circle", gear = "gearshape.fill",
         bolt = "bolt.fill", speaker = "speaker.wave.2.fill", warning = "exclamationmark.triangle.fill",
         pause = "pause.fill", stop = "stop.fill", cloud = "cloud.fill", cancel = "xmark"
}
enum VoiceTint: Equatable { case neutral, calm, amber, red }       // neutral = primary white; calm = the `PillPalette.mist` Swatch for chips and its text color for glyphs (info, dimmed); amber/red = the pill's existing status swatches in PillPalette, never raw RGB in a view
enum VoiceWingRight: Equatable { case none, meter, amberDot }
enum VoiceLineEmphasis: Equatable { case primary, secondary, caption }
struct VoiceBodyLine: Equatable { var text: String; var lineLimit: Int; var emphasis: VoiceLineEmphasis }
struct VoiceChipSpec: Equatable { var text: String; var glyph: VoiceGlyph? }
enum VoiceButtonRole: Equatable { case stop, cancel, resume, deny, approveClick, approveHold }
struct VoiceButtonSpec: Equatable {
    var role: VoiceButtonRole
    var title: String              // "Stop" / "Cancel" / "Resume" / "Deny" / "Approve"; for the icon-only buttons (stop, cancel) it is the VoiceOver label
    var glyph: VoiceGlyph?         // .stop / .cancel for the icon-only buttons, nil otherwise
    var isEnabled: Bool
    var nonce: String?             // deny / approve only: the nonce of the card ON SCREEN when the presentation was built
}
struct VoiceCountdown: Equatable {
    var deadline: Date
    var total: TimeInterval        // VoiceTiming.reviewWindow
    func remainingFraction(now: Date) -> Double      // clamped to 0...1
}
struct VoiceCardPresentation: Equatable {
    var tierLabel: String          // request.tier.label, e.g. "T2"
    var riskWords: [String]        // at most 4, in the severity-first order of the risk-word table below
    var riskOverflow: Int          // the N of "+N", 0 when nothing was cut
    var summary: String            // for a .hermes card redacted in privacy mode (fallback "Agent action"); a .local card's summary stays
    var literal: String            // what is DRAWN: the whole literal when reviewable, otherwise its first 240 characters (and at most its first 6 lines) + "…"; redacted in privacy mode (fallback "Command")
    var isLiteralComplete: Bool    // VoiceCardLayout.isLiteralReviewable(request.literal)
    var note: String?              // "Too long to review here" when !isLiteralComplete, else nil
    var hint: String?              // "Hold Approve to confirm" when requiresHold, else nil
    var requiresHold: Bool         // request.source == .hermes
    var nonce: String
}
struct VoiceSectionSnapshot: Equatable {
    // EVERY field has a default so a test writes VoiceSectionSnapshot(state: .review, finalTranscript: "x") (memberwise init, defaults shown)
    var state: VoiceState = .idle
    var partialTranscript: String = "", finalTranscript: String = "", reply: String = ""
    var reviewDeadline: Date? = nil
    var steps: [VoiceStep] = [], stepsStarted: Int = 0
    var pending: ConfirmationRequest? = nil
    var routeSummary: String? = nil, errorText: String? = nil
    var errorSeverity: VoiceFailure.Severity = .info
    var lane: VoiceLane? = nil, usesCloud: Bool = false
    var interruptListening: Bool = false
    var survivors: [String] = []
}
extension VoiceSectionSnapshot {
    /// Copies the fields above from the live model. Declared in an EXTENSION on purpose: an initializer inside the
    /// struct body would suppress the memberwise initializer, and the pure presentation tests must be able to build
    /// a snapshot field by field without a model.
    @MainActor init(model: VoiceSessionModel)
}
struct VoiceSectionPresentation: Equatable {
    init(_ snapshot: VoiceSectionSnapshot, privacyMode: Bool, now: Date)
    var title: String
    var titleLineLimit: Int                        // listening 2, review 2, error 2, speaking 3, every other state 1 (the table column below)
    var showsCloudBadge: Bool                      // snapshot.usesCloud
    var bodyLines: [VoiceBodyLine]
    var chips: [VoiceChipSpec]                     // agent step chips (at most VoiceLimits.visibleStepChips) plus one "+N" chip
    var showsMeter: Bool                           // listening, and any busy state while interruptListening
    var countdown: VoiceCountdown?                 // review only
    var buttons: [VoiceButtonSpec]                 // leading to trailing; the icon-only Stop is always last when present
    var card: VoiceCardPresentation?               // awaitingApproval with a pending request
    var tint: VoiceTint
    var wingLeft: VoiceGlyph?                      // nil only for idle; the section header shows the same glyph; always equals VoiceGlyph.wing(for: state)
    var wingRight: VoiceWingRight
    var heightBudget: CGFloat                      // VoiceCardLayout.approvalHeightBudget for awaitingApproval, else sectionHeightBudget
    var accessibilityLabel: String
}
enum VoiceCardLayout {
    static let maxVisibleCharacters = 240
    static let maxVisibleLines = 6                 // hard newlines
    static let sectionHeightBudget: CGFloat = 112  // every state except awaitingApproval
    static let approvalHeightBudget: CGFloat = 300 // awaitingApproval (the literal is never clipped, derivation below)
    static let literalFontSize: CGFloat = 10       // 10pt monospaced; PillTextStyle has no monospaced role and PillStyle.swift is not yours
    static func isLiteralReviewable(_ literal: String) -> Bool   // exact semantics below
    static func displayedLiteral(_ literal: String) -> String    // exact semantics below
    static func lines(of literal: String) -> [String]            // literal.components(separatedBy: .newlines), the ONE line counter
}
// in VoiceSectionView.swift (needs AppKit): extension VoiceCardLayout { static var literalNSFont: NSFont { .monospacedSystemFont(ofSize: literalFontSize, weight: .regular) }
//                                                                         static var literalFont: Font { .system(size: literalFontSize, design: .monospaced) } }
```

**Exact semantics of `VoiceCardLayout` (these functions gate Approve, so they are pinned).**

- Lines are counted with `literal.components(separatedBy: .newlines)` (`lines(of:)`), NEVER by splitting a `[Character]` on `"\n"`: Swift treats `"\r\n"` as ONE `Character`, so a Character split would count a Windows line break as no break at all and let 7 or more lines through the 6-line cap. `CharacterSet.newlines` also covers `\r`, U+0085, U+2028 and U+2029. (Verified: `components(separatedBy: .newlines)` turns a `\r\n` pair into TWO separators, so `"a\r\nb"` has 3 elements `["a", "", "b"]`. That over-counts, which is the SAFE direction and is deliberate: never normalize the pair away. In practice an agent card's literal comes from `CommandRiskScanner.sanitized`, which already turns every newline into the three characters `" ⏎ "`, so real line breaks reach this code only through defensive paths and tests.) An EMPTY literal has 1 line (`"".components(separatedBy: .newlines) == [""]`), 0 characters, and is reviewable (the scanner never sends one: it is `.unscanned` and not approvable anyway).
- `isLiteralReviewable(l)` = `l.count <= 240 && lines(of: l).count <= 6` (`count` is `String.count`, i.e. Characters).
- `displayedLiteral(l)`: if `isLiteralReviewable(l)` return `l` UNCHANGED. Otherwise apply the cuts in this ORDER: (1) the 6-line cut: keep the first 6 elements of `lines(of: l)` and join them with `"\n"`; (2) the 240-character cut: `String(thatResult.prefix(240))`; (3) append `"…"` (U+2026). So the result is at most 241 characters and at most 6 lines. (The joined text uses `"\n"` even if the input used `"\r\n"`; this is display only, Approve is disabled for such a literal.)

| literal | `isLiteralReviewable` | `displayedLiteral` |
|---|---|---|
| `"ls -la"` | true | `"ls -la"` |
| 241 x `"a"` | false | 240 x `"a"` + `"…"` |
| `"a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng"` (13 characters; `lines(of:)` has 13 elements because each `\r\n` splits twice) | false | `"a\n\nb\n\nc\n…"` (the first 6 elements `a, "", b, "", c, ""` joined with `\n`, then `…`) |
| `"a\nb\nc\nd\ne\nf"` (6 lines) | true | unchanged |
| `"a\nb\nc\nd\ne\nf\ng"` (7 lines, 13 characters) | false | `"a\nb\nc\nd\ne\nf…"` |
| `""` | true | `""` |
| 6 lines of 50 `"x"` (305 characters with the separators) | false | the first 240 characters of the 6 joined lines + `"…"` |

The views call `VoiceSectionPresentation` only; they never read the model fields directly. `VoiceSectionView(presentation:levels:width:motion:contrast:reduceTransparency:actions:)`
takes `motion: NotchAnimation.Motion`, `contrast: ColorSchemeContrast`, `reduceTransparency: Bool` (the values `NotchPillView` already has) and an
`actions: VoiceSectionActions` struct of closures (`stop`, `resume`, `cancel`, `approve(nonce)`, `deny(nonce)`), wired to the model's `stopAll`/`resume`/`cancelReview`/`approve`/`deny` by `VoiceSectionHost`.
**`width` is the CONTENT width, `expandedContentWidth`** (268 at the default pill width, 228 at the supported minimum), never the pill's outer width; the view lays out at exactly that width and the render tests pass 268 and 228. `levels` is only read by `VoiceMeter` when `presentation.showsMeter`.

**The remaining named APIs (exact signatures; implement these names, do not invent others).**

```swift
// VoiceSectionPresentation.swift (pure, no AppKit)
enum VoiceStateWords {
    static func wingWord(for state: VoiceState) -> String?       // the "Wing / accessibility word" column of 2.4; nil for .idle
    static func menuTitle(for state: VoiceState) -> String       // the "Status-menu title" column of 2.4 ("Idle" for .idle)
}
enum VoiceRiskWords {
    static func word(for flag: RiskFlags) -> String              // one single-flag RiskFlags value -> its chip word (table in 2.3)
    static func words(for flags: RiskFlags) -> (words: [String], overflow: Int)   // severity-first table order, at most 4, overflow = number cut
}
enum VoiceSettingsWords {
    static func hotkeyLabel(_ choice: VoiceHotkeyChoice) -> String
    static func localeLabel(_ identifier: String) -> String      // unknown identifier -> the identifier itself
    static func permissionText(_ state: VoicePermissionState) -> String
    static func laneStatusText(_ status: HermesLaneStatus) -> String         // "Refused: " + preflightWord(reason)
    static func preflightWord(_ failure: PreflightFailure) -> String
    static let shortcutShadowNote: String                         // "⌥⌘V also moves items in Finder; choose another shortcut if you use that."
    static let updateCheckNote: String                            // the full reworded update-check note of 2.8 (it is no longer "the only network request")
}
extension VoiceGlyph {
    /// The ONE glyph-for-state mapping (the left-wing glyph and the section header glyph). nil for .idle.
    /// Always equals VoiceSectionPresentation.wingLeft; a test iterates every VoiceState.
    static func wing(for state: VoiceState) -> VoiceGlyph?
}

// VoiceSectionView.swift
struct VoiceSectionActions {                                     // closures, wired by VoiceSectionHost to the model
    var stop: () -> Void
    var resume: () -> Void
    var cancel: () -> Void
    var approve: (String) -> Void                                // argument = the nonce of the card on screen
    var deny: (String) -> Void
    static let none = VoiceSectionActions(stop: {}, resume: {}, cancel: {}, approve: { _ in }, deny: { _ in })   // previews, render tests
}
@MainActor struct VoiceMeter: View {                             // 5 bars, metrics in the "Meter metrics" bullet
    static let barCount = VoiceLimits.meterBars, barWidth: CGFloat = 2, barSpacing: CGFloat = 1.5
    static let minBarHeight: CGFloat = 3, maxBarHeight: CGFloat = 12
    static let totalWidth: CGFloat = 16                          // 5 x 2 + 4 x 1.5, the tests read this name
    init(levels: [Float], motion: NotchAnimation.Motion)
}
@MainActor struct VoiceSectionHost: View {                       // VoiceSectionView.swift; the only view that observes the model for the section
    @ObservedObject var model: VoiceSessionModel
    let privacyMode: Bool, width: CGFloat                        // width = the CONTENT width (expandedContentWidth)
    let motion: NotchAnimation.Motion, contrast: ColorSchemeContrast, reduceTransparency: Bool
    init(model: VoiceSessionModel, privacyMode: Bool, width: CGFloat, motion: NotchAnimation.Motion,
         contrast: ColorSchemeContrast, reduceTransparency: Bool)
}
@MainActor struct VoiceWingMeterHost: View {                     // NotchPillView+Voice.swift; the only wing view that observes levels
    @ObservedObject var model: VoiceSessionModel
    let motion: NotchAnimation.Motion
    init(model: VoiceSessionModel, motion: NotchAnimation.Motion)
}

// StatusMenuText.swift (pure). VoiceMenuAction, VoiceMenuItemSpec and VoiceMenuPayload are TOP-LEVEL internal types in this file, not nested in StatusMenuText.
// StatusMenuText is a PUBLIC enum, so every new static on it (voiceMenuItems, voiceStateTitle) is `internal` (a `public static func` returning an internal type does not compile).
struct VoiceMenuPayload: Equatable { let action: VoiceMenuAction; let nonce: String? }   // the NSMenuItem.representedObject of every voice item
```

**Layout skeleton of `VoiceSectionView` (a sketch, tokens as above).** A `VStack(alignment: .leading, spacing: PillSpace.xs)` of: (1) the HEADER row, an `HStack`: the state glyph (`VoiceGlyph.wing(for:)` image in the tint color), the title `Text` (`.lineLimit(titleLineLimit)`, tail truncation, `.layoutPriority(1)`), a `Spacer(minLength: 0)`, and the cloud badge (`cloud.fill` glyph + "Hermes") when `showsCloudBadge`; (2) each `bodyLines` entry as a `Text` with its `lineLimit` and emphasis style; (3) the meter (`VoiceMeter`) when `showsMeter`, the countdown bar when `countdown != nil`, and the `chips` row (a wrapping-free row of `PillChip`s) when non-empty; (4) the card (tier/risk chip row, summary, `VoiceLiteralBlock`, note, hint) when `card != nil`; (5) the trailing BUTTON row (`HStack`, leading to trailing, Stop last) when `buttons` is non-empty. **Do NOT use the existing `sectionHeader()` helper for the header**: it applies `.textCase(.uppercase)` (and the section-title style), which would UPPERCASE a transcript or a reply; build the header from `PillTextStyle` roles directly and never apply a `textCase` modifier anywhere in the voice views. The whole stack is padded vertically by `PillSpace.xs` on top and bottom (the Battery row has no padding of its own to copy; the 112 and 300 budgets are derived with this padding) and laid out at exactly the content width. Type roles: `titleLineLimit` title and `primary` lines use `PillTextStyle.bodyStrong`, `secondary` lines `PillTextStyle.body`, `caption` lines `PillTextStyle.caption`; the buttons use the existing `PillButtonStyle`; the cloud badge is a plain glyph + `Text` pair, NOT a `PillChip` (`PillChip` takes a `PillPalette.Swatch` and has no glyph support), and `VoiceTint.calm` maps to the `PillPalette.mist` Swatch for chips and to its text color for glyphs.

**Accessibility structure (safety-relevant, exact).** The Battery section combines its children into one element with a label override (`accessibilityElement(children: .combine)`). **`VoiceSectionView` must NOT do that.** A combined element swallows the Deny, Approve, Stop, Cancel and Resume buttons, and then the safety claim of this document, that an agent card can be DENIED through VoiceOver or the keyboard, would silently be false. The root stack applies the container summary with `.accessibilityElement(children: .contain)` followed by `.accessibilityLabel(presentation.accessibilityLabel)`, and every `VoiceButtonSpec` button stays its own element carrying `spec.title` as its `.accessibilityLabel` (the hold button's label is "Approve, hold to confirm", below). No `.combine` and no `.ignore` anywhere in `VoiceSectionView.swift`. The idle presentation's `accessibilityLabel` is `""`. The gate is a scripted source check (section 4 and the PLAN final checks): `rg -n '\.combine\b|\.ignore\b' Sources/DesnotchCore/UI/VoiceSectionView.swift` must print nothing, and `rg -c 'accessibilityElement\(children: \.contain\)' Sources/DesnotchCore/UI/VoiceSectionView.swift` must print exactly `1`. (A headless `NSHostingView` does not expose a reliable accessibility tree, so no render test is mandated for this; the source check is the gate.) For the same reason no COMMENT in that file may contain `.combine` or `.ignore` (section 6).

Colors and type come from the existing tokens (`PillTextStyle`, `PillSpace`, `PillRowHeight`, `PillRowLeading`, `PillPalette`,
`PillSurface.highlight`, `PillFocusRing`); nothing under 10pt; all motion from `motion.*` tokens (the only exception is the countdown bar below);
no `repeatForever`, no `.onHover`, no animation while the state is unchanged. `.onChange(of:)` must use the single-parameter macOS 13 form, like the existing code.

**The per-state table** (this IS the specification of `VoiceSectionPresentation.init`; every text goes through the privacy rule below; "fb" = the fallback used in privacy mode; `Stop` = the icon-only button, `stop.fill`, role `.stop`):

| State | `title` | `bodyLines` (text, lineLimit, emphasis) | other fields | `buttons` | `wingLeft` | `wingRight` | `tint` |
|---|---|---|---|---|---|---|---|
| `idle` | "" (empty) | - | no chips, no meter, no countdown, no card, `showsCloudBadge` false | none (no buttons) | `nil` | `.none` | `.neutral` |
| `armed` | "Starting…" | - | - | Stop | `.mic` | `.none` | `.calm` |
| `listening` | the partial transcript (fb "Voice command", 2 lines) while it is non-empty, else "Listening…" | "Esc cancels" (1, caption) | `showsMeter` true | Stop (NO Cancel button; Esc cancels) | `.mic` | `.meter` | `.neutral` |
| `transcribing` | "Transcribing…" | - | - | Stop | `.ellipsis` | `.none` | `.calm` |
| `review` | "Heard: " + the final transcript (fb "Voice command", 2 lines) | `routeSummary` verbatim (1, secondary), omitted when nil | `countdown` from `reviewDeadline` (total `VoiceTiming.reviewWindow`) | Cancel (icon `.cancel`), Stop | `.checkmark` | `.none` | `.neutral` |
| `thinking` | "Thinking…" | - | `showsCloudBadge` | Stop | `.ellipsis` | `.none` | `.neutral` |
| `acting`, lane `.local` | `routeSummary`, or "Working…" when nil | - | - | Stop | `.gear` | `.none` | `.neutral` |
| `acting`, lane `.hermes` | "Working…" (also the whole content with ZERO steps) | - | `chips` = the last-started `steps` up to 3 (`PillChip`s showing the step `kind` word) plus a "+N" chip when `stepsStarted` exceeds the chips shown | Stop | `.gear` | `.none` | `.neutral` |
| `awaitingApproval` | "Needs approval" | - | `card` (below); with `pending == nil` (cannot arise) no card | Deny, Approve (`.approveClick` for a `.local` card, `.approveHold` for a `.hermes` card), Stop | `.bolt` | `.amberDot` | `.amber` |
| `speaking` | the reply (fb "Reply", 3 lines), or "Done" when the reply is empty | - | - | Stop | `.speaker` | `.none` | `.neutral` |
| `error` | `errorText`, or "Something went wrong" when nil (NOT redacted: generic and secret-free; 2 lines) | - | - | Stop | `.warning` | `.none` | `.info` -> `.calm`, `.warning` -> `.amber`, `.alert` -> `.red` |
| `paused` | `errorText` if non-nil (a tripwire: "Agent stopped: unapproved tool"), else "Agent stopped" | the survivors line when `survivors` is non-empty: "N still running: a, b, c" showing at most 3 names then ", +K" (lineLimit 2, caption); names redacted (fb "process") | - | Resume (NO Stop button: `stopAll` is a no-op while paused, R03) | `.pause` | `.none` | `.red` |

`idle` is never MOUNTED (`hasVoice` is false) but its presentation is defined so `init` is total: empty title, no body lines, chips or buttons, `wingLeft == nil`, `wingRight == .none`, `tint == .neutral`, `heightBudget == sectionHeightBudget` (112), `titleLineLimit == 1`. The Cancel, Deny and Resume buttons come first, Approve next, Stop last.

**`titleLineLimit`** (new field, so the view never has to know the state): `listening` 2, `review` 2, `error` 2, `speaking` 3, every other state 1. The title `Text` uses `.lineLimit(titleLineLimit)` with tail truncation. Model-authored text with no listed limit gets one anyway: a `.hermes` card's `summary` is `lineLimit(2)` with tail truncation (the literal below it is the part that must never be clipped, the summary may be).

**Edge cases (pinned):** (a) `awaitingApproval` with `pending == nil` (cannot arise): `card == nil`, `buttons == [Stop]` only, `wingRight == .amberDot`, tint amber; the status menu then offers only the info line and "Stop Voice Agent". (b) `acting` with `lane == nil` is treated as the `.hermes` row ("Working…", chips). (c) In privacy mode the `review` title is "Heard: Voice command" (the fixed word "Heard: " stays, the transcript is replaced by its fallback), never just "Voice command". (d) An `error` title is never redacted (generic text only). Common rules:

- **Stop-only capture**: while `interruptListening` is true (an agent is busy and the user is holding the key), in `thinking` and `acting` append a body line "Say “abort agent” to stop" (1, caption) and set `showsMeter` true. It never replaces the busy content. **In `awaitingApproval` NOTHING is added** (no abort line, `showsMeter` stays false): the card's worst case is already about 290pt of its 300pt budget, and the extra line plus meter would add about 30pt; the interrupt capture itself still works there (it is the reducer's R100), it is just not visualised on the card (the earcon and the haptic of `VoiceCuePlayer` still signal it).
- **Cloud badge**: `showsCloudBadge = snapshot.usesCloud`: a small `.cloud` glyph + "Hermes" next to the title, whenever the lane is `.hermes`. In `review` with a remote route the second line is `routeSummary` verbatim, "Send to Hermes (cloud)" (no extra word added).
- **Privacy mode** (`privacyMode == true`): partial/final transcript, reply and the approval literal are replaced by their fallbacks "Voice command", "Reply", "Command"; a `.hermes` card's `summary` is model-authored, so it is replaced too (fb "Agent action"); a `.local` card's `summary` is desnotch-authored and stays. The fixed words ("Listening…"), `routeSummary` and the generic `errorText` stay. `survivors` names are replaced.
- **`accessibilityLabel`** may contain ONLY: "Voice: <word from `VoiceStateWords`>"; ", sent to the Hermes cloud agent" when `showsCloudBadge`; `routeSummary` (desnotch-authored); for an approval, the card's `tierLabel`, its `riskWords`, and "needs approval"; the generic `errorText` for an error or a pause; and "N still running" (a count, never names). It NEVER contains a transcript, a reply, a literal, an agent-authored `summary` or a survivor name, in privacy mode or not (the visible `Text` views carry their own, already redacted, labels like any other row; the label is the container summary, applied with `.accessibilityElement(children: .contain)` and NEVER `.combine`, so every button stays a separate element: see "Accessibility structure" under the layout skeleton). `VoiceAccessibilityTextTests` asserts this with distinctive secret strings. **Exact join format:** the label is the non-empty parts joined with `", "` (comma and one space), in this order: (1) `"Voice: <word>"`; (2) `"sent to the Hermes cloud agent"` when `showsCloudBadge`; (3) `routeSummary` when the presentation shows it (review, and acting with lane `.local`); (4) for a card: `tierLabel`, then each risk word; (5) the generic `errorText` for `error`, and for `paused` when non-nil; (6) `"N still running"` when survivors is non-empty. The phrase "needs approval" comes from part (1) (it is the `VoiceStateWords` word of `awaitingApproval`) and is not repeated in part (4). Example: `"Voice: needs approval, T2, destructive"`; `"Voice: confirming, Set volume to 30%"`; `"Voice: thinking, sent to the Hermes cloud agent"`; `"Voice: stopped, Agent stopped: unapproved tool, 2 still running"`.
- **Reduce Motion / Minimal**: the meter shows a static bar set (no per-bar animation), state changes are opacity-only (existing token behavior).
  The meter updates at most at the rate `levels` arrives (the coordinator throttles to 15 Hz); animate bar height with `motion.direct` only when `motion.allowsGeometry`.
- **Meter metrics** (`VoiceMeter`, used by the wing and the section): `VoiceMeter.barCount = VoiceLimits.meterBars` (5), `barWidth = 2`, `barSpacing = 1.5`, `minBarHeight = 3`, `maxBarHeight = 12`; total width 5 x 2 + 4 x 1.5 = 16, which fits the 16pt wing slot (`WingMetrics.contentWidth(of: .voice, timerShowsLabel: true, agentLabelLength: 1) == 16`: the real signature is `contentWidth(of:timerShowsLabel:agentLabelLength:)` with NO default arguments, so tests pass the two extra arguments; the `.voice` case ignores them); bar height = `3 + level x (12 - 3)`, bars centered vertically. When `!motion.allowsGeometry` it ignores `levels` and draws the fixed pattern `[0.4, 0.7, 1.0, 0.7, 0.4]`.
- **Countdown bar (review)**: the one place a raw duration is allowed, because the bar is determinate: when `motion.allowsGeometry`, animate its width from the
  current remaining fraction to 0 with `.linear(duration: remaining)` (the pattern `PillMarquee`/`PillControls` use for finite progress); under Reduce Motion / Minimal it is a static bar showing the remaining fraction at render time. No looping. **Key the bar on the deadline**: give the bar view `.id(countdown.deadline)` and start the animation from an `.onAppear` of that identity-keyed view, so a re-render of `VoiceSectionHost` in the middle of the review window (a privacy toggle, a `levels` publish) does not restart the animation.
- **Risk-flag chip words** (`VoiceRiskWords.word(for:)`; `words(for:)` emits them in EXACTLY this order, SEVERITY FIRST, at most 4, then "+N"): `.destructive` "destructive", `.sudo` "sudo", `.protectedPath` "protected path", `.pipeToInterpreter` "pipe to shell", `.base64Decode` "base64", `.evalUse` "eval", `.commandSubstitution` "substitution", `.hiddenCharacters` "hidden characters", `.unscanned` "unscanned", and then the four low-severity flags `.redirect` "redirect", `.chaining` "chained", `.pipe` "pipe", `.url` "network".
  **Why this order:** a card can only carry the five non-auto-deny flags (`url`, `pipe`, `chaining`, `redirect`, `destructive`; the auto-deny flags are refused without a card, R84), and `destructive` is the reason a command is T2, so it must never be the word that falls into "+N". Pinned example: all five card flags set give `words == ["destructive", "redirect", "chained", "pipe"]` and `overflow == 1` (the cut word is "network"). The cap of 4 and the "+N" overflow are unchanged. The auto-deny words are in the table for totality only (a test iterates every single flag).
- **The approval card** (`awaitingApproval`, `pendingConfirmation != nil`): tier chip (`request.tier.label` plus the risk words above), the `summary` line, and the `literal` in a monospaced block (`VoiceLiteralBlock`). For a `.local` card the summary and the literal are the same string (`i.summary`): draw the summary line only when `summary != literal`, so the card never shows one line twice. **The chip row is ONE line:** the tier chip, up to 4 risk-word chips and a "+N" chip can exceed the 228pt content width (for example `T2` + destructive + redirect + chained + pipe + "+1", the five-flag card, is about 250pt at 10pt type), so lay it out as a single non-wrapping row inside `ViewThatFits(in: .horizontal)` whose fallback is the same row with the risk chips replaced by one compact chip "N risks"; it may never push the card past its 300pt budget. The render tests include this worst case at width 228.
  **The literal is never clipped**: `VoiceLiteralBlock(text:)` renders `card.literal` in `VoiceCardLayout.literalFont` (10pt monospaced) with NO `lineLimit` and `.fixedSize(horizontal: false, vertical: true)`, padded by `VoiceLiteralBlock.horizontalPadding = PillSpace.s` and `verticalPadding = PillSpace.xs` (static constants the render test reads). Measured: 240 unbroken characters take 6 lines (78pt) at 252pt wide and 8 lines (104pt) at 212pt wide, and the worst LEGAL literal takes about 12 lines (156pt) at the minimum width, so a `lineLimit(6)` would silently hide text that Approve covers. Approve is enabled only when the whole literal is on screen and reviewable:
  `request.canApprove && VoiceCardLayout.isLiteralReviewable(request.literal)` (`literal.count <= 240` and at most 6 hard-newline lines). Otherwise the card draws the first 240 characters (and at most the first 6 lines) + "…", `note` is "Too long to review here", and **Approve is disabled**.
  Approve is also disabled when `!request.canApprove` (truncated by the scanner, auto-deny flags, tier T3). Buttons: **Deny** (click) and **Approve**. Both call `model.approve(nonce:)` / `model.deny(nonce:)` with `VoiceButtonSpec.nonce`, which is the nonce of the card that is on screen, captured when the presentation was built.
  For a `.local` card (volume above 70%), Approve is a click. **For a `.hermes` card, Approve is hold-to-approve** (`VoiceApproveButton`):
  - Detection: `LongPressGesture(minimumDuration: motion.approveHoldDuration)` with `.updating($isPressing) { value, state, _ in state = value }` for the pressed state and `.onEnded { _ in approve(nonce) }` for the commit. A plain click (press and release before the duration) ends the gesture without `.onEnded` and therefore does nothing; moving away (`maximumDistance` default) cancels the hold. Releasing early cancels. Detect the pressed state change with the single-parameter `.onChange(of: isPressing) { pressing in ... }`.
  - Ring: a `Circle().trim(from: 0, to: progress)` around the button. When `motion.allowsGeometry`, on `pressing == true` set `progress = 1` inside `withAnimation(.linear(duration: motion.approveHoldDuration))` and on release reset it to 0 with animation `nil`. When `!motion.allowsGeometry` (Minimal / Reduce Motion) the ring is STATIC: a full ring at reduced opacity while pressed, no progress animation. The hold itself still takes `approveHoldDuration`.
  - Identity: key the button with `.id(request.nonce)` so `@State`/`@GestureState` hold state can never carry from one card to the next (a hold started on card A cannot fire for card B, and the commit always uses the nonce bound at render time).
  - **The commit re-checks everything itself.** The control is a gesture, not a `Button`, so `.disabled(...)` is not a reliable gate (a gesture on a disabled view can still be driven programmatically, and the spec can change between render and release). The `.onEnded` closure calls ONE static function, `VoiceApproveButton.commit(spec: VoiceButtonSpec, presentedNonce: String, actions: VoiceSectionActions) -> Bool`, which does `guard spec.isEnabled, let nonce = spec.nonce, nonce == presentedNonce else { return false }`, then `actions.approve(nonce)` and `return true` (`presentedNonce` is the nonce captured when the view was built). The reducer's R72/R71 remain the backstop, not the gate. A `VoiceApproveButton` built with a disabled spec attaches no gesture at all. `VoiceSectionRenderTests` calls `commit` directly: a disabled spec, a nil nonce and a mismatching nonce each return false and call nothing; a matching enabled spec calls `approve` exactly once with that nonce.
  - Accessibility: the label is "Approve, hold to confirm". There is NO `.accessibilityAction` that approves: an agent card can only be DENIED through VoiceOver or the keyboard, on purpose (the hold has no accessible shortcut, and the status menu has no Approve for an agent card either, 2.7). Do not add one.
  The ripple (`PillRipple`) plays `attentionPulseCount` times (0 under Reduce Motion), then the amber tint stays static.
  Height: the approval state has its own budget, `VoiceCardLayout.approvalHeightBudget = 300`; every other state must fit `sectionHeightBudget = 112`. Derivation of 300: the worst legal literal at the minimum width is about 156pt (above) and the card's chrome (header row, tier chip row, summary, hint, button row, paddings) is budgeted at about 124pt, so about 280pt, with only about 10pt of margin to 300 in the worst case. **The lever if the render test overshoots 300** (use it, do not improvise): first set the agent summary to `lineLimit(1)` when the literal wraps to more than 6 rows, then, if still over, move the hint ("Hold Approve to confirm") into the button row as the leading caption instead of its own line. Never shrink the literal font or clip the literal. These two numbers are the ones `PillStackEstimate` uses (2.3.1) and the render tests assert.
  **The pinned worst-case fixture (a `private let worstCaseLiteral` in `VoiceSectionRenderTests.swift`, not in Sources):** SIX lines of exactly 38 characters each joined by `"\n"`, which is 6 x 38 + 5 = **233 characters**, so `isLiteralReviewable` is TRUE (233 <= 240 and 6 lines) and Approve is enabled. At content width 228 the text area is 228 - 2 x `VoiceLiteralBlock.horizontalPadding` = 212pt, about 35 monospaced characters of 10pt per row, so each 38-character line wraps to 2 rows: 12 rows, the maximum a legal literal can take (each extra wrapped row costs 35 more characters, and 235 characters of budget over six lines allow at most 6 extra rows). At width 268 the same fixture takes 6 rows (about 41 characters per row). Do not build the fixture from 40-character lines: 6 x 40 + 5 = 245 characters is over the cap, `isLiteralReviewable` is FALSE and Approve is disabled; that 245-character literal is the "not reviewable by length" fixture, kept as a separate test row.
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

`NotchPillView+Shared.swift`: `hasContentBeforePrivacyAction` becomes `hasVoice || hasNotification || hasMiddleSection`. The "previous content" chains of the later sections (`hasMedia || hasTimer || ...`) do not mention the notification today, and must not mention voice either: the voice block and the notification block own their own dividers. Add `let hasVoice: Bool` AND `let voiceCardShown: Bool` (`voiceState == .awaitingApproval`) to `PillStructuralAnimationState` (a `private struct` declared at the top of `NotchPillView.swift`, NOT in `+Shared`; set both where the state is built, in that file): the jump between the 112pt section and the 300pt approval card must be animated by the structural spring, not snap.

`PillStackBudget.swift`: `PillStackEstimate` gains, AFTER the existing stored properties and WITH defaults (the budget tests build it with labelled memberwise arguments and must keep compiling): `var hasVoice = false`, `var voiceState: VoiceState? = nil`, `static let voiceHeight = VoiceCardLayout.sectionHeightBudget` (112) and `static let voiceApprovalHeight = VoiceCardLayout.approvalHeightBudget` (300). In `height(caps:)` insert FIRST in `sections`: `if hasVoice { sections.insert(voiceState == .awaitingApproval ? Self.voiceApprovalHeight : Self.voiceHeight, at: 0) }`. `stackEstimate` (in `+Shared`) sets `hasVoice: hasVoice, voiceState: voiceState`. `PillStackBudgetTests` adds "voice height estimate included" (idle estimate unchanged; `hasVoice` adds 112 plus one divider; `.awaitingApproval` adds 300 plus one divider).

### 2.4 Wings

Add `WingIndicator.voice` and `WingInputs.voiceState: VoiceState?` (nil when idle; it defaults to nil). Extend `WingSelection.select` (pure; keep it a pure function) so that:

| `voiceState` | left wing | right wing |
|---|---|---|
| `nil` | unchanged | unchanged |
| `armed`, `transcribing`, `review`, `thinking`, `acting`, `speaking`, `error`, `paused` | `.voice` | unchanged |
| `listening`, `awaitingApproval` | `.voice` | `.voice` |

`.voice` outranks every other left-wing indicator including `.volume`; on the right it outranks `.volume` only in `listening`/`awaitingApproval`. The wing indicator is
glyph-only: `WingMetrics.contentWidth(of: .voice, timerShowsLabel: true, agentLabelLength: 1) == 16` (shorthand elsewhere in this document: `contentWidth(of: .voice)`), `inset(of: .voice) == persistentInset`, so `extraWidth` stays 0. Left glyph by state as in the per-state table of 2.3. `wingInputs.voiceState` is `voiceState == .idle ? nil : voiceState` (read from the internal `@State`, never from the model). **The right wing needs live `levels` but the pill observes only `voice.$state`, so the meter has its own host**: `VoiceWingMeterHost` (`@MainActor struct`, `@ObservedObject var model: VoiceSessionModel`, plus `let motion: NotchAnimation.Motion`) in `NotchPillView+Voice.swift` renders `VoiceMeter(levels: model.levels, ...)` with the metrics of 2.3 (5 bars, 2pt wide, 1.5pt gap, heights 3 to 12pt, 16pt wide in total) and is used for the right-wing `.voice` indicator while `voiceState == .listening`; for `.awaitingApproval` the right wing is a plain amber dot (a plain view, nothing observed). Reading `voice.levels` from a non-observing view would freeze the bars, and putting `@ObservedObject` back on the pill would undo the performance goal: use the host. Note for reviewers: while voice is active the pill is held open (2.5), so the collapsed wings show only during the exit grace period; the wing code is still specified and tested as a pure function.

**Accessibility text (pure).** Provide `static func voiceCompactLabel(_ state: VoiceState?) -> String?` (in `NotchPillView+Voice.swift`; returns nil for nil/idle, else "Voice: <word>") and use it in
`compactAccessibilityLabel` (in `+Compact`, where it is a `private var`): the voice phrase goes FIRST in `parts` (voice outranks every other left-wing indicator), before the media/timer phrases. One word table (`VoiceStateWords` in `VoiceSectionPresentation.swift`) feeds the label, the status menu and the tests; it never contains transcript, reply or literal text:

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
The decision is a pure function in `VoiceSectionPresentation.swift`: `VoiceAnnouncementPolicy.announcement(for state: VoiceState, severity: VoiceFailure.Severity) -> (message: String, isHighPriority: Bool)?`: `awaitingApproval` -> `(voiceNeedsApproval, true)`; `error` with severity `.warning` or `.alert` -> `(voiceFailed, false)`; `paused` -> `(voiceStopped, false)`; everything else (including `error` with `.info`, `armed`, `listening`, `speaking`) -> `nil`. Never announce listening, transcripts, replies or command text, and never announce on `armed` (the mic would capture it).

**Where it runs (the stale-severity trap).** `VoiceSessionModel.apply` assigns `state` BEFORE `errorSeverity`, and a `$state` sink or `.onReceive` fires in `willSet`, before either value is stored. So the decision must NEVER be made inside the `$state` receive closure (it would see the PREVIOUS severity). Announce from `.onChange(of: voiceState) { newState in ... }`, which SwiftUI runs in a later update pass, after `apply` has returned, and read `voice.errorSeverity` THERE. The hook is `VoiceAnnouncementModifier`, a `@MainActor struct ... : ViewModifier` in `NotchPillView+Voice.swift` with `let state: VoiceState` and `let model: VoiceSessionModel` (a plain `let`, NOT observed) whose body is `content.onChange(of: state) { newState in if let a = VoiceAnnouncementPolicy.announcement(for: newState, severity: model.errorSeverity) { AccessibilityAnnouncer.announce(a.message, priority: a.isHighPriority ? .high : .medium) } }`. `NotchPillView.body` applies it ONCE at the root, next to the `.onReceive(voice.$state...)` that feeds `voiceState`: `.modifier(VoiceAnnouncementModifier(state: voiceState, model: voice))`. It makes no `PillHaptics` calls.

### 2.7 Status menu (the keyboard / VoiceOver path)

The pill is non-activating and never key, so every voice action must be mirrored in `StatusMenuBuilder` (rebuilt on every open; the builder reaches the model through `composition.voiceModel`). Only when `SettingsStore.shared.voiceEnabled`
(otherwise add nothing). Make the composition a pure function in `StatusMenuText.swift`:

```swift
enum VoiceMenuAction: Equatable { case talk, stopListening, approve, deny, cancel, stopAgent, resume, typeCommand }
struct VoiceMenuItemSpec: Equatable { var title: String; var isEnabled: Bool; var action: VoiceMenuAction?; var nonce: String? }   // action nil = disabled info line
static func voiceMenuItems(state: VoiceState, pending: ConfirmationRequest?, debugTyping: Bool) -> [VoiceMenuItemSpec]
static func voiceStateTitle(_ state: VoiceState) -> String          // the "Status-menu title" column of the word table in 2.4
```

**Placement.** The builder maps the specs to `NSMenuItem`s and inserts the block RIGHT AFTER the existing "Show Notch" item and its separator (`rebuildMenu`, just before the "Update Available" block), followed by its own separator. "Show Notch" is the existing item and stays where it is. Nothing is added while voice is off.

**The items per state** (this is the specification of `voiceMenuItems`; the first item is always the disabled info line "Voice: <state title>", `action == nil`):

| State | Items after the info line |
|---|---|
| `idle` | "Talk" (`.talk`) |
| `armed`, `transcribing`, `thinking`, `acting` | "Stop Voice Agent" (`.stopAgent`) |
| `listening` | "Stop Listening" (`.stopListening`), "Cancel" (`.cancel`), "Stop Voice Agent" |
| `review` | "Cancel", "Stop Voice Agent" |
| `awaitingApproval`, card `source == .local` | "Approve: <summary>" (`.approve`, nonce of the card; disabled when `!canApprove`), "Deny" (`.deny`, nonce), "Stop Voice Agent" |
| `awaitingApproval`, card `source == .hermes` | "Deny" (`.deny`, nonce), "Stop Voice Agent". **There is NO Approve item for an agent card**: the menu would show a command it cannot show (menus may be screen-shared) and would bypass hold-to-approve. The existing "Show Notch" item stays so the card can be pinned open and read. `VoiceStatusMenuTextTests` asserts there is no `.approve` spec for an agent card. |
| `speaking`, `error` | "Talk", "Stop Voice Agent" |
| `paused` | "Resume Voice" (`.resume`) |
| `awaitingApproval` with `pending == nil` (cannot arise) | "Stop Voice Agent" only (no Approve, no Deny, no nonce) |

(Deliberate: there is no soft "Cancel" while the agent is `thinking` or `acting`, only "Stop Voice Agent"; `Esc` covers the keyboard path for cancelling a capture or a review.) Plus, in EVERY state, only when `debugTyping` (env `DESNOTCH_VOICE_DEBUG == "1"`): "Type a Voice Command…" (`.typeCommand`), enabled only while `state == .idle`; it opens a small `NSAlert` with a text field and calls `voice.submitTyped(text)` (empty text does nothing). In an accessory app call `NSApp.activate(ignoringOtherApps: true)` before `runModal()` and set `alert.window.initialFirstResponder = field`, or the field is unfocused. The local-card summary is `request.summary` (desnotch-authored: it IS the literal for local cards). `.talk` and `.stopListening` both call `voice.toggleTalk()`; `.cancel` calls `voice.cancelReview()`; `.stopAgent` calls `voice.stopAll()`; `.resume` calls `voice.resume()`. Approve/Deny bind the nonce rendered at menu build time via `representedObject` (see AGENTS.md "Notification menu actions bind the app name they rendered").

**Enablement (the existing builder does NOT set `autoenablesItems`).** `StatusMenuBuilder` never sets `autoenablesItems`, and its action-less header items rely on auto-disable, so do NOT set `menu.autoenablesItems = false`. Instead implement `@objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool` in the `StatusMenuBuilder+Actions` extension (the `@objc` is REQUIRED, or make the class conform to `NSMenuItemValidation`; without one of the two AppKit never calls it and the nonce gate silently does nothing): it returns `true` for every item that is not a voice item (so every existing item behaves exactly as before; mark voice items by a `representedObject` payload type, e.g. `VoiceMenuPayload`), and for a voice item: Approve is enabled only when the payload nonce equals `composition.voiceModel.pendingConfirmation?.nonce` AND that card's `canApprove` is true; Deny only when the nonce still matches; `.typeCommand` only while the state is `.idle`; the others follow their spec's `isEnabled`. `NSMenuItem.isEnabled` alone is not a gate (auto-enable re-enables items that have a target). The action handler ALSO re-checks both conditions (nonce equality, and `canApprove` for Approve) before calling `approve`/`deny`. The reducer (R72) is the final gate either way.

### 2.8 Settings

`VoiceSettingsSection` (added to `SettingsView.content` after the notification section) shows:

- Toggle "Voice control" bound to `settings.voiceEnabled`, with a `SettingsNote`: "Off by default. Hold the shortcut to speak. Uses the microphone and on-device speech recognition; audio is never saved."
- When on (every row below, INCLUDING the Hermes toggle, is shown only while `settings.voiceEnabled` is true): two permission rows (Microphone, Speech Recognition) from `model.permissions`, a "Allow Access…" button -> `model.requestPermissions()` (shown while either state is `.notDetermined`), and, when a permission is `.denied`, buttons that open System Settings at `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` and `x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition` (`NSWorkspace.shared.open(URL)`); no button for `.restricted` (the user cannot change it).
- Picker "Language" over `SettingsStore.supportedVoiceLocales` ("English (US)", "Bahasa Indonesia"), Picker "Shortcut" over `VoiceHotkeyChoice` with a warning-colored note "Another app uses this shortcut or the Stop shortcut ⌥⌘." when `model.hotkeyStatus == .unavailable` (only while voice is enabled), and, while the selected choice is `.optionCommandV`, a neutral `SettingsNote` with `VoiceSettingsWords.shortcutShadowNote` ("⌥⌘V also moves items in Finder; choose another shortcut if you use that.": the default combination shadows Finder's "Move Item Here" while Finder is frontmost), Toggle "Speak replies" (`voiceTTSEnabled`, note: "Silent in Privacy mode"), Toggle "Lower other audio while listening" (`voiceDuckMedia`).
- Toggle "Send other requests to the Hermes agent (cloud)" bound to `voiceHermesLane`, with a note in the warning color: "Anything that is not a built-in command is sent to the cloud-routed Hermes agent. Requires the locked 'voice' Hermes profile." and the status line from `model.hermesLaneStatus`.
- The pane is 300 pt wide (`SettingsView.contentWidth`): the section must fit it without horizontal scrolling.

**Copy tables (all in `VoiceSettingsWords` in `VoiceSectionPresentation.swift`, pure, tested in `VoiceSectionPresentationTests`).** `VoiceHotkeyChoice` and `SettingsStore.supportedVoiceLocales` carry no labels, so the labels live here:

| `VoiceHotkeyChoice` | label | | locale id | label |
|---|---|---|---|---|
| `optionCommandV` | "⌥⌘V" | | `en-US` | "English (US)" |
| `shiftOptionCommandV` | "⌥⇧⌘V" | | `id-ID` | "Bahasa Indonesia" |
| `optionCommandJ` | "⌥⌘J" | | anything else | the identifier itself |

The hotkey labels use the standard Apple modifier order (control, option, shift, command), which is also what the existing `HotKeyBinding.displayString` produces, so the Shift variant is `⌥⇧⌘V`, never `⇧⌥⌘V`. `VoiceHotkeyMap` belongs to WP-PLATFORM and may not be merged when you build, so `hotkeyLabel` returns these three LITERALS (it must not call `VoiceHotkeyMap`). WP-PLATFORM's `VoiceHotkeyMapTests` pins `VoiceHotkeyMap.binding(for:).displayString` to the same three strings, and the PLAN integration check compares the two after the merge.

| `VoicePermissionState` | row text | | `HermesLaneStatus` | status line |
|---|---|---|---|---|
| `authorized` | "Allowed" | | `off` | "Off" |
| `notDetermined` | "Not asked yet" | | `checking` | "Checking…" |
| `denied` | "Not allowed" | | `ready` | "Ready" |
| `restricted` | "Restricted by this Mac" | | `refused(reason)` | "Refused: " + the word below |
| `unknown` | "Unknown" | | | |

| `PreflightFailure` | reason word | | `PreflightFailure` | reason word |
|---|---|---|---|---|
| `binaryMissing` | "Hermes not found" | | `configNotLocked` | "profile not locked" |
| `profileMissing` | "no voice profile" | | `mcpConfigured` | "MCP configured" |
| `approvalsOff` | "approvals off" | | `protocolMismatch` | "protocol mismatch" |
| `allowlistNotEmpty` | "allowlist not empty" | | `notImplemented` | "not available" |
| `toolsetOutsideAllowlist` | "toolsets not empty" | | | |

Every `PreflightFailure` case has a word (a test iterates `PreflightFailure.allCases`).
- **Wiring.** `SettingsHeader` and `SettingsNote` are `private struct`s inside `App/SettingsView.swift` (around lines 411 and 431), so the new file cannot see them: you own `SettingsView.swift`, so change both to internal (drop `private`) and use them from `VoiceSettingsSection`. `SettingsView` gains `var voice: VoiceSessionModel?` (default nil, like `notificationMirror`), declared LAST, after `onShowOnboarding`, so the existing labelled call order in `WindowCoordinator` (`notificationMirror:`, `globalHotKey:`, `onShowOnboarding:`) stays valid and the new `voice: composition.voiceModel` argument is appended at the end of that call, and `SettingsView.content` renders `VoiceSettingsSection(model:)` only when it is non-nil. Settings are NOT exported (do not touch `SettingsTransfer`).
- **A privacy statement that becomes false (you own `SettingsView.swift`, so you fix it).** Around line 253 the update-check `SettingsNote` says "Asks GitHub once a day whether a newer release exists. That is the only network request desnotch makes. You still download and install updates yourself." Once the optional Hermes cloud lane exists that is untrue and would sit next to the new cloud toggle. Replace the middle sentence so the note reads exactly: "Asks GitHub once a day whether a newer release exists. The update check is the only network request desnotch makes on its own; the optional Hermes agent lane (Voice control) sends requests to your configured agent. You still download and install updates yourself." Gate: `rg -n 'only network request' Sources/DesnotchCore/App/SettingsView.swift` must print nothing (section 4), and `VoiceSectionPresentationTests` has `testUpdateNoteNoLongerClaimsToBeTheOnlyNetworkRequest`, which cannot read the source, so it asserts the replacement text through a constant: put the sentence in `VoiceSettingsWords.updateCheckNote` (the full new note, a `static let`) and have `SettingsView` render `VoiceSettingsWords.updateCheckNote`; the test asserts the constant contains "on its own" and "Hermes agent lane" and does not contain "That is the only network request".

## 3. Tests to write (named; each is a test method)

Every test class below that builds a `VoiceSessionModel`, an `NSHostingView`, a `VoiceCuePlayer` or reads `SettingsStore` is declared `@MainActor final class XTests: XCTestCase {` (as `ArtworkGlowRenderTests` is).

- `VoiceSectionPresentationTests`: one test per row of the per-state table in 2.3, asserting `title`, `bodyLines`, `chips`, `buttons` (roles, titles, enabled flags, order), `wingLeft`, `wingRight`, `tint`, `heightBudget` (`testListeningShowsPartialAndMeter`, `testListeningWithEmptyPartialSaysListening`, `testReviewShowsHeardAndRouteSummary`, `testActingAgentWithZeroStepsSaysWorking`, `testActingLocalShowsRouteSummary`, `testErrorWithNilTextUsesTheGenericFallback`, `testIdleHasAnEmptyPresentation` (the idle row: empty title, no lines/chips/buttons, `wingLeft == nil`, `heightBudget == 112`, `titleLineLimit == 1`), `testTitleLineLimitPerState` (listening/review/error 2, speaking 3, the rest 1), `testWingGlyphMatchesThePresentationForEveryState` (`VoiceGlyph.wing(for:)` equals `wingLeft` for all 11), `testAwaitingApprovalWithoutAPendingRequestOffersOnlyStop`, `testActingWithNilLaneIsTreatedAsHermes`, `testAbortLineAndMeterAreNotAddedOnTheApprovalCard`, `testPrivacyModeReviewTitleKeepsHeardAndRedactsTheTranscript` ("Heard: Voice command"), `testAccessibilityLabelJoinFormat` (the four examples of 2.3), `testSnapshotMemberwiseInitIsAvailable` (a snapshot is built field by field with no model), `testLiteralLayoutSemantics` (the six-row table of `VoiceCardLayout`: reviewability and `displayedLiteral`, including the CRLF and 241-character rows), `testPausedAfterTripwireShowsTheTripwireText`, `testPausedAfterUserStopShowsAgentStopped`, `testPausedSurvivorsAreCappedAtThreeNames` ("N still running: a, b, c, +K"), `testPausedShowsSurvivorsAndResume`, `testPausedHasNoStopButtonAndListeningHasNoCancelButton`, `testErrorSeverityStyling`, `testCloudBadgeWhenLaneIsHermes`, `testReviewShowsRouteSummaryVerbatim`, `testInterruptListeningAddsTheAbortLineAndMeter`, ...), plus the card tests: `testAwaitingApprovalCardDisablesApproveWhenLiteralTooLong`, `testApproveDisabledWhenLiteralHasMoreThanSixLines`, `testHermesCardRequiresHold` (`.approveHold`, `hint`), `testLocalCardApprovesWithClick` (`.approveClick`), `testTruncatedRequestCannotBeApproved`, `testTier3RequestCannotBeApproved`, `testButtonsCarryTheNonceOfTheCardOnScreen`, `testRiskWordsOrderAndCap` (severity-first order; all five card flags give `["destructive", "redirect", "chained", "pipe"]` with overflow 1; `[.url, .pipe]` gives `["pipe", "network"]`; `[.chaining, .destructive]` gives `["destructive", "chained"]`; one test iteration over every single flag checks `word(for:)`; no flags give `[]` and 0), `testCountdownRemainingFraction`. Plus `testPrivacyModeRedactsTranscriptReplyAndLiteral` (assert none of the secret strings appear anywhere in the presentation, including an agent card's `summary` and the survivors names, and that a `.local` card's desnotch-authored `summary` is kept), `testNoPresentationOffersASpokenApproval`, `testAccessibilityLabelNeverContainsLiveContent` (distinctive strings in transcript, reply, literal, agent summary and survivor names, with privacy mode ON and OFF: none appears in `accessibilityLabel`), and the settings copy: `testSettingsWordsCoverEveryPreflightFailure` (iterates `PreflightFailure.allCases`), the permission-state, hotkey and locale tables, `testShortcutShadowNoteText` (the exact `VoiceSettingsWords.shortcutShadowNote` string), `testHotkeyLabelsUseTheAppleModifierOrder` (`⌥⌘V`, `⌥⇧⌘V`, `⌥⌘J`) and `testUpdateNoteNoLongerClaimsToBeTheOnlyNetworkRequest` (2.8).
- `VoiceSectionRenderTests`: render `VoiceSectionView` for every NON-IDLE `VoiceState` (10 states; `idle` is never mounted, its presentation is covered by `testIdleHasAnEmptyPresentation`) (use `NSHostingView` offscreen like `ArtworkGlowRenderTests`; `fittingSize` works headless; assert a non-zero size, width == the content width you pass, and height <= `presentation.heightBudget` (`VoiceCardLayout.sectionHeightBudget` for every state except `awaitingApproval`, whose budget is `approvalHeightBudget` = 300)). Card cases, each at content widths 268 (default) AND 228 (supported minimum): a 240-character literal with no spaces; a 6-line literal; the pinned WORST legal literal of 2.3 (six lines of exactly 38 characters joined by `"\n"`, 233 characters, reviewable, Approve ENABLED, 12 rows at width 228: assert `VoiceCardLayout.isLiteralReviewable(fixture)` is true and the card's Approve spec is enabled before measuring anything); a 245-character literal made of six 40-character lines (NOT reviewable by length: Approve disabled, note shown); a 7-line literal (not reviewable: Approve disabled, "Too long to review here" shown). The 300pt budget test and the nothing-clipped test use the 233-character fixture. For the reviewable literals size `VoiceLiteralBlock(text:)` on its own (it is an internal view precisely so this is possible) at `contentWidth` and assert the full text is laid out: its fitting height >= the wrapped height computed independently with `NSAttributedString(string: literal, attributes: [.font: VoiceCardLayout.literalNSFont]).boundingRect(with: CGSize(width: contentWidth - 2 * VoiceLiteralBlock.horizontalPadding, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height + 2 * VoiceLiteralBlock.verticalPadding` (nothing is clipped), and that the whole card height is <= 300. The existing render tests (`ArtworkGlowRenderTests`) capture pixels with `CGWindowListCreateImage`; yours do NOT: they only read `NSHostingView.fittingSize` (measured to work headless: a 240-character 10pt monospaced block at 228pt wide is 8 rows and 104pt), so borrow only the hosting-view set-up from them. Use `drainMainQueue()` (synchronous tests only; an `async` test uses `await drainMainOperationQueue()`).
- `VoiceWingSelectionTests`: the table in 2.4 (every row, both wings), plus "voice beats volume on the left", plus an unchanged-behavior test with `voiceState == nil` for three of the existing combinations, plus `WingMetrics` width/inset/extraWidth for `.voice`, plus the meter metrics (`VoiceMeter` total width == 16).
- `VoiceHoverPolicyTests`: the full truth table of `wantsHover` (8 rows) and `acceptsMouse` unchanged.
- `VoiceStatusMenuTextTests`: for each of the 11 states the list of item titles/enabled flags/actions that `StatusMenuText.voiceMenuItems` returns (the table in 2.7), including a local card (Approve + Deny), an agent card (Deny only, NO `.approve` spec), `canApprove == false` (Approve disabled), `debugTyping` on/off (the item is enabled only in `.idle`), and `voiceStateTitle` for all 11 states.
- `VoiceCuePlayerTests`: the mapping table above with fake closures; the `error` fallback beep.
- `VoiceAccessibilityTextTests`: `NotchPillView.voiceCompactLabel` for nil and all 11 states (exact words from the 2.4 table), the three `PillAnnouncements` strings, `VoiceAnnouncementPolicy.announcement(for:severity:)` for every state x severity (only `awaitingApproval` (high priority), `error` with `.warning`/`.alert`, and `paused` announce), and that none of these ever contains a transcript/reply/literal string.
- Update `PillSectionMotionTests` (`testVoiceIsFirstAndEveryOtherKindShiftsByOne`, `testApproveHoldDurationIsTheSameInEveryTokenSet`, `testOnlyTimerCompletionIsADoubleTap` for `{.timerComplete, .voiceError}`), `PillInteractionPolicyTests`, `WingMetricsTests`, `PillStackBudgetTests` (voice height estimate is included in the stack: 112 / 300 plus one divider; row caps still fit), `NotchPillPresentationTests` (`PillFlashKind.voice`: hold 3.0, spotlight `.voice`, rim `(.cyan, 0.5)`).
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

  In a sandbox that only allows writes inside the worktree use `W="$PWD/.build/scratch-check"; rm -rf "$W"` instead of `mktemp -d` (`.build/` is gitignored; remove `$W` afterwards). Commands this package needs to be allowed to run: `swift`, `rsync` (inside `run.sh`), `python3` (inside `run.sh`), `rg`, `bash`, and read-only `git` (`status`, `diff`, `ls-files`; `check-ownership.sh` uses them).

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

Run these and report their last lines:

```sh
swift build 2>&1 | grep -E "warning:|error:|Build complete"
scripts/voice-harness/run.sh --filter Voice
scripts/voice-harness/run.sh --filter Pill
scripts/voice-harness/run.sh --filter Wing
scripts/voice-harness/run.sh
scripts/voice-harness/lint-lite.sh Sources/DesnotchCore/UI/Voice*.swift Sources/DesnotchCore/UI/NotchPillView+Voice.swift Tests/DesnotchCoreTests/Voice/UI/*.swift   # plus every other UI file you changed
scripts/voice-harness/check-ownership.sh WP-UI
# forbidden patterns (PLAN section 12), comments included; each must print nothing (rg exits 1 on no match: that is the good outcome)
rg -n '\bprint\(|\bNSLog\(|\bos_log|\bLogger\(|\.onHover|repeatForever|serve --stop|pkill|killall|hermes pause|osascript|auth\.json|AXIsProcessTrusted' -g 'Voice*.swift' -g 'NotchPillView+Voice.swift' Sources/DesnotchCore/UI
rg -n 'accessibilityAction|textCase' Sources/DesnotchCore/UI/VoiceSectionView.swift Sources/DesnotchCore/UI/VoiceSettingsSection.swift Sources/DesnotchCore/UI/NotchPillView+Voice.swift
# accessibility structure (2.3): the buttons must stay separate elements. First command prints nothing, second prints exactly 1
rg -n '\.combine\b|\.ignore\b' Sources/DesnotchCore/UI/VoiceSectionView.swift
rg -c 'accessibilityElement\(children: \.contain\)' Sources/DesnotchCore/UI/VoiceSectionView.swift
# a stale privacy statement (2.8): must print nothing
rg -n 'only network request' Sources/DesnotchCore/App/SettingsView.swift
git diff origin/main -- Sources | rg '^\+.*(\bprint\(|\bNSLog\(|\bos_log|\bLogger\()'     # also covers the existing UI/App files you changed
```

Done means: build clean; the warning check of this section prints nothing; the full suite has no failures beyond the two documented baseline ones; every class in section 3 exists and passes; lint clean; `git status` shows changes only in the files of 2.2.

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

Additional UI rules: tokens only (no raw durations/curves/fonts in views), minimum 10pt, 8pt grid spacing from `PillSpace`, WCAG AA contrast through `PillPalette`, every interactive element has a VoiceOver label and `pillFocusRing`,
Reduce Motion / Reduce Transparency / Increase Contrast honored through the existing environment values, no new `PreferenceKey`, no second size callback, no broad `.animation` on a root view.

## 6. DO NOT

- Do NOT use `.onHover` or `repeatForever` anywhere (CI test `PillSourceGuardTests` fails). Do NOT add a second hover source. **No COMMENT in a voice UI file may contain a banned token** (`.onHover`, `repeatForever`, `print(`, `NSLog(`, `os_log`, `Logger(`, `pkill`, `killall`, `osascript`, `auth.json`, `AXIsProcessTrusted`), and none in `VoiceSectionView.swift` may contain `.combine` or `.ignore`; none in `VoiceSectionView.swift`, `VoiceSettingsSection.swift` or `NotchPillView+Voice.swift` may contain `accessibilityAction` or `textCase`. The orchestrator's `rg` passes over `Voice*.swift` and `NotchPillView+Voice.swift` also match comments, unlike `PillSourceGuardTests`, which skips `//` lines. Explain a ban in words ("no hover modifier", "children stay separate elements", "no uppercase modifier") instead.
- Do NOT apply `.textCase(...)` or call `sectionHeader()` in a voice view (it uppercases text; a transcript must keep its case). Do NOT add `accessibilityAction` to `VoiceSectionView.swift` (the orchestrator's `rg` checks it: no accessibility shortcut may approve).
- Do NOT make the panel key window, and do NOT add anything that takes keyboard focus from the frontmost app.
- Do NOT edit any `Voice/Contracts/*` file, `SettingsStore.swift`, `SettingsTransfer.swift`, `AppComposition.swift`, `AppDelegate.swift`, `Package.swift`, scripts, `AGENTS.md`, or anything under `Voice/Logic`, `Voice/Platform`, `Voice/Hermes`, `Voice/Coordinator`.
- Do NOT call the recognizer, agent, audit log or any executor. Do NOT import `Speech`, `AVFoundation` (except what `NSSound` needs from AppKit).
- Do NOT show or announce a transcript, reply, command text or file path outside `privacyRedacted`; do NOT put them in the status menu.
- Do NOT add spoken/typed approval ("say yes"). Do NOT add "always allow" or "allow for session" anywhere.
- Do NOT add a setting, a defaults key or a settings-export field (the contract already has all of them).
- Do NOT run `git add/commit/push/...`.
