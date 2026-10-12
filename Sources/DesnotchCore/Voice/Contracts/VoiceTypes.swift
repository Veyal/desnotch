import Foundation

// MARK: - Contract file
//
// FROZEN after the "feat(voice): plan and contracts" commit. Work packages implement and
// consume these types; they do not edit them. A needed change goes back to the plan owner as
// a contract amendment (see docs/voice/PLAN.md, "Contract amendments"). Everything here is
// pure data: no I/O, no AppKit, no clocks. Swift 5.10 note: every type is `Sendable`.

// MARK: - Tiers and lanes

/// Risk tier of an action. Higher is more dangerous. Unknown things default to `.t3`
/// (default-deny); see `ConfirmationPolicy` and `ToolTierTable` (WP-LOGIC).
enum VoiceTier: Int, CaseIterable, Comparable, Sendable, Codable {
    /// Read-only, media, open app, timers: runs after the cancel window.
    case t0 = 0
    /// Reversible agent work inside the allowlisted toolset: window plus rate limit.
    case t1
    /// Destructive or surprising: visual approval card.
    case t2
    /// Network egress, sends: card plus a second factor (unavailable in the MVP, so denied).
    case t3
    /// Credentials, engagement data, sudo, evidence writes: denied, no voice path.
    case t4

    static func < (lhs: VoiceTier, rhs: VoiceTier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// "T0" ... "T4".
    var label: String { "T\(rawValue)" }
}

/// Which executor handles a command. `.hermes` always means cloud-routed model traffic.
enum VoiceLane: String, Sendable, Codable, Equatable {
    case local
    case hermes
}

/// How the current capture was started and is ended.
enum CaptureMode: String, Sendable, Equatable {
    /// Push-to-talk: the key is held; its release ends the capture.
    case hold
    /// Latched: a tap started it; a second tap, the cap timer or Cancel ends it.
    case toggle
}

// MARK: - Session state machine vocabulary

/// The foreground phase of a voice session. Exactly one at a time.
/// The full transition table is in docs/voice/PLAN.md and docs/voice/WP-LOGIC.md.
enum VoiceState: String, CaseIterable, Sendable, Equatable {
    /// Nothing runs: no mic, no timers.
    case idle
    /// Key is down; waiting for the first audio buffer.
    case armed
    /// Mic is open; partial transcript streams in.
    case listening
    /// The user ended the capture; waiting for the recognizer's final text.
    case transcribing
    /// "heard: ..., sending in 1.5 s". Esc cancels. Nothing leaves the Mac before this elapses.
    case review
    /// Hermes lane: submitted, no tool activity yet.
    case thinking
    /// A local action is running, or the agent is using tools.
    case acting
    /// An approval card is showing (local T2, or an agent request).
    case awaitingApproval
    /// Showing (and optionally speaking) the reply.
    case speaking
    /// A failure is on screen for a few seconds.
    case error
    /// The agent was hard-stopped (Stop, tripwire). Needs an explicit Resume.
    case paused

