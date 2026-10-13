import Foundation

// Tools that drive AppKit through `AgentSystemServing`: apps, links, the existing local verbs
// (media, volume, timer), a system snapshot, and the clipboard.

/// `open_app`: an app from the fixed catalog, an exact bundle id, or an installed app whose
/// name matches exactly. T1. A name that touches a protected marker is T4.
struct OpenAppTool: AgentTool {
    let system: AgentSystemServing

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "open_app",
            description: "Open (or bring to front) an installed Mac app by its name or bundle id.",
            inputSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"App name, e.g. Safari, or bundle id"}},"required":["name"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let name = args.text("name"), name.count <= 200 else {
            return AgentProposals.invalid("tool.open_app", label: AgentToolStep.openApp, "name is required")
        }
        let scan = AgentProposals.scanned(name)
        if scan.flags.contains(.hiddenCharacters) || CommandRiskScanner.mentionsProtectedPath(name) {
            return ChatToolProposal(
                tier: .t4, stepLabel: AgentToolStep.openApp, summary: "Open an app", literal: scan.sanitized,
                risk: scan.flags, auditCode: "tool.open_app"
            )
        }
        return ChatToolProposal(
            tier: .t1, stepLabel: AgentToolStep.openApp, summary: "Open an app", literal: scan.sanitized,
            auditCode: "tool.open_app"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        let name = args.text("name") ?? ""
        let system = self.system
        guard let match = await system.resolveApp(name) else {
            return ChatToolOutcome(content: "No installed app matches that name.", isError: true)
        }
        let launched = await system.launchApp(match)
        return launched
            ? ChatToolOutcome(content: "Opened \(match.name).", isError: false)
            : ChatToolOutcome(content: "Could not open \(match.name).", isError: true)
    }
}

/// `open_url`: an http(s) link in the default browser. Tier from `AgentURLPolicy`.
struct OpenURLTool: AgentEgressTool {
    let system: AgentSystemServing

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "open_url",
            description: "Open an http or https web address in the default browser.",
            inputSchemaJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let raw = args.text("url"), let verdict = AgentURLPolicy.classify(raw) else {
            return AgentProposals.invalid("tool.open_url", label: AgentToolStep.openLink, "a valid http(s) url is required")
        }
        return ChatToolProposal(
            tier: verdict.tier,
            stepLabel: verdict.tier == .t2 ? AgentToolStep.openLinkApproved : AgentToolStep.openLink,
            summary: "Open a link in your browser",
            literal: verdict.literal,
            risk: verdict.risk,
            isTruncated: verdict.isTruncated,
            auditCode: "tool.open_url"
        )
    }

    func proposeAfterDataRead(_ args: AgentToolArgs) -> ChatToolProposal {
        guard let raw = args.text("url"), let verdict = AgentURLPolicy.classify(raw) else {
            return AgentProposals.invalid("tool.open_url", label: AgentToolStep.openLinkApproved, "a valid http(s) url is required")
        }
        return ChatToolProposal(
            tier: max(.t2, verdict.tier), stepLabel: AgentToolStep.openLinkApproved,
            summary: "Open a link in your browser", literal: verdict.literal, risk: verdict.risk,
            isTruncated: verdict.isTruncated, auditCode: "tool.open_url"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let raw = args.text("url"), let verdict = AgentURLPolicy.classify(raw), verdict.tier <= .t2 else {
            return ChatToolOutcome(content: "Invalid url.", isError: true)
        }
        let opened = await system.open(verdict.url)
        return ChatToolOutcome(content: opened ? "Opened the link." : "Could not open the link.", isError: !opened)
    }
}

/// `media_control`: play, pause, next, previous through the local executor. T0.
struct MediaControlTool: AgentTool {
    let system: AgentSystemServing

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "media_control",
            description: "Control what is playing: play, pause, next or previous.",
            inputSchemaJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["play","pause","next","previous"]}},"required":["action"]}"#
        )
    }

    static func intent(_ action: String?) -> LocalIntent? {
        switch action?.lowercased() {
        case "play": return .mediaPlay
        case "pause": return .mediaPause
        case "next": return .mediaNext
        case "previous": return .mediaPrevious
        default: return nil
        }
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let intent = Self.intent(args.text("action")) else {
            return AgentProposals.invalid("tool.media_control", label: AgentToolStep.media, "action must be play, pause, next or previous")
        }
        return ChatToolProposal(
            tier: ConfirmationPolicy.tier(of: intent), stepLabel: AgentToolStep.media, summary: intent.summary,
            literal: intent.summary, auditCode: "tool.media_control"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let intent = Self.intent(args.text("action")) else {
            return ChatToolOutcome(content: "Invalid action.", isError: true)
        }
        return LocalIntentTools.outcome(await system.execute(intent))
    }
}

/// `set_volume`: absolute output volume. T0 up to 70%, T2 (card) above, exactly like the
/// local lane (`ConfirmationPolicy`).
struct SetVolumeTool: AgentTool {
    let system: AgentSystemServing

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "set_volume",
            description: "Set the Mac's output volume in percent (0 to 100). Above 70 needs the user's approval.",
            inputSchemaJSON: #"{"type":"object","properties":{"percent":{"type":"integer","minimum":0,"maximum":100}},"required":["percent"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let percent = args.int("percent"), (0...100).contains(percent) else {
            return AgentProposals.invalid("tool.set_volume", label: AgentToolStep.volume, "percent must be 0 to 100")
        }
        let intent = LocalIntent.volumeSet(percent: percent)
        let tier = ConfirmationPolicy.tier(of: intent)
        return ChatToolProposal(
            tier: tier, stepLabel: tier == .t2 ? AgentToolStep.volumeApproved : AgentToolStep.volume,
            summary: intent.summary, literal: intent.summary, auditCode: "tool.set_volume"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let percent = args.int("percent"), (0...100).contains(percent) else {
            return ChatToolOutcome(content: "Invalid percent.", isError: true)
        }
        return LocalIntentTools.outcome(await system.execute(.volumeSet(percent: percent)))
    }
}

