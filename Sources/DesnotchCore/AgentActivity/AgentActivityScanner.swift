import Foundation

/// Discovers local Claude Code / Codex CLI session transcripts and turns them into coarse,
/// privacy-safe `AgentSession` summaries.
///
/// Pattern adapted from agent-island (https://github.com/tristan666666/agent-island, MIT,
/// Eric Park)'s `SessionScanner.swift`: enumerate the known session-log directories, skip
/// sub-agent/automation fan-out, and derive state from file recency plus a turn-completion
/// marker - state is never derived from transcript prose. See `AGENTS.md` for the attribution
/// note and the per-format detail this implementation fills in independently.
///
/// Every path here is built from `NSHomeDirectory()` via the standard `~/.claude` / `~/.codex`
/// locations - never a machine-specific literal - and nothing that leaves this type (session
/// id, absolute path, transcript body) reaches the UI. Only `AgentSession.projectLabel` (a
/// basename), `AgentSession.state`/`lastActivity`, and - only when the caller passes
/// `includeTaskTitles: true`, i.e. the owner opted in via Settings - a hard-truncated
/// first-prompt hint (`AgentSession.taskTitle`) do. With titles off (the default) no prompt text
/// is read at all.
public enum AgentActivityScanner {
    /// Sessions whose transcript hasn't changed in longer than this are treated as gone, not
    /// merely idle - old/finished chats from days ago shouldn't resurface as activity.
    static let lookbackWindow: TimeInterval = 2 * 60 * 60
    /// A turn that's still "in progress" past this long without a file change is presumed hung.
    static let stalledWindow: TimeInterval = 10 * 60
    /// A stalled (presumed-hung) session is only surfaced this long; beyond it, it's almost
    /// certainly dead and would otherwise inflate the count ("N agents: ... stalled") for up
    /// to `lookbackWindow`.
    static let stalledSessionMax: TimeInterval = 45 * 60
    /// A transcript stamped this far in the future (clock set back, NTP step, restored or
    /// synced files) has an untrustworthy age. Smaller negative ages are ordinary jitter.
    static let clockSkewTolerance: TimeInterval = 60
    /// A completed turn this recent is "needs you"; older than this it fades to plain "idle".
    static let needsYourTurnWindow: TimeInterval = 5 * 60

    /// Tail seek window is escalated through these sizes when no turn signal is found, so a
    /// single giant JSONL entry (seen: >1 MB) doesn't silently drop a whole session.
    static let tailWindows: [Int] = [65_536, 1_048_576, 4_194_304]

    /// Head window read for first-prompt title extraction. A session whose first prompt sits
    /// past it just falls back to the project label.
    static let titleHeadBytes = 262_144
    /// Head window scanned for a Claude Code transcript's `cwd`.
    static let claudeCWDHeadBytes = 32_768

    /// Minimum spacing between OpenCode queries when only the WAL/SHM sidecars changed (the
    /// main database file is untouched). A running agent appends to the WAL constantly, which
    /// otherwise respawned `sqlite3` against a possibly multi-GB database on every 5s scan.
    static let openCodeWALThrottle: TimeInterval = 10
    static let openCodeQueryTimeout: TimeInterval = 10
    static let openCodeOutputByteCap = 1_048_576

    /// The providers scanned, in result order (Claude Code, Codex, Pi, OpenCode).
    private static let sources: [any AgentSessionSource] = [
        ClaudeCodeSessionSource(),
        CodexSessionSource(),
        PiSessionSource(),
        OpenCodeSessionSource(),
    ]

    /// Scan the current user's known session directories. `includeTaskTitles` is the owner's
    /// opt-in for first-prompt-derived titles; when false no prompt text is read at all.
    public static func scan(now: Date, includeTaskTitles: Bool = false) -> [AgentSession] {
        scan(home: URL(fileURLWithPath: NSHomeDirectory()), now: now, includeTaskTitles: includeTaskTitles)
    }

    /// Scan rooted at an arbitrary home directory (testable with fixture trees).
    public static func scan(home: URL, now: Date, includeTaskTitles: Bool = false) -> [AgentSession] {
        beginScan()
        defer { pruneTurnCache() }
        return sources.flatMap { $0.scan(home: home, now: now, includeTaskTitles: includeTaskTitles) }
    }

    // MARK: - Shared

    /// Maps recency + turn state to a coarse activity state, or `nil` if the session should
    /// not be surfaced at all (e.g. a presumed-hung session now presumed dead).
    public static func classify(elapsed rawElapsed: TimeInterval, turnInProgress: Bool) -> AgentActivityState? {
        // A future mtime would otherwise read as "just now" for hours or days: it never
        // stalls or fades, inflating the count and firing a needs-you notification.
        guard rawElapsed >= -clockSkewTolerance else { return nil }
        let elapsed = max(0, rawElapsed)
        if turnInProgress {
            // Beyond `stalledSessionMax` with no file change, treat as dead, not stalled.
            guard elapsed <= stalledSessionMax else { return nil }
            return elapsed < stalledWindow ? .working : .stalled
        } else {
            return elapsed < needsYourTurnWindow ? .needsYourTurn : .idle
        }
    }

    /// Stable, opaque per-session identity (source + FNV-1a hash of the transcript path or
    /// database session id). Used only to tell two sessions apart across scans, e.g. for
    /// notification de-duplication when two sessions share a project and title. It is a hash:
    /// never rendered and not reversible to a path.
    static func identityKey(_ source: AgentSource, _ token: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\(source)|" + String(hash, radix: 16)
    }
}
