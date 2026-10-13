import Foundation

// Pure presentation values for the voice section. Views render this and never read the
// session model themselves, so the per-state table stays unit-testable without AppKit.

enum VoiceGlyph: String, Equatable {
    case mic = "mic.fill"
    case ellipsis = "ellipsis"
    case checkmark = "checkmark.circle"
    case gear = "gearshape.fill"
    case bolt = "bolt.fill"
    case speaker = "speaker.wave.2.fill"
    case warning = "exclamationmark.triangle.fill"
    case pause = "pause.fill"
    case stop = "stop.fill"
    case cloud = "cloud.fill"
    case cancel = "xmark"
}

extension VoiceGlyph {
    /// The one glyph-for-state mapping, shared by the left wing and the section header.
    /// Nil only while idle, when the section is not mounted.
    static func wing(for state: VoiceState) -> VoiceGlyph? {
        switch state {
        case .idle: return nil
        case .armed, .listening: return .mic
        case .transcribing, .thinking: return .ellipsis
        case .review: return .checkmark
        case .acting: return .gear
        case .awaitingApproval: return .bolt
        case .speaking: return .speaker
        case .error: return .warning
        case .paused: return .pause
        }
    }
}

enum VoiceTint: Equatable {
    case neutral, calm, amber, red
}

enum VoiceWingRight: Equatable {
    case none, meter, amberDot
}

enum VoiceLineEmphasis: Equatable {
    case primary, secondary, caption
}

struct VoiceBodyLine: Equatable {
    var text: String
    var lineLimit: Int
    var emphasis: VoiceLineEmphasis
}

struct VoiceChipSpec: Equatable {
    var text: String
    var glyph: VoiceGlyph?
}

enum VoiceButtonRole: Equatable {
    case stop, cancel, resume, deny, approveClick, approveHold
}

struct VoiceButtonSpec: Equatable {
    var role: VoiceButtonRole
    var title: String
    var glyph: VoiceGlyph?
    var isEnabled: Bool
    var nonce: String?
}

struct VoiceCountdown: Equatable {
    var deadline: Date
    var total: TimeInterval

    func remainingFraction(now: Date) -> Double {
        guard total > 0 else { return 0 }
        let fraction = deadline.timeIntervalSince(now) / total
        return min(1, max(0, fraction))
    }
}

struct VoiceCardPresentation: Equatable {
    var tierLabel: String
    var riskWords: [String]
    var riskOverflow: Int
    var summary: String
    var literal: String
    var isLiteralComplete: Bool
    var note: String?
    var hint: String?
    var requiresHold: Bool
    var nonce: String
}

struct VoiceSectionSnapshot: Equatable {
    var state: VoiceState = .idle
    var partialTranscript: String = ""
    var finalTranscript: String = ""
    var reply: String = ""
    var reviewDeadline: Date? = nil
    var steps: [VoiceStep] = []
    var stepsStarted: Int = 0
    var pending: ConfirmationRequest? = nil
    var routeSummary: String? = nil
    var errorText: String? = nil
    var errorSeverity: VoiceFailure.Severity = .info
    var lane: VoiceLane? = nil
    var usesCloud: Bool = false
    var interruptListening: Bool = false
    var survivors: [String] = []
}

extension VoiceSectionSnapshot {
    /// Copies the live model into a value the pure presenter can read. Declared in an
    /// extension on purpose: an initializer inside the struct body would suppress the
    /// memberwise initializer the presentation tests build field by field.
    @MainActor
    init(model: VoiceSessionModel) {
        self.init(
            state: model.state,
            partialTranscript: model.partialTranscript,
            finalTranscript: model.finalTranscript,
            reply: model.reply,
            reviewDeadline: model.reviewDeadline,
            steps: model.steps,
            stepsStarted: model.stepsStarted,
            pending: model.pendingConfirmation,
            routeSummary: model.routeSummary,
            errorText: model.errorText,
            errorSeverity: model.errorSeverity,
            lane: model.lane,
            usesCloud: model.usesCloud,
            interruptListening: model.interruptListening,
            survivors: model.survivors
        )
    }
}

