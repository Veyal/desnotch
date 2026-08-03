import Foundation

/// Coarse state for a single detected coding-agent session, derived from how recently its
/// transcript file changed plus a lightweight turn-completion marker in its content - never
/// from the transcript text itself.
public enum AgentActivityState {
    case working
    case needsYourTurn
    case stalled
    case idle
}

public enum AgentSource {
    case claudeCode
    case codex
    case pi
    case openCode

    /// SF Symbol glyph for the source (generic, no paths/content).
    public var symbol: String {
        switch self {
        case .claudeCode: return "terminal.fill"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .pi: return "p.circle.fill"
        case .openCode: return "curlybraces"
        }
    }

    /// Human-readable name for the source.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .pi: return "Pi"
        case .openCode: return "OpenCode"
        }
    }
}

/// A single detected session. `projectLabel` is always a generic basename (never a full path)
/// so it is safe to render directly in the UI. `taskTitle` is a short, hard-truncated hint
/// derived from the session's first real user prompt line (owner-approved exception to the
/// no-transcript rule - see AGENTS.md); nil when the format carries no usable prompt.
public struct AgentSession: Identifiable {
    public let id = UUID()
    public let source: AgentSource
    public let projectLabel: String
    public let taskTitle: String?
    /// Absolute project directory for click-to-jump. NEVER rendered (privacy boundary:
    /// only `projectLabel`/`taskTitle` reach pixels) - used solely as an open target.
    public let projectPath: String?
    public let state: AgentActivityState
    public let lastActivity: Date

    public init(
        source: AgentSource,
        projectLabel: String,
        taskTitle: String? = nil,
        projectPath: String? = nil,
        state: AgentActivityState,
        lastActivity: Date
    ) {
        self.source = source
        self.projectLabel = projectLabel
        self.taskTitle = taskTitle
        self.projectPath = projectPath
        self.state = state
        self.lastActivity = lastActivity
    }
}

/// Aggregated counts the pill actually renders - individual session identities/paths never
/// reach the view layer, only these counts and generic labels.
public struct AgentActivitySummary: Equatable {
    public let workingCount: Int
    public let needsYourTurnCount: Int
    public let stalledCount: Int
    public let idleCount: Int

    public init(sessions: [AgentSession]) {
        workingCount = sessions.filter { $0.state == .working }.count
        needsYourTurnCount = sessions.filter { $0.state == .needsYourTurn }.count
        stalledCount = sessions.filter { $0.state == .stalled }.count
        idleCount = sessions.filter { $0.state == .idle }.count
    }

    /// Sessions worth surfacing in the pill. Purely-idle sessions (turn finished a while ago,
    /// nothing pending) are tracked but deliberately excluded here so old/finished chats don't
    /// keep the pill open - see the priority note in `NotchPillView`.
    public var actionableCount: Int { workingCount + needsYourTurnCount + stalledCount }

    public var hasActivity: Bool { actionableCount > 0 }

    public var headline: String {
        var clauses: [String] = []
        if workingCount > 0 { clauses.append("\(workingCount) working") }
        if needsYourTurnCount > 0 { clauses.append("\(needsYourTurnCount) needs you") }
        if stalledCount > 0 { clauses.append("\(stalledCount) stalled") }
        let noun = actionableCount == 1 ? "agent" : "agents"
        return "\(actionableCount) \(noun): \(clauses.joined(separator: ", "))"
    }

    public static func == (lhs: AgentActivitySummary, rhs: AgentActivitySummary) -> Bool {
        lhs.workingCount == rhs.workingCount
            && lhs.needsYourTurnCount == rhs.needsYourTurnCount
            && lhs.stalledCount == rhs.stalledCount
            && lhs.idleCount == rhs.idleCount
    }
}
