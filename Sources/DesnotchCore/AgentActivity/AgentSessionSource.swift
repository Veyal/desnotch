import Foundation

/// One provider of local agent sessions (Claude Code, Codex, Pi, OpenCode). Each conformer
/// knows where its transcripts live and how to read a turn signal out of them;
/// `AgentActivityScanner` only orchestrates the list of sources and the shared caches.
///
/// Conformers must stay privacy-safe: only a project basename, a state, a timestamp, an opaque
/// identity hash and - when `includeTaskTitles` is true - a sanitised title may leave `scan`.
protocol AgentSessionSource: Sendable {
    /// Sessions rooted at `home`, already filtered by the lookback window and classified.
    /// Sources without a first-prompt title (Pi, OpenCode) ignore `includeTaskTitles`.
    func scan(home: URL, now: Date, includeTaskTitles: Bool) -> [AgentSession]
}
