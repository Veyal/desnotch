import Foundation

/// Coarse state for a single detected coding-agent session, derived from how recently its
/// transcript file changed plus a lightweight turn-completion marker in its content - never
/// from the transcript text itself.
enum AgentActivityState {
    case working
    case needsYourTurn
    case stalled
    case idle
}

enum AgentSource {
    case claudeCode
    case codex
}

/// A single detected session. `projectLabel` is always a generic basename (never a full path)
/// so it is safe to render directly in the UI.
struct AgentSession: Identifiable {
    let id = UUID()
    let source: AgentSource
    let projectLabel: String
    let state: AgentActivityState
    let lastActivity: Date
}

/// Aggregated counts the pill actually renders - individual session identities/paths never
/// reach the view layer, only these counts and generic labels.
struct AgentActivitySummary {
    let workingCount: Int
    let needsYourTurnCount: Int
    let stalledCount: Int
    let idleCount: Int

    init(sessions: [AgentSession]) {
        workingCount = sessions.filter { $0.state == .working }.count
        needsYourTurnCount = sessions.filter { $0.state == .needsYourTurn }.count
        stalledCount = sessions.filter { $0.state == .stalled }.count
        idleCount = sessions.filter { $0.state == .idle }.count
    }

    /// Sessions worth surfacing in the pill. Purely-idle sessions (turn finished a while ago,
    /// nothing pending) are tracked but deliberately excluded here so old/finished chats don't
    /// keep the pill open - see the priority note in `NotchPillView`.
    var actionableCount: Int { workingCount + needsYourTurnCount + stalledCount }

    var hasActivity: Bool { actionableCount > 0 }

    var headline: String {
        var clauses: [String] = []
        if workingCount > 0 { clauses.append("\(workingCount) working") }
        if needsYourTurnCount > 0 { clauses.append("\(needsYourTurnCount) needs you") }
        if stalledCount > 0 { clauses.append("\(stalledCount) stalled") }
        let noun = actionableCount == 1 ? "agent" : "agents"
        return "\(actionableCount) \(noun): \(clauses.joined(separator: ", "))"
    }
}
