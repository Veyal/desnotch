import Foundation

/// Publishes `AgentActivityScanner` results into SwiftUI state.
///
/// Unlike `NowPlayingController`, this polls: there is no OS notification for "a JSONL
/// transcript file changed", so a short interval is the pragmatic option here. The scan
/// itself runs off the main actor since it does file I/O, and only the resulting lightweight
/// summary is published back.
///
/// Scans never overlap: a single long-lived `Task` loop sleeps for `scanInterval`
/// between scans instead of a repeating timer, so a slow scan can't pile up on top of
/// the next tick. Visibility/toast behavior is delegated to `NotchPillPresentation`.
///
/// Two things are published: the aggregate `summary` (counts the pill headline renders)
/// and the per-session `sessions` list (privacy-safe: source + project basename + state +
/// last-activity only - never transcript content) that the detail card renders.
@MainActor
public final class AgentActivityController: ObservableObject {
    @Published public private(set) var summary = AgentActivitySummary(sessions: [])
    @Published public private(set) var sessions: [AgentSession] = []

    public let presentation: NotchPillPresentation
    private let scanInterval: TimeInterval = 5
    private var scanTask: Task<Void, Never>?
    private var lastActionableCount = 0
    private var lastSignature = ""
    private var lastNeedsYouKeys: Set<String> = []
    private var isFirstApply = true

    public init(presentation: NotchPillPresentation) {
        self.presentation = presentation
        startScanning()
    }

    private func startScanning() {
        let interval = scanInterval
        scanTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.scanOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    private func scanOnce() async {
        guard await MainActor.run(body: { SettingsStore.shared.agentActivityEnabled }) else {
            // Disabled in Settings: publish an empty state once (signature dedupe makes
            // repeats free) and skip the filesystem scan entirely.
            await MainActor.run { [weak self] in
                self?.apply(sessions: [], summary: AgentActivitySummary(sessions: []))
            }
            return
        }
        let now = Date()
        let scanned = await Task.detached(priority: .utility) { AgentActivityScanner.scan(now: now) }.value
        let summary = AgentActivitySummary(sessions: scanned)
        await MainActor.run { [weak self] in
            self?.apply(sessions: scanned, summary: summary)
        }
    }

    private func apply(sessions scanned: [AgentSession], summary: AgentActivitySummary) {
        // Actionable sessions drive the detail card; idle ones are hidden.
        let actionable = scanned.filter { $0.state != .idle }

        // A stable signature of what the UI shows: counts + per-session (source/project/state).
        // Re-publish only when it changes, so neither the pill nor the detail card
        // re-evaluates every 5s when nothing actually moved.
        let sig = "\(summary.actionableCount)|\(summary.workingCount)|\(summary.needsYourTurnCount)|\(summary.stalledCount)#"
            + actionable
                .map { "\($0.source)|\($0.projectLabel)|\($0.state)" }
                .sorted().joined(separator: ";")
        guard sig != lastSignature else { return }
        lastSignature = sig

        // Notify sessions that newly flipped to needs-your-turn. Keyed by identity, not
        // UUID (session ids are fresh each scan). The first apply after launch only seeds
        // the set - pre-existing needs-you sessions shouldn't fire a notification.
        let needsYou = actionable.filter { $0.state == .needsYourTurn }
        let needsYouKeys = Set(needsYou.map(Self.sessionKey))
        if !isFirstApply {
            for session in needsYou where !lastNeedsYouKeys.contains(Self.sessionKey(session)) {
                AgentAttentionNotifier.shared.notifyNeedsYou(
                    session.taskTitle ?? session.projectLabel
                )
            }
        }
        lastNeedsYouKeys = needsYouKeys
        isFirstApply = false

        self.summary = summary
        self.sessions = actionable
        lastActionableCount = summary.hasActivity ? summary.actionableCount : 0
        // Note: no presentation.reset() here - the notch is now always visible and hover
        // is owned by the window controller's cursor tracker; yanking it on activity
        // clearing would collapse the pill mid-read.
    }

    /// Stable identity across scans (session structs get fresh UUIDs every scan).
    private static func sessionKey(_ session: AgentSession) -> String {
        "\(session.source)|\(session.projectLabel)|\(session.taskTitle ?? "")"
    }

    deinit {
        scanTask?.cancel()
    }
}
