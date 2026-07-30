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

    /// Grace period after the mouse leaves before clearing hover, so briefly crossing the
    /// edge doesn't collapse an expanded pill.
    private let hoverExitDelay: TimeInterval = 0.4
    private var exitTimer: Timer?
    private var volumeFlashTimer: Timer?

    public init() {}

    /// Called from the pill's `.onHover`.
    public func setHovering(_ hovering: Bool) {
        exitTimer?.invalidate()
        if hovering {
            isHovering = true
        } else {
            let timer = Timer(timeInterval: hoverExitDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.isHovering = false }
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

    /// Forget hover state (used when all activity clears).
    public func reset() {
        exitTimer?.invalidate()
        isHovering = false
    }
}
