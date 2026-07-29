import Foundation

/// Tracks the pill's hover state, shared by both content modes.
///
/// The pill minimizes by default and expands only while the pointer is over it (`isHovering`);
/// a short exit grace avoids flicker on edge crossings. Timers run on `.common` run-loop mode
/// so they keep firing during menu tracking.
@MainActor
public final class NotchPillPresentation: ObservableObject {
    @Published public private(set) var isHovering = false

    /// Grace period after the mouse leaves before clearing hover, so briefly crossing the
    /// edge doesn't collapse an expanded pill.
    private let hoverExitDelay: TimeInterval = 0.4
    private var exitTimer: Timer?

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

    /// Forget hover state (used when all activity clears).
    public func reset() {
        exitTimer?.invalidate()
        isHovering = false
    }
}
