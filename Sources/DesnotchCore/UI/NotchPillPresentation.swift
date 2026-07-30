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

    /// Brief forced-open state after a successful file drop, so the user sees the item
    /// land in the tray even if the cursor immediately leaves; auto-clears.
    @Published public private(set) var dropFlash = false

    /// Grace period after the mouse leaves before clearing hover, so briefly crossing the
    /// edge doesn't collapse an expanded pill.
    private let hoverExitDelay: TimeInterval = 0.4
    private var exitTimer: Timer?
    private var volumeFlashTimer: Timer?
    private var dropFlashTimer: Timer?

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
            let timer = Timer(timeInterval: hoverExitDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.exitTimer = nil
                    self?.isHovering = false
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
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.volumeFlash = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeFlashTimer = timer
    }

    /// Hold the pill open briefly after a drop so the added tray item is visible.
    public func flashDropConfirmation() {
        dropFlash = true
        dropFlashTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dropFlash = false }
        }
        RunLoop.main.add(timer, forMode: .common)
        dropFlashTimer = timer
    }

    /// Forget hover state (used when all activity clears).
    public func reset() {
        exitTimer?.invalidate()
        isHovering = false
    }
}
