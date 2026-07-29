import AppKit
import Combine

/// Bridges `MediaRemoteBridge` updates into SwiftUI state.
///
/// Deliberately push-driven, not polled: `MediaRemoteBridge` only calls back when
/// the underlying adapter subprocess reports a real change, so this controller (and
/// therefore the UI) does zero work at rest - the timers below are one-shot and only
/// run while the pill is actually expanded or being hovered.
///
/// Visibility is a live-activity "toast," not a persistent panel: while media is
/// active, a small collapsed indicator stays at the notch, and the full pill expands
/// briefly on a real change (new track, or a play/pause flip) before auto-collapsing
/// again. Hovering the collapsed indicator re-expands it; moving the mouse away
/// re-collapses it after a short grace period.
@MainActor
final class NowPlayingController: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var isExpanded = false

    /// How long the pill stays expanded after a change event, or after the user
    /// interacts with a control, before auto-collapsing.
    private let autoCollapseDelay: TimeInterval = 2.5
    /// Grace period after the mouse leaves before collapsing, so briefly crossing
    /// the edge doesn't dismiss it.
    private let hoverExitDelay: TimeInterval = 0.4

    private var collapseTimer: Timer?
    private var isHovering = false
    private let bridge = MediaRemoteBridge.shared

    /// Whether there's anything to show at all - drives the collapsed indicator's
    /// own visibility, independent of whether it's currently expanded.
    var hasActiveMedia: Bool { info?.hasContent == true }

    init() {
        bridge.onNowPlayingChange = { [weak self] newInfo in
            self?.applyRemote(newInfo)
        }
    }

    private func applyRemote(_ newInfo: NowPlayingInfo?) {
        let previous = info
        info = newInfo

        guard let newInfo, newInfo.hasContent else {
            collapseTimer?.invalidate()
            isExpanded = false
            return
        }

        // Reveal only on an actual change (new track, or a play/pause flip) - not on
        // a redundant re-delivery of identical state, and not on the optimistic
        // local update from togglePlayPause() being echoed back once confirmed.
        if previous != newInfo {
            reveal()
        }
    }

    private func reveal() {
        isExpanded = true
        restartAutoCollapseTimer()
    }

    private func restartAutoCollapseTimer() {
        collapseTimer?.invalidate()
        guard !isHovering else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: autoCollapseDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.collapseUnlessHovering() }
        }
    }

    private func collapseUnlessHovering() {
        guard !isHovering else { return }
        isExpanded = false
    }

    /// Called from the pill's `.onHover` - the only way to manually reopen/dismiss it.
    func setHovering(_ hovering: Bool) {
        guard hasActiveMedia else { return }
        isHovering = hovering
        collapseTimer?.invalidate()
        if hovering {
            isExpanded = true
        } else {
            collapseTimer = Timer.scheduledTimer(withTimeInterval: hoverExitDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.collapseUnlessHovering() }
            }
        }
    }

    func togglePlayPause() {
        // Optimistic update: flip immediately rather than waiting for the real
        // MediaRemote round-trip (command subprocess -> target app -> notification
        // -> our stream subprocess -> us), which can take close to a second even
        // though the command subprocess itself completes in ~15ms (measured) - most
        // of the latency is downstream, outside this app's control. applyRemote()
        // reconciles with the real state once it arrives; if it already matches,
        // that arrival is a no-op rather than a second reveal pulse.
        guard var optimistic = info else { return }
        optimistic.isPlaying.toggle()
        info = optimistic
        restartAutoCollapseTimer()
        bridge.send(.togglePlayPause)
    }

    func next() {
        restartAutoCollapseTimer()
        bridge.send(.nextTrack)
    }

    func previous() {
        restartAutoCollapseTimer()
        bridge.send(.previousTrack)
    }
}
