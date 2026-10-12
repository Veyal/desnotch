import Foundation

// MARK: - Contract file (frozen, see VoiceTypes.swift)
//
// The seams between work packages. Every protocol has an honest "unavailable" stub in
// `VoiceStubs.swift` that fails closed with a typed `VoiceFailure`; none of them fakes success.
// Swift 5.10 note: anything that touches AppKit, SettingsStore or a controller is
// `@MainActor`; everything else is `Sendable` and implemented with explicit isolation.

/// Time source. (Named `VoiceClock`: `Clock` already exists in the Swift standard library.)
protocol VoiceClock: Sendable {
    func now() -> Date
}

struct SystemVoiceClock: VoiceClock {
    func now() -> Date { Date() }
}

/// Microphone capture plus on-device recognition behind one seam. Audio lives in memory only
/// and never leaves the process. Implemented by `AppleSpeechRecognizer` (WP-PLATFORM).
///
/// Contract:
/// - `start` begins capture immediately and returns the event stream for this capture.
///   Order: `.captureStarted` (first buffer), any number of `.level`/`.partial`, then exactly
///   one `.final` (or one `.failed`), then the stream finishes.
/// - `endAudio` is the user ending the capture: flush buffered audio and finalize.
/// - `cancel` discards everything: the stream finishes without a `.final`.
/// - Calling `start` while a capture is active cancels the old capture first.
protocol SpeechRecognizing: Sendable {
    func start(localeIdentifier: String, contextualStrings: [String]) -> AsyncStream<SpeechEvent>
    func endAudio()
    func cancel()
}

/// Spoken replies. `speak` returns true when the utterance finished, false when it was
/// stopped or could not start. Implemented by `AppleSpeechSynthesizer` (WP-PLATFORM).
protocol SpeechSynthesizing: Sendable {
    func speak(_ text: String, localeIdentifier: String) async -> Bool
    func stop()
}

/// Runs the fixed local verbs. Never throws; failures are typed results. Main-actor because it
/// drives `FocusTimerController`, `NowPlayingController` and `NSWorkspace`.
/// Implemented by `SystemLocalExecutor` (WP-PLATFORM).
@MainActor
protocol LocalExecuting: AnyObject {
    func execute(_ intent: LocalIntent) async -> LocalExecutionResult
}

/// The agent executor behind the Hermes lane. One implementation (`HermesAgentBackend`,
/// WP-HERMES) plus `NullBackend`.
protocol AgentBackend: Sendable {
    var id: String { get }
    /// Run on every process spawn and every new session, not once. The Hermes lane stays
    /// refused until this returns `.ready`.
    func preflight() async -> AgentPreflightResult
    /// Submit one utterance. The stream ends with `.finished` or `.failed`.
    func submit(_ utterance: String) -> AsyncStream<AgentEvent>
    /// Answer an approval request. `allow == true` is sent as `once`; `false` as `deny`.
    func respond(nonce: String, allow: Bool) async
    /// Soft cancel of the current turn (`session/cancel`). An agent that ignores it is killed
    /// after `VoiceTiming.hardStopGrace` by the backend itself, and a later submit first
    /// completes that kill (WP-HERMES B.7).
    func cancelTurn() async
    /// Interrupt, wait `VoiceTiming.hardStopGrace`, SIGTERM then SIGKILL the process group.
    func emergencyStop() async -> EmergencyStopReport
    func shutdown() async
}

/// Append-only, hash-chained, metadata-only audit log. Implemented by `FileAuditLogger`
/// (WP-PLATFORM).
protocol AuditLogging: Sendable {
    /// Returns false when the record could not be durably appended. The coordinator refuses
    /// T2+ actions while the log is unwritable.
    @discardableResult
    func append(_ draft: AuditDraft) async -> Bool
    func verify() async -> AuditVerification
}

/// Minimal file seam so the audit logger is testable without the disk.
protocol FileWriting: Sendable {
    func ensureDirectory(_ url: URL) throws
    func appendLine(_ line: String, to url: URL) throws
    /// An absent file reads as an empty array.
    func readLines(from url: URL) throws -> [String]
    /// 0600 for files, 0700 for directories.
    func restrictToOwner(_ url: URL) throws
    /// Size in bytes; 0 for an absent file.
    func fileSize(_ url: URL) throws -> Int
    /// Replaces `destination` if it exists.
    func moveItem(at source: URL, to destination: URL) throws
}

/// Global push-to-talk and key commands. Implemented by `CarbonPushToTalk` (WP-PLATFORM).
/// The stream yields `.pressed` / `.released(heldSeconds:)` for the talk key, `.stopKey` for
/// the always-registered stop chord, and `.cancelKey` (Esc) only while armed.
/// A source may be SINGLE-USE (`CarbonPushToTalk` is): `start()` after `stop()` can return
/// `.unavailable`, so the coordinator builds a new source on every enable.
@MainActor
protocol PushToTalkSource: AnyObject {
    var events: AsyncStream<PushToTalkEvent> { get }
    func start() -> PushToTalkStatus
    func stop()
    /// Registers Esc globally while true, unregisters it while false (it must not be stolen
    /// from other apps at idle).
    func setCancelKeyArmed(_ armed: Bool)
}

/// Screen lock / console-session gate. Unknown state counts as locked (fail closed).
@MainActor
protocol LockStateProviding: AnyObject {
    /// Recomputed from the system on every read (no cached answer), so it is correct even when
    /// no `changes` stream exists.
    var isLocked: Bool { get }
    /// Emits the new value on every change. Each access returns a NEW stream; the monitor
    /// listens for notifications only while at least one stream is alive.
    var changes: AsyncStream<Bool> { get }
}

/// Lowers other audio while the mic is open. Restores only if the user did not change the
/// volume meanwhile.
@MainActor
protocol MediaDucking: AnyObject {
    func duck()
    func restore()
}

/// Non-prompting status plus an explicit request. The request is made only after the user
/// enables voice in Settings.
@MainActor
protocol VoicePermissionProviding: AnyObject {
    func status() -> VoicePermissionStatus
    func request() async -> VoicePermissionStatus
}

/// Plays the short sound and haptic cues the reducer asks for (`VoiceEffect.cue`). Implemented
/// by `VoiceCuePlayer` (WP-UI); the coordinator (WP-HERMES) calls it.
@MainActor
protocol VoiceCuePlaying: AnyObject {
    func play(_ cue: VoiceCue)
}