    /// Phases in which a Hermes turn is in flight.
    var isAgentBusy: Bool { self == .thinking || self == .acting || self == .awaitingApproval }
}

/// Timers the reducer asks the coordinator to run. The matching event is
/// `VoiceEvent.timerElapsed(kind, generation:)`.
enum VoiceTimerKind: String, Sendable, Equatable, CaseIterable {
    case listenCap, finalWatchdog, review, approval, errorDisplay, replyDisplay, turnBudget
}

/// Short sound/haptic cues. The UI/coordinator decides how to render them.
enum VoiceCue: String, Sendable, Equatable, CaseIterable {
    case captureStart, captureEnd, commit, needsConfirmation, approved, done, error
}

/// A tool-activity chip. `kind` is a category label, never raw tool arguments.
struct VoiceStep: Equatable, Sendable, Identifiable {
    let id: Int
    let kind: String
}

enum PauseReason: Equatable, Sendable {
    case userStop
    case spokenAbort
    case tripwire(String)
}

/// A second, independent push-to-talk capture used only while an agent turn is busy, so the
/// user can say "abort agent" or "stop". Its transcript is honored only for those phrases.
struct InterruptCapture: Equatable, Sendable {
    var generation: Int
    var endedByUser: Bool
}

/// Everything the reducer remembers. Pure value; the coordinator owns the single instance.
struct VoiceContext: Equatable, Sendable {
    var state: VoiceState = .idle
    /// Monotonic id allocator. Every new flow/interrupt takes `counter += 1`.
    var counter = 0
    /// Id of the current flow; async events carry it and stale ones are dropped.
    var generation = 0
    var captureMode: CaptureMode = .hold
    /// True only when a user action (key release, toggle tap) ended the capture. A Hermes
    /// submission requires it; a cap-timer or recognizer-initiated end never submits.
    var captureEndedByUser = false
    var lane: VoiceLane?
    var partialTranscript = ""
    var finalTranscript = ""
    var route: RouteDecision?
    var pending: ConfirmationRequest?
    /// The local T2 intent behind `pending`, when the card is for a local action.
    var pendingIntent: LocalIntent?
    var failure: VoiceFailure?
    var pauseReason: PauseReason?
    /// Reply text for `.speaking` (bounded by `VoiceLimits.maxReplyCharacters`).
    var reply = ""
    var steps: [VoiceStep] = []
    var stepsStarted = 0
    /// Approvals the user granted whose tool start has not been seen yet (tripwire accounting).
    var approvedToolStarts = 0
    var interrupt: InterruptCapture?
    var rate = RateLimiter()

    init() {}
}

/// Inputs that are not events: facts the coordinator knows at the moment of the call.
struct VoiceReducerEnv: Equatable, Sendable {
    var now: Date
    var voiceEnabled: Bool
    var screenLocked: Bool
    /// Hermes lane setting is on AND the preflight passed.
    var hermesLaneReady: Bool
    var hermesTurnsRemainingToday: Int
    /// TTS setting on, privacy mode off. When false replies are shown, not spoken.
    var speechAllowed: Bool
    /// False in the MVP; T3 is denied while false.
    var secondFactorAvailable: Bool
    /// A fresh unique string on every call (the coordinator uses a UUID). Used for nonces.
    var freshNonce: String

    init(
        now: Date,
        voiceEnabled: Bool = true,
        screenLocked: Bool = false,
        hermesLaneReady: Bool = false,
        hermesTurnsRemainingToday: Int = VoiceLimits.hermesTurnsPerDay,
        speechAllowed: Bool = false,
        secondFactorAvailable: Bool = false,
        freshNonce: String = "nonce-0"
    ) {
        self.now = now
        self.voiceEnabled = voiceEnabled
        self.screenLocked = screenLocked
        self.hermesLaneReady = hermesLaneReady
        self.hermesTurnsRemainingToday = hermesTurnsRemainingToday
        self.speechAllowed = speechAllowed
        self.secondFactorAvailable = secondFactorAvailable
        self.freshNonce = freshNonce
    }
}

/// Everything that can happen. Events from async sources carry the `generation` that was
/// current when the work was started (the id given in the matching `VoiceEffect`).
enum VoiceEvent: Equatable, Sendable {
    // User and system input
    case talkPressed
    case talkReleased(heldSeconds: Double)
    case toggleTalk
    /// Esc, the pill's Cancel, the status-menu Cancel, `VoiceSessionModel.cancelReview()`.
    case cancelRequested
    /// Stop button, global stop chord, status-menu Stop, `VoiceSessionModel.stopAll()`.
    case stopAllRequested
    case resumeRequested
    case approveRequested(nonce: String)
    case denyRequested(nonce: String)
    case screenLocked
    /// The `voiceEnabled` setting turned off.
    case featureDisabled

