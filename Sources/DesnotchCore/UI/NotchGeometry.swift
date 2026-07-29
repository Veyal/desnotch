import AppKit

/// Works out where to dock the pill panel for a given screen and content size.
///
/// Real notch (`NSScreen.safeAreaInsets.top > 0`, macOS 12.1+ MacBooks): the panel is
/// anchored to the very top of the screen (status-bar level), overlapping the notch
/// region, matching how Dynamic-Island-style pills behave. Final pixel positioning
/// against a *real* notch cutout still needs verification on a MacBook - see README.
///
/// No notch (every other Mac, including this dev machine's display): the panel sits
/// fully below the menu bar instead of straddling it, top-centered.
///
/// The panel is sized to the pill's measured content size plus a transparent inset
/// reserved on the sides and bottom for the spring overshoot and drop shadow (the pill
/// content is top-anchored, so no inset is needed above it).
public enum NotchGeometry {
    public struct Placement {
        public let frame: NSRect
        public let hasPhysicalNotch: Bool

        public init(frame: NSRect, hasPhysicalNotch: Bool) {
            self.frame = frame
            self.hasPhysicalNotch = hasPhysicalNotch
        }
    }

    public static let fallbackWidth: CGFloat = 220
    public static let fallbackHeight: CGFloat = 32

    /// A content size generous enough to fit the expanded pill (now-playing artwork + title/
    /// artist + 3 transport buttons, or an agent headline). The panel is sized to at least
    /// this so that collapsing/expanding does NOT change the panel size mid-animation - a
    /// width change during the spring is what produced the horizontal "slide" feel. The panel
    /// only ever grows beyond this if content genuinely needs more room.
    public static let contentFloor = CGSize(width: 340, height: 60)

    /// Transparent room reserved around the pill so overshoot/shadow never clip.
    public static let shadowInsetX: CGFloat = 12
    public static let shadowInsetBottom: CGFloat = 16

    /// Sizing used before SwiftUI reports a real content size (avoids an initial 0×0 panel).
    public static var fallbackWindowSize: CGSize {
        windowSize(forContent: CGSize(width: fallbackWidth, height: fallbackHeight))
    }

    public static func windowSize(forContent content: CGSize) -> CGSize {
        CGSize(
            width: content.width + shadowInsetX * 2,
            height: content.height + shadowInsetBottom
        )
    }

    /// Prefers a screen with a physical notch (where the pill belongs), falling back to
    /// the key/main screen. Returns nil only if there are no screens at all.
    public static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    public static func placement(for screen: NSScreen, windowSize: CGSize) -> Placement {
        let hasNotch = screen.safeAreaInsets.top > 0
        let width = windowSize.width
        let height = windowSize.height
        let x = screen.frame.midX - width / 2

        let y: CGFloat
        if hasNotch {
            // Anchor into the top notch region; real-notch pixel fit needs a MacBook.
            y = screen.frame.maxY - height
        } else {
            // Sit fully below the menu bar (the top gap between visibleFrame and frame),
            // with a small breathing margin - don't straddle the menu bar.
            let menuBarTop = screen.visibleFrame.maxY
            y = menuBarTop - height - 6
        }

        return Placement(
            frame: NSRect(x: x, y: y, width: width, height: height),
            hasPhysicalNotch: hasNotch
        )
    }
}