struct VoiceSectionPresentation: Equatable {
    var title: String
    var titleLineLimit: Int
    var showsCloudBadge: Bool
    var bodyLines: [VoiceBodyLine]
    var chips: [VoiceChipSpec]
    var showsMeter: Bool
    var countdown: VoiceCountdown?
    var buttons: [VoiceButtonSpec]
    var card: VoiceCardPresentation?
    var tint: VoiceTint
    var wingLeft: VoiceGlyph?
    var wingRight: VoiceWingRight
    var heightBudget: CGFloat
    var accessibilityLabel: String

    /// `now` is accepted so callers share one clock with the countdown, and ignored here:
    /// the countdown exists exactly when a review still has a deadline, even after that
    /// deadline has passed. `remainingFraction(now:)` takes its own clock.
    init(_ snapshot: VoiceSectionSnapshot, privacyMode: Bool, now: Date) {
        _ = now
        let state = snapshot.state
        let showsCloudBadge = snapshot.usesCloud || snapshot.lane == .hermes
        let wingLeft = VoiceGlyph.wing(for: state)
        var title = ""
        var bodyLines: [VoiceBodyLine] = []
        var chips: [VoiceChipSpec] = []
        var showsMeter = false
        var countdown: VoiceCountdown?
        var buttons: [VoiceButtonSpec] = []
        var card: VoiceCardPresentation?
        var tint: VoiceTint = .neutral
        var wingRight: VoiceWingRight = .none
        let heightBudget = state == .awaitingApproval
            ? VoiceCardLayout.approvalHeightBudget
            : VoiceCardLayout.sectionHeightBudget

        switch state {
        case .idle:
            break
        case .armed:
            title = "Starting…"
            buttons = [VoiceSectionPresentation.stopButton()]
            tint = .calm
        case .listening:
            title = snapshot.partialTranscript.isEmpty
                ? "Listening…"
                : VoiceSectionPresentation.redact(
                    snapshot.partialTranscript, fallback: "Voice command", privacyMode: privacyMode
                )
            bodyLines = [VoiceBodyLine(text: "Esc cancels", lineLimit: 1, emphasis: .caption)]
            showsMeter = true
            buttons = [VoiceSectionPresentation.stopButton()]
            wingRight = .meter
        case .transcribing:
            title = "Transcribing…"
            buttons = [VoiceSectionPresentation.stopButton()]
            tint = .calm
        case .review:
            let heard = VoiceSectionPresentation.redact(
                snapshot.finalTranscript, fallback: "Voice command", privacyMode: privacyMode
            )
            title = "Heard: \(heard)"
            if let route = snapshot.routeSummary {
                bodyLines = [VoiceBodyLine(text: route, lineLimit: 1, emphasis: .secondary)]
            }
            if let deadline = snapshot.reviewDeadline {
                countdown = VoiceCountdown(deadline: deadline, total: VoiceTiming.reviewWindow)
            }
            buttons = [
                VoiceButtonSpec(role: .cancel, title: "Cancel", glyph: .cancel, isEnabled: true, nonce: nil),
                VoiceSectionPresentation.stopButton()
            ]
        case .thinking:
            title = "Thinking…"
            buttons = [VoiceSectionPresentation.stopButton()]
        case .acting:
            let agentLane = snapshot.lane != .local
            if agentLane {
                title = "Working…"
                chips = VoiceSectionPresentation.stepChips(snapshot)
            } else {
                title = snapshot.routeSummary ?? "Working…"
            }
            buttons = [VoiceSectionPresentation.stopButton()]
        case .awaitingApproval:
            title = "Needs approval"
            tint = .amber
            wingRight = .amberDot
            if let pending = snapshot.pending {
                let built = VoiceSectionPresentation.cardPresentation(pending, privacyMode: privacyMode)
                card = built.card
                buttons = built.buttons + [VoiceSectionPresentation.stopButton()]
            } else {
                buttons = [VoiceSectionPresentation.stopButton()]
            }
        case .speaking:
            title = snapshot.reply.isEmpty
                ? "Done"
                : VoiceSectionPresentation.redact(snapshot.reply, fallback: "Reply", privacyMode: privacyMode)
            buttons = [VoiceSectionPresentation.stopButton()]
        case .error:
            title = snapshot.errorText ?? "Something went wrong"
            buttons = [VoiceSectionPresentation.stopButton()]
            let severityText: String
            switch snapshot.errorSeverity {
            case .info:
                tint = .calm
                severityText = "Info"
            case .warning:
                tint = .amber
                severityText = "Warning"
            case .alert:
                tint = .red
                severityText = "Alert"
            }
            bodyLines = [VoiceBodyLine(text: severityText, lineLimit: 1, emphasis: .caption)]
        case .paused:
            title = snapshot.errorText ?? "Agent stopped"
            if !snapshot.survivors.isEmpty {
                let names = snapshot.survivors.map {
                    VoiceSectionPresentation.redact($0, fallback: "process", privacyMode: privacyMode)
                }
                bodyLines = [VoiceBodyLine(
                    text: VoiceSectionPresentation.survivorsLine(names),
                    lineLimit: 2,
                    emphasis: .caption
                )]
            }
            buttons = [VoiceButtonSpec(role: .resume, title: "Resume", glyph: nil, isEnabled: true, nonce: nil)]
            tint = .red
        }

        if snapshot.interruptListening, state == .thinking || state == .acting {
            bodyLines.append(VoiceBodyLine(
                text: "Say “abort agent” to stop",
                lineLimit: 1,
                emphasis: .caption
            ))
            showsMeter = true
        }

        self.title = title
        self.titleLineLimit = VoiceSectionPresentation.titleLineLimit(for: state)
        self.showsCloudBadge = state == .idle ? false : showsCloudBadge
        self.bodyLines = bodyLines
        self.chips = chips
        self.showsMeter = showsMeter
        self.countdown = countdown
        self.buttons = buttons
        self.card = card
        self.tint = tint
        self.wingLeft = wingLeft
        self.wingRight = wingRight
        self.heightBudget = heightBudget
        self.accessibilityLabel = VoiceSectionPresentation.accessibilityLabel(
            state: state,
            snapshot: snapshot,
            showsCloudBadge: self.showsCloudBadge,
            card: card
        )
    }