    // Capture and recognition
    case captureStarted(generation: Int)
    /// Covers capture-device and recognizer failures alike.
    case captureFailed(VoiceFailure, generation: Int)
    case partialTranscript(String, generation: Int)
    case finalTranscript(String, generation: Int)

    // Timers, execution, speech, agent
    case timerElapsed(VoiceTimerKind, generation: Int)
    case localExecutionFinished(LocalExecutionResult, generation: Int)
    case speechFinished(generation: Int)
    case agent(AgentEvent, generation: Int)
}

/// Things the reducer asks the coordinator to do. The reducer never performs I/O.
enum VoiceEffect: Equatable, Sendable {
    case startCapture(generation: Int, mode: CaptureMode)
    /// Flush audio and let the recognizer finalize (user ended the capture).
    case endCapture(generation: Int)
    /// Discard everything; no final transcript will follow.
    case cancelCapture(generation: Int)
    case startTimer(VoiceTimerKind, generation: Int, seconds: Double)
    case cue(VoiceCue)
    case execute(LocalIntent, generation: Int)
    case submitToAgent(utterance: String, generation: Int)
    /// Only `once` (allow) or `deny` is ever sent; never session/always.
    case respondToApproval(nonce: String, allow: Bool)
    /// Soft cancel of the current agent turn (no process kill).
    case cancelAgentTurn
    /// Interrupt, wait, then SIGTERM/SIGKILL the agent's process group. Reports survivors.
    case stopAgentHard
    case speak(String, generation: Int)
    case stopSpeaking
    case audit(AuditDraft)
}

/// Result of one reducer step.
struct VoiceTransition: Equatable, Sendable {
    var context: VoiceContext
    var effects: [VoiceEffect]

    init(context: VoiceContext, effects: [VoiceEffect] = []) {
        self.context = context
        self.effects = effects
    }
}

// MARK: - Routing

/// The closed set of things the local lane can do (MVP). No shell, no URLs, no quit/kill/delete.
enum LocalIntent: Equatable, Sendable {
    case mediaPlay
    case mediaPause
    case mediaNext
    case mediaPrevious
    /// Absolute volume, 0...100.
    case volumeSet(percent: Int)
    /// Relative volume in percentage points (+-10, or +-5 for "a bit").
    case volumeStep(delta: Int)
    case mute
    case unmute
    /// `bundleID` comes from the fixed `AppCatalog` table, never from the transcript.
    case openApp(bundleID: String, name: String)
    case timerStart(minutes: Int)
    case timerCancel

    /// Stable machine label for audit records (no arguments, nothing user-authored).
    var kind: String {
        switch self {
        case .mediaPlay: return "media.play"
        case .mediaPause: return "media.pause"
        case .mediaNext: return "media.next"
        case .mediaPrevious: return "media.previous"
        case .volumeSet: return "volume.set"
        case .volumeStep: return "volume.step"
        case .mute: return "volume.mute"
        case .unmute: return "volume.unmute"
        case .openApp: return "app.open"
        case .timerStart: return "timer.start"
        case .timerCancel: return "timer.cancel"
        }
    }

