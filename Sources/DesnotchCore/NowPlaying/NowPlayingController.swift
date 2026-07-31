import AppKit
import Combine

/// Bridges `MediaRemoteBridge` updates into SwiftUI state.
///
/// Deliberately push-driven, not polled: `MediaRemoteBridge` only calls back when
/// the underlying adapter subprocess reports a real change, so this controller (and
/// therefore the UI) does zero work at rest.
///
/// Visibility lives in `NotchPillPresentation` (shared with agent activity); this
/// type only owns the now-playing *data* and tells the presentation when to reveal
/// (on a real change) or keep the pill open (on a user control tap).
@MainActor
public final class NowPlayingController: ObservableObject {
    @Published public private(set) var info: NowPlayingInfo?

    public let presentation: NotchPillPresentation

    /// How long after a transport tap we wait for the stream to confirm the new state
    /// before falling back to a one-shot `get` as ground truth.
    private let reconciliationDelay: TimeInterval = 1.5
    /// Transport taps within this window are coalesced so a rapid double-tap can't
    /// spawn an unbounded pile of perl `send` processes or desync optimistic state.
    private let toggleCoalesceWindow: TimeInterval = 0.25

    private var reconcileTimer: Timer?
    private var pausedExpiryTimer: Timer?
    private var lastToggleAt: Date?
    private let bridge = MediaRemoteBridge.shared

    /// Whether there's anything to show at all - drives the collapsed indicator's
    /// own visibility, independent of whether it's currently expanded.
    public var hasActiveMedia: Bool { info?.hasContent == true }

    public init(presentation: NotchPillPresentation) {
        self.presentation = presentation
        bridge.onNowPlayingChange = { [weak self] newInfo in
            self?.applyRemote(newInfo)
        }
    }

    private func applyRemote(_ newInfo: NowPlayingInfo?) {
        info = newInfo

        // A real update has arrived, so a pending optimistic toggle is confirmed; no
        // need for the reconciliation fallback.
        reconcileTimer?.invalidate()
        updatePausedExpiry()
        // Expansion is driven by the view (needs-attention || hover), so nothing to push here.
    }

    /// The stream is change-driven, so a paused item never gets another update - a
    /// timer is the only way to notice it has gone stale. Sessions that arrive
    /// already past retention (e.g. app launch with hours-old browser residue) are
    /// dropped immediately.
    private func updatePausedExpiry() {
        pausedExpiryTimer?.invalidate()
        pausedExpiryTimer = nil
        guard let info, info.hasContent, let expiry = info.pausedExpiry() else { return }
        let delay = expiry.timeIntervalSinceNow
        guard delay > 0 else {
            self.info = nil
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let current = self.info, !current.isPlaying else { return }
                self.info = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pausedExpiryTimer = timer
    }

    public func togglePlayPause() {
        // Optimistic update: flip immediately rather than waiting for the real
        // MediaRemote round-trip (command subprocess -> target app -> notification
        // -> our stream subprocess -> us), which can take close to a second even
        // though the command subprocess itself completes in ~15ms (measured) - most
        // of the latency is downstream, outside this app's control. applyRemote()
        // reconciles with the real state once it arrives; if it already matches,
        // that arrival is a no-op rather than a second reveal pulse.
        guard var optimistic = info else { return }

        // Coalesce rapid taps: if a toggle landed very recently, ignore the repeat entirely
        // (don't flip UI, don't send) so we neither spawn overlapping perl `send` processes
        // nor desync the optimistic state from the single toggle that was actually sent.
        let now = Date()
        if let last = lastToggleAt, now.timeIntervalSince(last) < toggleCoalesceWindow {
            return
        }
        lastToggleAt = now
        // Re-anchor the position at the flip moment: keeps the timeline continuous
        // and stamps when a pause happened, which is what paused-retention counts from.
        optimistic.elapsed = optimistic.position(at: now)
        optimistic.isPlaying.toggle()
        optimistic.elapsedAt = now
        info = optimistic
        updatePausedExpiry()
        bridge.send(.togglePlayPause)
        scheduleReconciliation()
    }

    public func next() {
        bridge.send(.nextTrack)
        scheduleReconciliation()
    }

    public func previous() {
        bridge.send(.previousTrack)
        scheduleReconciliation()
    }

    /// Seek to an absolute position (dragging the pill's timeline). Optimistic like
    /// `togglePlayPause`: the local elapsed/timestamp move immediately so the bar
    /// doesn't snap back while the MediaRemote round-trip completes; the stream (or
    /// the `get` fallback) then confirms the real position.
    public func seek(to seconds: TimeInterval) {
        guard var optimistic = info else { return }
        let clamped = optimistic.duration.map { min(max(0, seconds), $0) } ?? max(0, seconds)
        optimistic.elapsed = clamped
        optimistic.elapsedAt = Date()
        info = optimistic
        updatePausedExpiry()
        bridge.seek(to: clamped)
        scheduleReconciliation()
    }

    /// If the stream hasn't confirmed a transport command by `reconciliationDelay`,
    /// run the adapter `get` once and treat its result as ground truth. This covers
    /// the case where a command was dropped or the change-driven stream missed the
    /// update - without it the optimistic UI could stay wrong indefinitely.
    private func scheduleReconciliation() {
        reconcileTimer?.invalidate()
        let timer = Timer(timeInterval: reconciliationDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reconcileWithGet() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    private func reconcileWithGet() {
        bridge.getOnce { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard let result else { return }
                if result.hasContent {
                    self.info = result
                    self.updatePausedExpiry()
                } else if !self.hasActiveMedia {
                    self.info = nil
                }
            }
        }
    }
}