    static func titleLineLimit(for state: VoiceState) -> Int {
        switch state {
        case .listening, .review, .error: return 2
        case .speaking: return 3
        default: return 1
        }
    }

    private static func stopButton() -> VoiceButtonSpec {
        VoiceButtonSpec(role: .stop, title: "Stop", glyph: .stop, isEnabled: true, nonce: nil)
    }

    private static func redact(_ text: String, fallback: String, privacyMode: Bool) -> String {
        privacyMode ? fallback : text
    }

    private static func survivorsLine(_ names: [String]) -> String {
        let shown = names.prefix(3)
        let extra = names.count - shown.count
        var line = "\(names.count) still running: \(shown.joined(separator: ", "))"
        if extra > 0 {
            line += ", +\(extra)"
        }
        return line
    }

    private static func stepChips(_ snapshot: VoiceSectionSnapshot) -> [VoiceChipSpec] {
        let shown = snapshot.steps.suffix(VoiceLimits.visibleStepChips)
        var chips = shown.map { VoiceChipSpec(text: $0.kind, glyph: nil) }
        let overflow = snapshot.stepsStarted - shown.count
        if overflow > 0 {
            chips.append(VoiceChipSpec(text: "+\(overflow)", glyph: nil))
        }
        return chips
    }

    private static func cardPresentation(
        _ request: ConfirmationRequest, privacyMode: Bool
    ) -> (card: VoiceCardPresentation, buttons: [VoiceButtonSpec]) {
        let hold = request.source == .hermes
        let reviewable = VoiceCardLayout.isLiteralReviewable(request.literal)
        let approveEnabled = request.canApprove && reviewable && !(privacyMode && hold)
        let risks = VoiceRiskWords.words(for: request.risk)
        let summary = hold
            ? redact(request.summary, fallback: "Agent action", privacyMode: privacyMode)
            : request.summary
        let drawn = VoiceCardLayout.displayedLiteral(request.literal)
        let literal = hold
            ? redact(drawn, fallback: "Command", privacyMode: privacyMode)
            : drawn
        let note: String?
        if privacyMode && hold {
            note = "Turn off Privacy mode to review"
        } else if !reviewable || request.isTruncated {
            note = "Too long to review here"
        } else if !request.canApprove {
            note = "Can't approve this from voice"
        } else {
            note = nil
        }
        let hint: String? = hold && approveEnabled ? "Hold Approve to confirm" : nil
        let card = VoiceCardPresentation(
            tierLabel: request.tier.label,
            riskWords: risks.words,
            riskOverflow: risks.overflow,
            summary: summary,
            literal: literal,
            isLiteralComplete: reviewable,
            note: note,
            hint: hint,
            requiresHold: hold,
            nonce: request.nonce
        )
        let approve = VoiceButtonSpec(
            role: hold ? .approveHold : .approveClick,
            title: "Approve",
            glyph: nil,
            isEnabled: approveEnabled,
            nonce: request.nonce
        )
        let deny = VoiceButtonSpec(
            role: .deny, title: "Deny", glyph: nil, isEnabled: true, nonce: request.nonce
        )
        return (card, [deny, approve])
    }

