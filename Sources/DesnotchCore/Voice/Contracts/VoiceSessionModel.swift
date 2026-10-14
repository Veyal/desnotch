import Combine
import Foundation

// MARK: - Contract file (frozen, see VoiceTypes.swift)

/// The closures the UI's actions call. The coordinator (WP-HERMES, part A) installs them; until
/// then they are nil and the actions are no-ops. A struct of closures keeps the model free of
/// any dependency on the coordinator.
@MainActor
struct VoiceSessionActions {
    var stopAll: (() -> Void)?
    var resume: (() -> Void)?
    var approve: ((String) -> Void)?
    var deny: ((String) -> Void)?
    var cancelReview: (() -> Void)?
    var toggleTalk: (() -> Void)?
    /// Debug-only text entry (`DESNOTCH_VOICE_DEBUG=1`): runs a typed line through the same
    /// pipeline as a final transcript, bypassing mic and recognizer.
    var submitTyped: ((String) -> Void)?
    var requestPermissions: (() -> Void)?
    /// Amendment (opt-in AI provider): re-runs the agent-lane check after Settings saved or
    /// removed a provider key (the Keychain has no change notification).
    var refreshAgentLane: (() -> Void)?

    init() {}
}

/// The one object the pill, the status menu and Settings bind to. It holds presentation state
/// only; it never makes decisions. The coordinator writes it through `apply(...)`,
/// `setLevels`, `setPermissions`, `setHermesLaneStatus`, `setHotkeyStatus` and `setSurvivors`; the UI reads the
/// published fields and calls the action methods.
///
/// Privacy: `partialTranscript`, `finalTranscript`, `reply` and `pendingConfirmation.literal`
/// are live content. The UI must show them only through the privacy-mode redaction boundary and
/// must never announce them to VoiceOver or log them.
@MainActor
public final class VoiceSessionModel: ObservableObject {
    // MARK: Published state (read by the UI)

    @Published private(set) var state: VoiceState = .idle
    /// `VoiceLimits.meterBars` values in 0...1. Empty when not listening.
    @Published private(set) var levels: [Float] = []
    @Published private(set) var partialTranscript = ""
    @Published private(set) var finalTranscript = ""
    /// When the review window ends (drives a determinate countdown); nil outside `.review`.
    @Published private(set) var reviewDeadline: Date?
    /// Tool chips, newest last. The UI shows at most `VoiceLimits.visibleStepChips`.
    @Published private(set) var steps: [VoiceStep] = []
    @Published private(set) var stepsStarted = 0
    @Published private(set) var pendingConfirmation: ConfirmationRequest?
    /// The lane of the current flow, nil when idle.
    @Published private(set) var lane: VoiceLane?
    /// What the pending route will do, written by desnotch (never by a model): the local
    /// intent's summary ("Set volume to 30%") or "Send to Hermes (cloud)". Nil without a route.
    @Published private(set) var routeSummary: String?
    /// Generic failure text for the current `.error`/`.paused` state, nil otherwise.
    @Published private(set) var errorText: String?
    @Published private(set) var errorSeverity: VoiceFailure.Severity = .info
    /// Reply text during `.speaking`.
    @Published private(set) var reply = ""
    /// True while the second, stop-only capture runs during a busy agent turn.
    @Published private(set) var interruptListening = false
    /// Processes that survived a hard stop (basenames), shown in the paused state.
    @Published private(set) var survivors: [String] = []
    @Published private(set) var permissions: VoicePermissionStatus = .unknown
    @Published private(set) var hermesLaneStatus: HermesLaneStatus = .off
    /// `.unavailable` when another app owns the push-to-talk combination (or voice is off).
    @Published private(set) var hotkeyStatus: PushToTalkStatus = .unavailable
    /// Amendment (opt-in AI provider): true while the current flow sends audio or text to the
    /// configured OpenAI-compatible endpoint outside the agent lane (cloud speech-to-text or the
    /// cloud reply voice). The coordinator clears it when the session returns to idle.
    @Published private(set) var cloudActivity = false
    /// Display name of the backend behind the agent lane: "Hermes" or "AI provider".
    @Published private(set) var agentName = VoiceSessionModel.hermesAgentName

    var actions = VoiceSessionActions()