    /// Short desnotch-authored description shown in the review banner and on cards.
    var summary: String {
        switch self {
        case .mediaPlay: return "Play"
        case .mediaPause: return "Pause"
        case .mediaNext: return "Next track"
        case .mediaPrevious: return "Previous track"
        case .volumeSet(let percent): return "Set volume to \(percent)%"
        case .volumeStep(let delta): return delta >= 0 ? "Volume up \(delta)" : "Volume down \(-delta)"
        case .mute: return "Mute"
        case .unmute: return "Unmute"
        case .openApp(_, let name): return "Open \(name)"
        case .timerStart(let minutes): return "Timer \(minutes) min"
        case .timerCancel: return "Cancel timer"
        }
    }
}

/// What the router decided. Produced by `IntentRouter.route` (WP-LOGIC).
enum RouteDecision: Equatable, Sendable {
    case local(LocalIntent)
    /// Not a local command: goes to the Hermes lane. Carries the transcript text unmodified.
    case remote(utterance: String)
    /// The spoken emergency phrase ("abort agent"). Handled locally at any time.
    case emergencyStop
    /// Bare "stop"/"cancel" while an agent turn is busy: soft-cancel the turn.
    case cancelTurn
    case reject(RejectReason)
}

enum RejectReason: String, CaseIterable, Sendable, Equatable {
    case emptyUtterance
    case tooLong
    case notLocalCommand
    case ambiguous
    case unknownApp
    case invalidArgument
    /// Hermes submission attempted although the capture was not ended by the user.
    case needsUserRelease
    case hermesLaneUnavailable
    case notImplemented
}

/// Context the router needs besides the text.
struct RouterContext: Equatable, Sendable {
    /// True when a miss may be sent to Hermes (setting on, preflight passed).
    var hermesLaneAvailable: Bool
    /// True while an agent turn is thinking/acting/awaiting approval.
    var agentBusy: Bool

    init(hermesLaneAvailable: Bool = false, agentBusy: Bool = false) {
        self.hermesLaneAvailable = hermesLaneAvailable
        self.agentBusy = agentBusy
    }
}

// MARK: - Policy and confirmations

enum PolicyDecision: Equatable, Sendable {
    /// Runs after the review/cancel window. T0 and T1.
    case allow
    /// Needs a visual approval card. T2.
    case confirm
    case deny(DenyReason)
}

enum DenyReason: String, CaseIterable, Sendable, Equatable {
    case tierT4
    case secondFactorUnavailable
    case flaggedConstruct
    case protectedPath
    case unknownTool
    case notImplemented
}

/// Flags found by `CommandRiskScanner` in a command string shown on a card.
struct RiskFlags: OptionSet, Sendable, Equatable {
    let rawValue: Int
    static let pipeToInterpreter = RiskFlags(rawValue: 1 << 0)
    static let base64Decode = RiskFlags(rawValue: 1 << 1)
    static let evalUse = RiskFlags(rawValue: 1 << 2)
    static let commandSubstitution = RiskFlags(rawValue: 1 << 3)
    static let hiddenCharacters = RiskFlags(rawValue: 1 << 4)
    static let sudo = RiskFlags(rawValue: 1 << 5)
    static let protectedPath = RiskFlags(rawValue: 1 << 6)
    static let chaining = RiskFlags(rawValue: 1 << 7)
    static let pipe = RiskFlags(rawValue: 1 << 8)
    static let redirect = RiskFlags(rawValue: 1 << 9)
    static let url = RiskFlags(rawValue: 1 << 10)
    static let destructive = RiskFlags(rawValue: 1 << 11)
    /// Set by the stub scanner: nothing was actually scanned.
    static let unscanned = RiskFlags(rawValue: 1 << 12)

    /// Flags that are refused outright: no card, no approval possible.
    static let autoDeny: RiskFlags = [
        .pipeToInterpreter, .base64Decode, .evalUse, .commandSubstitution,
        .hiddenCharacters, .sudo, .protectedPath, .unscanned
    ]
}

/// Result of scanning a literal command string (WP-LOGIC).
struct CommandRisk: Equatable, Sendable {
    var flags: RiskFlags
    /// Text safe to display: control, bidi and zero-width characters removed.
    var sanitized: String
    /// True when `sanitized` was cut at the display limit. Approve stays disabled.
    var wasTruncated: Bool
    var tier: VoiceTier

    var isAutoDeny: Bool { !flags.intersection(.autoDeny).isEmpty }
}

/// An approval card. `literal` is the exact text the user is approving.
/// For local actions it is authored by desnotch; for agent requests it is model-authored and
/// has been through `CommandRiskScanner`, so the card also shows the risk flags.
struct ConfirmationRequest: Equatable, Sendable, Identifiable {
    var nonce: String
    var tier: VoiceTier
    var source: VoiceLane
    var summary: String
    var literal: String
    var risk: RiskFlags
    var isTruncated: Bool
    var requiresSecondFactor: Bool