/// `focus_timer`: start (1-120 minutes) or cancel the focus timer. T0.
struct FocusTimerTool: AgentTool {
    let system: AgentSystemServing

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "focus_timer",
            description: "Start a focus timer for 1 to 120 minutes, or cancel the running one.",
            inputSchemaJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["start","cancel"]},"minutes":{"type":"integer","minimum":1,"maximum":120}},"required":["action"]}"#
        )
    }

    static func intent(_ args: AgentToolArgs) -> LocalIntent? {
        switch args.text("action")?.lowercased() {
        case "cancel":
            return .timerCancel
        case "start":
            guard let minutes = args.int("minutes"), VoiceLimits.timerMinutesRange.contains(minutes) else { return nil }
            return .timerStart(minutes: minutes)
        default:
            return nil
        }
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let intent = Self.intent(args) else {
            return AgentProposals.invalid("tool.focus_timer", label: AgentToolStep.timer, "use start with 1 to 120 minutes, or cancel")
        }
        return ChatToolProposal(
            tier: ConfirmationPolicy.tier(of: intent), stepLabel: AgentToolStep.timer, summary: intent.summary,
            literal: intent.summary, auditCode: "tool.focus_timer"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let intent = Self.intent(args) else {
            return ChatToolOutcome(content: "Invalid timer request.", isError: true)
        }
        return LocalIntentTools.outcome(await system.execute(intent))
    }
}

enum LocalIntentTools {
    static func outcome(_ result: LocalExecutionResult) -> ChatToolOutcome {
        switch result {
        case .success(let spoken):
            return ChatToolOutcome(content: spoken ?? "Done.", isError: false)
        case .failure(let failure):
            return ChatToolOutcome(content: "Failed: \(failure.code).", isError: true)
        }
    }
}

/// `get_system_info`: date and time, battery, free disk space, frontmost app, now playing. T1.
struct SystemInfoTool: AgentTool {
    let system: AgentSystemServing
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "get_system_info",
            description: "Get the current date and time, battery, free disk space, frontmost app and what is playing.",
            inputSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        ChatToolProposal(tier: .t1, stepLabel: AgentToolStep.systemInfo, summary: "Read system status", auditCode: "tool.get_system_info")
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        ChatToolOutcome(content: Self.render(await system.snapshot()), isError: false)
    }

    static func render(_ snapshot: AgentSystemSnapshot) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: snapshot.timeZone) ?? .current
        var lines = ["time: \(formatter.string(from: snapshot.date)) (\(snapshot.timeZone))"]
        if let percent = snapshot.batteryPercent {
            lines.append("battery: \(percent)%\(snapshot.batteryCharging == true ? ", charging" : "")")
        } else {
            lines.append("battery: none")
        }
        if let free = snapshot.diskFreeBytes {
            lines.append("disk free: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
        if let app = snapshot.frontmostApp { lines.append("frontmost app: \(app)") }
        if let title = snapshot.nowPlayingTitle {
            let artist = snapshot.nowPlayingArtist.map { " by \($0)" } ?? ""
            let state = snapshot.nowPlayingIsPlaying == true ? "playing" : "paused"
            lines.append("now playing (\(state)): \(title)\(artist)")
        }
        return lines.joined(separator: "\n")
    }
}

/// `clipboard_read`: T2, because the clipboard may hold a secret. The card says how much would
/// be shared but never shows the text itself.
struct ClipboardReadTool: AgentTool {
    let system: AgentSystemServing
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "clipboard_read",
            description: "Read the plain text on the clipboard. The user must approve.",
            inputSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        ChatToolProposal(
            tier: .t2, stepLabel: AgentToolStep.readClipboardApproved, summary: "Share your clipboard with the AI",
            literal: "Send the clipboard text to the AI provider", auditCode: "tool.clipboard_read"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let text = await system.readClipboard(), !text.isEmpty else {
            return ChatToolOutcome(content: "The clipboard holds no shareable text.", isError: true)
        }
        return ChatToolOutcome(content: text, isError: false)
    }
}

/// `clipboard_write`: puts plain text on the clipboard. T2: text the user may paste into a
/// terminal is shown in full on the card, or the card cannot be approved; control, bidi and
/// zero-width characters are refused (T4).
struct ClipboardWriteTool: AgentTool {
    let system: AgentSystemServing

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "clipboard_write",
            description: "Copy plain text to the clipboard. The user must approve.",
            inputSchemaJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let text = args.string("text"), !text.isEmpty, text.utf8.count <= AgentToolLimits.writeBytes else {
            return AgentProposals.invalid("tool.clipboard_write", label: AgentToolStep.copyToClipboardApproved, "text is required (at most 64 KB)")
        }
        let card = AgentProposals.contentCard(header: ["Copy \(text.count) characters:"], content: text)
        return ChatToolProposal(
            tier: card.hidden ? .t4 : .t2, stepLabel: AgentToolStep.copyToClipboardApproved,
            summary: "Copy text to the clipboard", literal: card.literal, isTruncated: card.isTruncated,
            auditCode: "tool.clipboard_write"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let text = args.string("text"), !text.isEmpty, text.utf8.count <= AgentToolLimits.writeBytes else {
            return ChatToolOutcome(content: "Invalid text.", isError: true)
        }
        let written = await system.writeClipboard(text)
        return ChatToolOutcome(content: written ? "Copied." : "Could not write the clipboard.", isError: !written)
    }
}
