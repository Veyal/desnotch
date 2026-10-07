import Combine
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
    private let scanInterval: TimeInterval
    private let settings: SettingsStore
    private let activity: PollingActivity
    private let scan: @Sendable (Date, Bool) -> [AgentSession]
    private var scanTask: Task<Void, Never>?
    private var isEnabled = false
    private var isSuspended = false
    private var cancellables = Set<AnyCancellable>()
    private var lastActionableCount = 0
    private var lastSignature = ""
    private var needsYouTracker = NeedsYouTracker()
    /// True until the first scan after launch or re-enable has seeded `needsYouTracker`.
    private(set) var isFirstApply = true

    public convenience init(presentation: NotchPillPresentation) {
        self.init(presentation: presentation, settings: .shared, activity: .shared)
    }

    /// Internal injection point so tests can drive start/stop without scanning real transcripts.
    init(
        presentation: NotchPillPresentation,
        settings: SettingsStore,
        activity: PollingActivity,
        scanInterval: TimeInterval = 5,
        scan: @escaping @Sendable (Date, Bool) -> [AgentSession] = { now, includeTitles in
            AgentActivityScanner.scan(now: now, includeTaskTitles: includeTitles)
        }
    ) {
        self.presentation = presentation
        self.settings = settings
        self.activity = activity
        self.scanInterval = scanInterval
        self.scan = scan

        // The loop exists only while the feature is enabled and someone could see the
        // result (not while the display/session is asleep), like `ClipboardController`
        // follows its setting instead of polling a flag.
        settings.$agentActivityEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.isEnabled = enabled
                if !enabled {
                    // Disabled in Settings: publish an empty state once (signature dedupe
                    // makes repeats free). Re-enabling re-seeds the needs-you notifications.
                    self.apply(sessions: [], summary: AgentActivitySummary(sessions: []))
                    self.isFirstApply = true
                    self.needsYouTracker.reset()
                    // Forget the signature too: with no sessions on both sides the first scan
                    // after re-enable would match it and return before seeding, leaving
                    // `isFirstApply` set so the next real needs-you flip is swallowed.
                    self.lastSignature = ""
                }
                self.updateScanning()
            }
            .store(in: &cancellables)
        // Titles are prompt-derived: switching them off must clear what is already on screen at
        // once (people do this right before screen sharing), not when the next scan lands.
        settings.$agentTaskTitlesEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, !enabled, self.sessions.contains(where: { $0.taskTitle != nil }) else { return }
                self.sessions = self.sessions.map { $0.withoutTaskTitle() }
                self.lastSignature = ""
            }
            .store(in: &cancellables)
        activity.$isSuspended
            .removeDuplicates()
            .sink { [weak self] suspended in
                self?.isSuspended = suspended
                self?.updateScanning()
            }
            .store(in: &cancellables)
    }

    /// Internal so tests can assert the loop follows the setting and the sleep gate.
    var isScanning: Bool { scanTask != nil }

    private func updateScanning() {
        if isEnabled && !isSuspended {
            guard scanTask == nil else { return }
            scanTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let delay = await self?.scanOnce() else { return }
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        } else {
            scanTask?.cancel()
            scanTask = nil
        }
    }

    /// One scan; returns how long to wait before the next one.
    private func scanOnce() async -> TimeInterval {
        let now = Date()
        let includeTitles = settings.agentTaskTitlesEnabled
        let scan = self.scan
        // A plain dispatch queue, not a Swift-concurrency task: the scan blocks on its OpenCode
        // sqlite subprocess and must not park a cooperative-pool thread while it does.
        let scanned = await withCheckedContinuation { (continuation: CheckedContinuation<[AgentSession], Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scan(now, includeTitles))
            }
        }
        // Disabled or suspended while the scan was in flight: its result is stale.
        guard !Task.isCancelled else { return scanInterval }
        apply(sessions: scanned, summary: AgentActivitySummary(sessions: scanned))
        return activity.scaled(scanInterval)
    }

    private func apply(sessions scanned: [AgentSession], summary: AgentActivitySummary) {
        // Actionable sessions drive the detail card; idle ones are hidden.
        let actionable = scanned.filter { $0.state != .idle }

        // A stable signature of what the UI shows: counts + per-session (source/project/
        // title/state/elapsed-minutes). The minutes bucket makes the rows' relative times and
        // recency ordering refresh about once a minute per session - without it a
        // working session's "3s" froze until its *state* changed. Re-publish only when
        // the signature changes, so the pill still doesn't re-evaluate every 5s idle.
        let sig = "\(summary.actionableCount)|\(summary.workingCount)|\(summary.needsYourTurnCount)|\(summary.stalledCount)#"
            + actionable
                .map { "\($0.source)|\($0.projectLabel)|\($0.taskTitle ?? "")|\($0.state)|\(AgentActivityPresentation.freshness(for: $0.lastActivity, now: Date()))" }
                .sorted().joined(separator: ";")
        guard sig != lastSignature else { return }
        lastSignature = sig

        // Notify sessions that newly flipped to needs-your-turn. Keyed by the session's
        // stable identity, not UUID (session ids are fresh each scan) and not project/title
        // (two sessions in one project would collide). The first apply after launch only seeds
        // the set - pre-existing needs-you sessions shouldn't fire a notification. The body is
        // the project label only: a notification outlives the pill's Privacy mode and lands in
        // Notification Center, so prompt-derived text never goes there.
        let needsYou = actionable.filter { $0.state == .needsYourTurn }
        let fresh = needsYouTracker.update(
            needsYou: Set(needsYou.map(\.identityKey)),
            present: Set(scanned.map(\.identityKey)),
            now: Date()
        )
        if !isFirstApply, settings.notifyAgentNeedsYou {
            for session in needsYou where fresh.contains(session.identityKey) {
                AgentAttentionNotifier.shared.notifyNeedsYou(session.projectLabel)
            }
        }
        isFirstApply = false

        self.summary = summary
        self.sessions = actionable
        lastActionableCount = summary.hasActivity ? summary.actionableCount : 0
        // Note: no presentation.reset() here - the notch is now always visible and hover
        // is owned by the window controller's cursor tracker; yanking it on activity
        // clearing would collapse the pill mid-read.
    }

    deinit {
        scanTask?.cancel()
    }
}

/// Which sessions newly flipped to needs-you, across scans. A key already notified survives a scan
/// that merely drops its session (a failed OpenCode query, an unreadable transcript) for `grace`,
/// so the session reappearing is not "new" and does not notify twice; a session that is present
/// in any other state has really left needs-you, so its next flip notifies.
struct NeedsYouTracker {
    static let grace: TimeInterval = 60
    private var lastSeen: [String: Date] = [:]

    /// Returns the keys in `needsYou` that were not already tracked, then records this scan.
    /// `present` is every session key the scan returned, in any state.
    mutating func update(needsYou: Set<String>, present: Set<String>, now: Date) -> Set<String> {
        let fresh = needsYou.filter { lastSeen[$0] == nil }
        for (key, seen) in lastSeen where present.contains(key) || now.timeIntervalSince(seen) > Self.grace {
            lastSeen[key] = nil
        }
        for key in needsYou { lastSeen[key] = now }
        return Set(fresh)
    }

    mutating func reset() { lastSeen.removeAll() }
}