    var id: String { nonce }

    /// The UI disables Approve when this is false.
    var canApprove: Bool {
        !isTruncated && !requiresSecondFactor && risk.intersection(.autoDeny).isEmpty && tier < .t3
    }

    init(
        nonce: String,
        tier: VoiceTier,
        source: VoiceLane,
        summary: String,
        literal: String,
        risk: RiskFlags = [],
        isTruncated: Bool = false,
        requiresSecondFactor: Bool = false
    ) {
        self.nonce = nonce
        self.tier = tier
        self.source = source
        self.summary = summary
        self.literal = literal
        self.risk = risk
        self.isTruncated = isTruncated
        self.requiresSecondFactor = requiresSecondFactor
    }
}

/// The user's answer to a card, bound to its nonce.
enum ConfirmationDecision: Equatable, Sendable {
    case approved(nonce: String)
    case denied(nonce: String)
    case expired(nonce: String)
}

// MARK: - Agent backend vocabulary

/// Events from an `AgentBackend` for one submitted utterance. No raw tool arguments, ever.
enum AgentEvent: Equatable, Sendable {
    /// Short status label, redactable.
    case status(String)
    /// Streamed reply text (bounded by the consumer).
    case partial(String)
    /// A tool started. `kind` is a category label that is classified by `ToolTierTable`.
    case toolActivity(kind: String)
    case approvalNeeded(ConfirmationRequest)
    case finished(summary: String)
    case failed(VoiceFailure)
    /// Metadata only: feeds the audit counters.
    case usage(inputTokens: Int, outputTokens: Int, costMicros: Int)
}

enum PreflightFailure: String, CaseIterable, Sendable, Equatable {
    case binaryMissing
    case profileMissing
    case approvalsOff
    case allowlistNotEmpty
    case toolsetOutsideAllowlist
    case configNotLocked
    case mcpConfigured
    case protocolMismatch
    case notImplemented
}

enum AgentPreflightResult: Equatable, Sendable {
    case ready(profile: String)
    case refused(PreflightFailure)
}

/// Outcome of a hard stop.
struct EmergencyStopReport: Equatable, Sendable {
    /// Basenames of processes still alive after SIGKILL. Empty when the stop was total.
    var survivors: [String]

    init(survivors: [String] = []) {
        self.survivors = survivors
    }
}

// MARK: - Speech, execution, permissions

enum SpeechEvent: Equatable, Sendable {
    /// The first audio buffer arrived. The earcon plays now, not on key-down.
    case captureStarted
    /// 0...1, already throttled to `VoiceLimits.meterMaxHz`.
    case level(Float)
    case partial(String)
    /// Exactly one final per capture, then the stream finishes.
    case final(String)
    case failed(VoiceFailure)
}

enum LocalExecutionResult: Equatable, Sendable {
    /// `spoken` is a short confirmation ("Volume 30") or nil for silent success.
    case success(spoken: String?)
    case failure(VoiceFailure)
}

enum VoicePermissionKind: String, Sendable, Equatable {
    case microphone
    case speech
}

enum VoicePermissionState: String, Sendable, Equatable {
    case notDetermined, denied, restricted, authorized, unknown
}

struct VoicePermissionStatus: Equatable, Sendable {
    var microphone: VoicePermissionState
    var speech: VoicePermissionState

    var isReady: Bool { microphone == .authorized && speech == .authorized }

