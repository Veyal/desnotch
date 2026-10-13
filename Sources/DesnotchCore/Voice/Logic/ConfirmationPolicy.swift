import Foundation

// WP-LOGIC owns this file. Base commit: fail-closed stubs with the final signatures.

enum ConfirmationPolicy {
    /// The tier of a local intent (T0 for everything except absolute volume above the
    /// confirm line, and out-of-range values, which fail closed to T4).
    static func tier(of intent: LocalIntent) -> VoiceTier {
        switch intent {
        case .mediaPlay, .mediaPause, .mediaNext, .mediaPrevious,
             .volumeStep, .mute, .unmute, .openApp, .timerCancel:
            return .t0
        case .volumeSet(let percent):
            if percent < 0 || percent > 100 { return .t4 }
            return percent > VoiceLimits.volumeConfirmAbove ? .t2 : .t0
        case .timerStart(let minutes):
            return VoiceLimits.timerMinutesRange.contains(minutes) ? .t0 : .t4
        }
    }

    /// Tier to gate decision. T0/T1 allow, T2 confirm, T3 denied while no second factor
    /// (unavailable in the MVP), T4 denied.
    static func decide(tier: VoiceTier, secondFactorAvailable: Bool) -> PolicyDecision {
        switch tier {
        case .t0, .t1: return .allow
        case .t2: return .confirm
        case .t3: return secondFactorAvailable ? .confirm : .deny(.secondFactorUnavailable)
        case .t4: return .deny(.tierT4)
        }
    }
}

/// Classifies Hermes tool names (category labels) into tiers. Default-deny: an unknown name
/// is T3 and trips the tripwire.
enum ToolTierTable {
    /// The MVP `voice` profile ships no T1 tools; adding a name here is a contract amendment.
    static let explicitT1: Set<String> = []

    private static let t4Markers: [String] = [
        "interseptor", "vault", "engagement", "ssh", "keychain", "credential", "secret",
        "password", "token", "auth", "sudo", "hermes", "evidence", "finding"
    ]
    private static let t0Names: Set<String> = [
        "clock", "current_time", "get_time", "time", "calculator", "now_playing"
    ]
    private static let t3Words: Set<String> = [
        "terminal", "shell", "bash", "sh", "zsh", "exec", "execute", "run", "curl", "wget",
        "http", "https", "fetch", "web", "browser", "search", "network", "send", "post",
        "email", "message", "computer", "click", "screenshot", "cron", "kanban", "mcp",
        "docker", "git"
    ]
    private static let t2Words: Set<String> = [
        "write", "edit", "patch", "delete", "remove", "rm", "move", "mv", "rename", "kill",
        "create", "copy", "cp", "read", "list"
    ]

    static func tier(forTool kind: String) -> VoiceTier {
        // Exact, case-sensitive match first: these labels contain a capital letter and a space,
        // which `HermesEventMapper.toolKind` never produces, so a Hermes tool cannot borrow them.
        if let inProcess = AgentToolStep.tiers[kind] { return inProcess }
        let lowered = kind.lowercased()
        if lowered.trimmingCharacters(in: .whitespaces).isEmpty { return .t3 }
        for marker in t4Markers where lowered.contains(marker) { return .t4 }
        if t0Names.contains(lowered) { return .t0 }
        if explicitT1.contains(lowered) { return .t1 }
        let words = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for word in words where t3Words.contains(word) { return .t3 }
        for word in words where t2Words.contains(word) { return .t2 }
        return .t3
    }
}

/// Step labels of desnotch's own machine-control tools (`Voice/Tools`, opt-in
/// `voiceAgentToolsEnabled`), with the tier each label stands for. The in-process backend
/// classifies a call BEFORE it runs and reports the start with the label of the tier it ran at:
/// a T2 call is reported only after its card was approved, with an "(approved)" label, so R82
/// consumes that approval and any other T2 start still trips the wire (R83). Labels are display
/// text for the step chips: no arguments, ever.
enum AgentToolStep {
    static let media = "Media"
    static let volume = "Volume"
    static let volumeApproved = "Volume (approved)"
    static let timer = "Timer"
    static let openApp = "Open app"
    static let openLink = "Open link"
    static let openLinkApproved = "Open link (approved)"
    static let systemInfo = "System info"
    static let listFolder = "List folder"
    static let listFolderApproved = "List folder (approved)"
    static let readFile = "Read file"
    static let readFileApproved = "Read file (approved)"
    static let searchFiles = "Search files"
    static let searchFilesApproved = "Search files (approved)"
    static let readClipboardApproved = "Read clipboard (approved)"
    static let copyToClipboardApproved = "Copy to clipboard (approved)"
    static let fetchPage = "Fetch page"
    static let fetchPageApproved = "Fetch page (approved)"
    static let writeFileApproved = "Write file (approved)"
    static let runShortcutApproved = "Run shortcut (approved)"
    static let runAppleScriptApproved = "Run AppleScript (approved)"
    static let runCommandApproved = "Run command (approved)"

    static let tiers: [String: VoiceTier] = [
        media: .t0,
        volume: .t0,
        timer: .t0,
        openApp: .t1,
        openLink: .t1,
        systemInfo: .t1,
        listFolder: .t1,
        readFile: .t1,
        searchFiles: .t1,
        fetchPage: .t1,
        volumeApproved: .t2,
        openLinkApproved: .t2,
        listFolderApproved: .t2,
        readFileApproved: .t2,
        searchFilesApproved: .t2,
        readClipboardApproved: .t2,
        copyToClipboardApproved: .t2,
        fetchPageApproved: .t2,
        writeFileApproved: .t2,
        runShortcutApproved: .t2,
        runAppleScriptApproved: .t2,
        runCommandApproved: .t2
    ]
}