    private static func accessibilityLabel(
        state: VoiceState,
        snapshot: VoiceSectionSnapshot,
        showsCloudBadge: Bool,
        card: VoiceCardPresentation?
    ) -> String {
        guard state != .idle else { return "" }
        var parts: [String] = []
        if let word = VoiceStateWords.wingWord(for: state) {
            parts.append("Voice: \(word)")
        }
        if showsCloudBadge {
            parts.append(
                state == .review
                    ? "goes to the Hermes cloud agent"
                    : "sent to the Hermes cloud agent"
            )
        }
        let showsRoute = state == .review || (state == .acting && snapshot.lane == .local)
        if showsRoute, let route = snapshot.routeSummary {
            parts.append(route)
        }
        if let card {
            parts.append(card.tierLabel)
            parts.append(contentsOf: card.riskWords)
        }
        if state == .error || state == .paused, let error = snapshot.errorText, !error.isEmpty {
            parts.append(error)
        }
        if !snapshot.survivors.isEmpty {
            parts.append("\(snapshot.survivors.count) still running")
        }
        return parts.joined(separator: ", ")
    }
}

enum VoiceCardLayout {
    static let maxVisibleCharacters = 240
    static let maxVisibleLines = 6
    static let sectionHeightBudget: CGFloat = 112
    static let approvalHeightBudget: CGFloat = 300
    static let literalFontSize: CGFloat = 10

    static func lines(of literal: String) -> [String] {
        literal.components(separatedBy: .newlines)
    }

    static func isLiteralReviewable(_ literal: String) -> Bool {
        literal.count <= maxVisibleCharacters && lines(of: literal).count <= maxVisibleLines
    }

    /// Cuts a literal that cannot be reviewed in full. Line cut first, then characters,
    /// then an ellipsis, so Approve stays disabled for anything the card does not show whole.
    static func displayedLiteral(_ literal: String) -> String {
        guard !isLiteralReviewable(literal) else { return literal }
        let joined = lines(of: literal).prefix(maxVisibleLines).joined(separator: "\n")
        return String(joined.prefix(maxVisibleCharacters)) + "…"
    }
}

enum VoiceStateWords {
    static func wingWord(for state: VoiceState) -> String? {
        switch state {
        case .idle: return nil
        case .armed: return "starting"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .review: return "confirming"
        case .thinking: return "thinking"
        case .acting: return "working"
        case .awaitingApproval: return "needs approval"
        case .speaking: return "speaking"
        case .error: return "error"
        case .paused: return "stopped"
        }
    }