    static let unknown = VoicePermissionStatus(microphone: .unknown, speech: .unknown)
}

enum HermesLaneStatus: Equatable, Sendable {
    case off
    case checking
    case ready
    case refused(PreflightFailure)
}

// MARK: - Push-to-talk and key commands

enum PushToTalkEvent: Equatable, Sendable {
    case pressed
    /// `heldSeconds` is measured by the source from press to release.
    case released(heldSeconds: Double)
    /// Esc while the cancel key is armed.
    case cancelKey
    /// The always-registered global stop chord.
    case stopKey
}

enum PushToTalkStatus: Equatable, Sendable {
    case active
    /// The talk key or the Stop chord could not be registered (another app owns it) or the source is a stub.
    case unavailable
}

// MARK: - Audit

enum AuditKind: String, Codable, Sendable, CaseIterable {
    case route, submit, execute, approval, denial, cancel, stop, tripwire
    case preflight, cost, error, lock, resume
}

/// What the reducer/coordinator hands to an `AuditLogging` implementation. `transcript` exists
/// only so the logger can hash it; it is never persisted.
struct AuditDraft: Equatable, Sendable {
    var kind: AuditKind
    var lane: VoiceLane?
    var tier: VoiceTier?
    var decision: String?
    var outcome: String?
    var transcript: String?
    var counters: [String: Int]

    init(
        kind: AuditKind,
        lane: VoiceLane? = nil,
        tier: VoiceTier? = nil,
        decision: String? = nil,
        outcome: String? = nil,
        transcript: String? = nil,
        counters: [String: Int] = [:]
    ) {
        self.kind = kind
        self.lane = lane
        self.tier = tier
        self.decision = decision
        self.outcome = outcome
        self.transcript = transcript
        self.counters = counters
    }
}

/// One persisted line of the hash-chained audit log. Metadata only: no audio, no utterance
/// text, no command text. `hash = SHA-256(canonical fields + prevHash)`; see WP-PLATFORM.
struct AuditRecord: Equatable, Codable, Sendable {
    var seq: Int
    /// ISO-8601 UTC, e.g. 2026-10-12T20:25:00Z.
    var timestamp: String
    var kind: AuditKind
    var lane: VoiceLane?
    var tier: Int?
    var decision: String?
    var outcome: String?
    /// SHA-256 hex of the normalized transcript, or nil.
    var transcriptHash: String?
    var counters: [String: Int]
    var prevHash: String
    var hash: String
}

struct AuditVerification: Equatable, Sendable {
    var isValid: Bool
    var recordCount: Int
    /// 1-based sequence number of the first broken record, if any.
    var firstBrokenSeq: Int?
    /// Hash of the last good record; the value to anchor externally.
    var headHash: String

    static let empty = AuditVerification(isValid: true, recordCount: 0, firstBrokenSeq: nil, headHash: "")
}

// MARK: - Failures

enum UnavailableReason: String, Sendable, Equatable {
    case notImplemented
    case recognizer
    case synthesizer
    case executor
    case backend
    case lockState
    case fileWriter
    case pushToTalk
}

/// Every way a voice flow can fail. `userMessage` is generic, short and secret-free; the UI
/// still routes it through the privacy-mode redaction boundary.
enum VoiceFailure: Error, Equatable, Sendable {
    case unavailable(UnavailableReason)
    case permissionDenied(VoicePermissionKind)
    case noSpeech
    case screenLocked
    case rejected(RejectReason)
    case denied(DenyReason)
    case rateLimited
    case dailyCapReached
    case timeout
    case stepBudgetExceeded
    /// An unclassified or too-dangerous tool started. `tool` is a bounded category label.
    case tripwire(tool: String)
    case preflightRefused(PreflightFailure)
    /// Short reason code, never raw output.
    case executionFailed(String)
    case agentFailed(String)

    enum Severity: Equatable, Sendable {
        /// Normal outcome of a bad utterance; styled calmly.
        case info
        case warning
        /// Safety event; styled as an alarm.
        case alert
    }

    var severity: Severity {
        switch self {
        case .noSpeech, .rejected: return .info
        case .tripwire, .denied: return .alert
        default: return .warning
        }
    }

