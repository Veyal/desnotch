import Foundation

/// Tracks the pill's hover state, shared by both content modes.
///
/// The pill minimizes by default and expands only while the pointer is over it (`isHovering`);
/// a short exit grace avoids flicker on edge crossings. Timers run on `.common` run-loop mode
/// so they keep firing during menu tracking.
@MainActor
public final class NotchPillPresentation: ObservableObject {
    @Published public private(set) var isHovering = false

    /// Momentary volume readout (0...1) after a scroll-to-adjust gesture; auto-clears.
    @Published public private(set) var volumeFlash: Float?

    /// Brief forced-open state so the user sees a change land (a file dropped into the
    /// tray, the power cable plugged/unplugged) even without hovering; auto-clears.
    @Published public private(set) var openFlash = false

    /// Grace period after the mouse leaves before clearing hover, so briefly crossing the
    /// edge doesn't collapse an expanded pill. User-configurable (Settings > Collapse delay);
    /// read at scheduling time so changes apply to the next exit immediately.
    private var hoverExitDelay: TimeInterval { SettingsStore.shared.hoverCollapseDelay }
    private var exitTimer: Timer?
    private var volumeFlashTimer: Timer?
    private var openFlashTimer: Timer?

    public init() {}

    /// Called by the window controller's cursor tracker on every relevant mouse event -
    /// the single authority for hover (the SwiftUI `.onHover` path was removed: its exit
    /// events raced panel resizes and could strand the pill closed under a stationary
    /// cursor, or open with the cursor long gone). Publishes only on real changes so the
    /// event-rate calls stay cheap.
    public func setHovering(_ hovering: Bool) {
        if hovering {
            exitTimer?.invalidate()
            exitTimer = nil
            if !isHovering {
                isHovering = true
            }
        } else {
            guard isHovering, exitTimer == nil else { return }
            let owner = self
            let timer = Timer(timeInterval: hoverExitDelay, repeats: false) { [weak owner] _ in
                Task { @MainActor in
                    owner?.exitTimer = nil
                    owner?.isHovering = false
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            exitTimer = timer
        }
    }

    /// Show the volume level briefly after a scroll adjustment.
    public func flashVolume(_ level: Float) {
        volumeFlash = level
        volumeFlashTimer?.invalidate()
        let owner = self
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak owner] _ in
            Task { @MainActor in owner?.volumeFlash = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeFlashTimer = timer
    }

    /// Hold the pill open briefly so a state change is visible without hovering.
    public func flashOpen(for duration: TimeInterval = 1.5) {
        openFlash = true
        openFlashTimer?.invalidate()
        let owner = self
        let timer = Timer(timeInterval: duration, repeats: false) { [weak owner] _ in
            Task { @MainActor in owner?.openFlash = false }
        }
        RunLoop.main.add(timer, forMode: .common)
        openFlashTimer = timer
    }

    /// Forget hover state (used when all activity clears).
    public func reset() {
        exitTimer?.invalidate()
        isHovering = false
    }
}
