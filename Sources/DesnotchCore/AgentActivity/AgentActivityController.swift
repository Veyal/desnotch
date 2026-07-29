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

        self.summary = summary
        self.sessions = actionable

        // When activity fully clears, clear hover so the pill hides cleanly.
        guard summary.hasActivity else {
            lastActionableCount = 0
            presentation.reset()
            return
        }

        lastActionableCount = summary.actionableCount
    }

    deinit {
        scanTask?.cancel()
    }
}
