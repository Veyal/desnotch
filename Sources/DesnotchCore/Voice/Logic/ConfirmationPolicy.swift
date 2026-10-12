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
