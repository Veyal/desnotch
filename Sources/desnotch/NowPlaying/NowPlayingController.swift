import AppKit
import Combine

/// Bridges `MediaRemoteBridge` change notifications into SwiftUI state.
///
/// Deliberately notification-driven, not polled: `MediaRemoteBridge` only calls back
/// when MediaRemote posts a change notification, so this controller (and therefore the
/// UI) does zero work at rest. The only timer here is the one-shot idle-close timer
/// below, which is scheduled/cancelled in response to state changes rather than
/// ticking continuously.
@MainActor
final class NowPlayingController: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var isVisible = false

    /// How long the pill stays open after playback stops/pauses before it animates closed.
    private let idleTimeout: TimeInterval = 8

    private var idleTimer: Timer?
    private let bridge = MediaRemoteBridge.shared

    init() {
        bridge.onNowPlayingChange = { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    private func refresh() {
        bridge.fetchNowPlayingInfo { [weak self] newInfo in
            guard let self else { return }
            self.apply(newInfo)
        }
    }

    private func apply(_ newInfo: NowPlayingInfo?) {
        info = newInfo

        guard let newInfo, newInfo.hasContent else {
            scheduleHide()
            return
        }

        if newInfo.isPlaying {
            idleTimer?.invalidate()
            idleTimer = nil
            isVisible = true
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        guard isVisible else { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isVisible = false
            }
        }
    }

    func togglePlayPause() {
        bridge.send(.togglePlayPause)
    }

    func next() {
        bridge.send(.nextTrack)
    }

    func previous() {
        bridge.send(.previousTrack)
    }
}