    public init() {}

    // MARK: Derived (read by the UI)

    /// Hold-open input for `PillInteractionPolicy.wantsHover`: any session phase but idle.
    var isActive: Bool { state != .idle }
    var isPaused: Bool { state == .paused }
    /// The pill must show the "cloud" badge whenever the agent lane is involved, and whenever
    /// audio or text of this flow goes to the opt-in AI provider.
    var usesCloud: Bool { lane == .hermes || cloudActivity }
    /// True while the microphone is open for this app.
    var isCapturing: Bool {
        state == .armed || state == .listening || interruptListening
    }

    // MARK: Actions (called by the UI)

    /// Stop button, menu item, hotkey. Hard-stops the agent if one is running.
    func stopAll() { actions.stopAll?() }
    func resume() { actions.resume?() }
    func approve(nonce: String) { actions.approve?(nonce) }
    func deny(nonce: String) { actions.deny?(nonce) }
    /// Esc / Cancel during the review window (or any cancellable phase).
    func cancelReview() { actions.cancelReview?() }
    /// Tap-to-talk fallback (button or menu): starts a latched capture or ends the current one.
    func toggleTalk() { actions.toggleTalk?() }
    func submitTyped(_ text: String) { actions.submitTyped?(text) }
    func requestPermissions() { actions.requestPermissions?() }
    func refreshAgentLane() { actions.refreshAgentLane?() }

    // MARK: Writers (called by the coordinator, and by tests/previews)

    /// Publishes the presentation fields derived from a reducer context. Assigns only fields
    /// that changed, so an idle session publishes nothing.
    func apply(_ context: VoiceContext, reviewDeadline deadline: Date?) {
        assignIfChanged(&state, context.state)
        assignIfChanged(&partialTranscript, context.partialTranscript)
        assignIfChanged(&finalTranscript, context.finalTranscript)
        assignIfChanged(&reviewDeadline, deadline)
        assignIfChanged(&steps, context.steps)
        assignIfChanged(&stepsStarted, context.stepsStarted)
        assignIfChanged(&pendingConfirmation, context.pending)
        assignIfChanged(&lane, context.lane)
        assignIfChanged(&routeSummary, Self.summary(of: context.route, agentName: agentName))
        assignIfChanged(&reply, context.reply)
        assignIfChanged(&interruptListening, context.interrupt != nil)
        let failure = (context.state == .error || context.state == .paused) ? context.failure : nil
        assignIfChanged(&errorText, failure?.userMessage)
        assignIfChanged(&errorSeverity, failure?.severity ?? .info)
        if context.state != .listening && context.state != .armed && !levels.isEmpty && !interruptListening {
            levels = []
        }
        if context.state != .paused && !survivors.isEmpty { survivors = [] }
    }

    func setLevels(_ newLevels: [Float]) {
        let clipped = Array(newLevels.prefix(VoiceLimits.meterBars)).map { min(1, max(0, $0)) }
        assignIfChanged(&levels, clipped)
    }

    func setPermissions(_ status: VoicePermissionStatus) {
        assignIfChanged(&permissions, status)
    }

    func setHermesLaneStatus(_ status: HermesLaneStatus) {
        assignIfChanged(&hermesLaneStatus, status)
    }

    func setHotkeyStatus(_ status: PushToTalkStatus) {
        assignIfChanged(&hotkeyStatus, status)
    }

    func setSurvivors(_ names: [String]) {
        assignIfChanged(&survivors, names)
    }

    func setCloudActivity(_ active: Bool) {
        assignIfChanged(&cloudActivity, active)
    }

    func setAgentName(_ name: String) {
        assignIfChanged(&agentName, name)
    }

    static let hermesAgentName = "Hermes"
    static let providerAgentName = "AI provider"

    static func summary(of route: RouteDecision?, agentName: String = "Hermes") -> String? {
        switch route {
        case .local(let intent): return intent.summary
        case .remote: return "Send to \(agentName) (cloud)"
        case .emergencyStop: return "Stop everything"
        case .cancelTurn: return "Cancel the current turn"
        case .reject, .none: return nil
        }
    }

    private func assignIfChanged<Value: Equatable>(_ slot: inout Value, _ value: Value) {
        if slot != value { slot = value }
    }
}