    /// Stable machine label for audit records. Carries the failure category only, never
    /// payload text (tool names, reason strings) that could be user- or model-authored.
    var code: String {
        switch self {
        case .unavailable(let reason): return "unavailable.\(reason.rawValue)"
        case .permissionDenied(let kind): return "permission.\(kind.rawValue)"
        case .noSpeech: return "no_speech"
        case .screenLocked: return "locked"
        case .rejected(let reason): return "rejected.\(reason.rawValue)"
        case .denied(let reason): return "denied.\(reason.rawValue)"
        case .rateLimited: return "rate_limited"
        case .dailyCapReached: return "daily_cap"
        case .timeout: return "timeout"
        case .stepBudgetExceeded: return "step_budget"
        case .tripwire: return "tripwire"
        case .preflightRefused(let failure): return "preflight.\(failure.rawValue)"
        case .executionFailed: return "execution_failed"
        case .agentFailed: return "agent_failed"
        }
    }

    var userMessage: String {
        switch self {
        case .unavailable: return "Voice isn't available"
        case .permissionDenied(.microphone): return "Microphone access needed"
        case .permissionDenied(.speech): return "Speech recognition access needed"
        case .noSpeech: return "Didn't catch that"
        case .screenLocked: return "Screen is locked"
        case .rejected(let reason):
            switch reason {
            case .emptyUtterance: return "Didn't catch that"
            case .tooLong: return "That was too long"
            case .notLocalCommand: return "Not a local command"
            case .ambiguous: return "Be more specific"
            case .unknownApp: return "Unknown app"
            case .invalidArgument: return "Couldn't use that value"
            case .needsUserRelease: return "Release the key to send"
            case .hermesLaneUnavailable: return "Agent lane is off"
            case .notImplemented: return "Voice isn't available"
            }
        case .denied: return "Blocked by safety policy"
        case .rateLimited: return "Too many commands, wait a moment"
        case .dailyCapReached: return "Daily agent limit reached"
        case .timeout: return "Timed out"
        case .stepBudgetExceeded: return "Agent used too many steps"
        case .tripwire: return "Agent stopped: unapproved tool"
        case .preflightRefused: return "Agent lane refused: profile check failed"
        case .executionFailed: return "Couldn't do that"
        case .agentFailed: return "Agent error"
        }
    }
}

// MARK: - Constants

/// Timing constants, seconds. One place so tests and docs agree.
enum VoiceTiming {
    /// A key press shorter than this is a tap (latches toggle mode), not a hold.
    static let holdThreshold = 0.35
    /// "heard: ..., sending in 1.5 s".
    static let reviewWindow = 1.5
    static let holdListenCap = 30.0
    static let toggleListenCap = 10.0
    /// After the user ends a capture, how long to wait for the recognizer's final text.
    static let finalWatchdog = 5.0
    static let approvalTimeout = 60.0
    static let errorDisplay = 3.0
    static let replyDisplay = 6.0
    /// Wall-clock budget for one agent turn.
    static let agentTurnBudget = 180.0
    /// Wait between interrupt and SIGTERM, and between SIGTERM and SIGKILL, in a hard stop.
    static let hardStopGrace = 0.5
}

/// Size and rate limits.
enum VoiceLimits {
    static let maxUtteranceCharacters = 500
    static let maxTranscriptDisplayCharacters = 500
    static let maxReplyCharacters = 400
    static let maxAgentSteps = 12
    /// Absolute volume above this needs an approval card (a misheard "ten" as "a hundred").
    static let volumeConfirmAbove = 70
    static let volumeStep = 10
    static let volumeStepSmall = 5
    static let timerMinutesRange = 1...120
    static let hermesTurnsPerDay = 40
    static let visibleStepChips = 3
    static let meterBars = 5
    static let meterMaxHz = 15.0
    /// Rate limits (sliding windows).
    static let t1PerMinute = 10
    static let t2PerTenMinutes = 3
}

/// Terms passed to the recognizer as `contextualStrings`. Fixed, no engagement names.
enum VoiceLexicon {
    static let contextualStrings = ["herdr", "Interseptor", "desnotch", "nmap"]
}