    static func menuTitle(for state: VoiceState) -> String {
        switch state {
        case .idle: return "Idle"
        case .armed: return "Starting"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .review: return "Confirming"
        case .thinking: return "Thinking"
        case .acting: return "Working"
        case .awaitingApproval: return "Needs Approval"
        case .speaking: return "Speaking"
        case .error: return "Error"
        case .paused: return "Stopped"
        }
    }
}

enum VoiceRiskWords {
    /// Severity first, so "destructive" (the reason a command is T2) cannot fall into "+N".
    private static let ordered: [(RiskFlags, String)] = [
        (.destructive, "destructive"),
        (.sudo, "sudo"),
        (.protectedPath, "protected path"),
        (.pipeToInterpreter, "pipe to shell"),
        (.base64Decode, "base64"),
        (.evalUse, "eval"),
        (.commandSubstitution, "substitution"),
        (.hiddenCharacters, "hidden characters"),
        (.unscanned, "unscanned"),
        (.redirect, "redirect"),
        (.chaining, "chained"),
        (.pipe, "pipe"),
        (.url, "network")
    ]

    static func word(for flag: RiskFlags) -> String {
        ordered.first { flag.contains($0.0) }?.1 ?? ""
    }

    static func words(for flags: RiskFlags) -> (words: [String], overflow: Int) {
        let matched = ordered.compactMap { flags.contains($0.0) ? $0.1 : nil }
        let cap = 4
        return (Array(matched.prefix(cap)), max(0, matched.count - cap))
    }
}

enum VoiceSettingsWords {
    static let shortcutShadowNote = "⌥⌘V also moves items in Finder; choose another shortcut if you use that."
    static let updateCheckNote = "Asks GitHub once a day whether a newer release exists. The update check is the only network request desnotch makes on its own; the optional Hermes agent lane (Voice control) sends requests to your configured agent. You still download and install updates yourself."
    static let privacyModeNote = "Privacy mode hides song titles, agent task titles, event and reminder names, clipboard previews, and tray filenames — for screen sharing. Voice transcripts and replies are hidden and agent approvals are blocked."

    static func hotkeyLabel(_ choice: VoiceHotkeyChoice) -> String {
        switch choice {
        case .optionCommandV: return "⌥⌘V"
        case .shiftOptionCommandV: return "⌥⇧⌘V"
        case .optionCommandJ: return "⌥⌘J"
        }
    }

    static func localeLabel(_ identifier: String) -> String {
        switch identifier {
        case "en-US": return "English (US)"
        case "id-ID": return "Bahasa Indonesia"
        default: return identifier
        }
    }

    static func permissionText(_ state: VoicePermissionState) -> String {
        switch state {
        case .authorized: return "Allowed"
        case .notDetermined: return "Not asked yet"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted by this Mac"
        case .unknown: return "Unknown"
        }
    }

    static func laneStatusText(_ status: HermesLaneStatus) -> String {
        switch status {
        case .off: return "Off"
        case .checking: return "Checking…"
        case .ready: return "Ready"
        case .refused(let reason): return "Refused: \(preflightWord(reason))"
        }
    }

    static func preflightWord(_ failure: PreflightFailure) -> String {
        switch failure {
        case .binaryMissing: return "Hermes not found"
        case .profileMissing: return "no voice profile"
        case .approvalsOff: return "approvals off"
        case .allowlistNotEmpty: return "allowlist not empty"
        case .toolsetOutsideAllowlist: return "toolsets not empty"
        case .configNotLocked: return "profile not locked"
        case .mcpConfigured: return "MCP configured"
        case .protocolMismatch: return "protocol mismatch"
        case .notImplemented: return "not available"
        }
    }
}

enum VoiceAnnouncementPolicy {
    static func announcement(
        for state: VoiceState, severity: VoiceFailure.Severity
    ) -> (message: String, isHighPriority: Bool)? {
        switch state {
        case .awaitingApproval:
            return (PillAnnouncements.voiceNeedsApproval, true)
        case .error where severity == .warning || severity == .alert:
            return (PillAnnouncements.voiceFailed, false)
        case .paused:
            return (PillAnnouncements.voiceStopped, false)
        default:
            return nil
        }
    }
}
