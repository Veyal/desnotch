import AppKit

/// Works out where to dock the pill panel for a given screen and content size.
///
/// Real notch (`NSScreen.safeAreaInsets.top > 0`, macOS 12.1+ MacBooks): the panel is
/// anchored to the very top of the screen (status-bar level), overlapping the notch
/// region, matching how Dynamic-Island-style pills behave. Final pixel positioning
/// against a *real* notch cutout still needs verification on a MacBook - see README.
///
/// No notch (every other Mac, including this dev machine's display): the panel is also
/// anchored flush with the screen top, so the pill renders as a "fake notch" over the
/// menu bar top-center.
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

    /// Physical notch cutout size (points): height from `safeAreaInsets.top`, width from the
    /// gap between `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. nil on notch-less screens.
    /// The pill must never place content inside this rect - it is opaque hardware.
    public static func notchSize(for screen: NSScreen) -> CGSize? {
        notchSize(
            safeAreaTop: screen.safeAreaInsets.top,
            screenWidth: screen.frame.width,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width
        )
    }

    /// Pure form of `notchSize(for:)` so the rule is testable without a real `NSScreen`.
    public static func notchSize(
        safeAreaTop: CGFloat,
        screenWidth: CGFloat,
        auxiliaryLeftWidth: CGFloat?,
        auxiliaryRightWidth: CGFloat?
    ) -> CGSize? {
        guard safeAreaTop > 0 else { return nil }
        if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
            let width = screenWidth - left - right
            if width > 0 { return CGSize(width: width, height: safeAreaTop) }
        }
        // Auxiliary areas unavailable: use a generous default so content stays clear.
        return CGSize(width: 200, height: safeAreaTop)
    }

    /// Stable transparent host room for the expanded pill. The AppKit panel must never
    /// resize during an open/close animation, so it is large enough for every realistic
    /// stack (including spring overshoot) up front: width covers the full supported
    /// expanded-width range plus the lively overshoot, height covers a long stacked layout.
    /// The panel is transparent, shadowless and click-through everywhere except over the
    /// pill, so the extra surface costs nothing. Unusually tall content can still grow it
    /// downward (quantized, see `PillPanelSizingPolicy`), but collapse never shrinks it.
    /// Hit testing is based on the measured visible pill rect, not this transparent floor.
    /// Use `effectiveContentFloor(forScreenSize:)` for the value capped to a real screen.
    public static let contentFloor = CGSize(width: 520, height: 720)

    /// `contentFloor` capped so the panel never exceeds a small screen.
    public static func effectiveContentFloor(forScreenSize screen: CGSize) -> CGSize {
        CGSize(
            width: min(contentFloor.width, max(0, screen.width - shadowInsetX * 2)),
            height: min(contentFloor.height, max(0, screen.height - 40))
        )
    }

    /// Silhouette radii (points). `collapsedBottomRadius` and `topEar` should match the
    /// hardware cutout's proportions; they are unverified on physical notch hardware, so
    /// retune them here (one place) after checking on a MacBook (see TODO.md).
    public static let topEar: CGFloat = 6
    public static let collapsedBottomRadius: CGFloat = 10
    public static let expandedBottomRadius: CGFloat = 24

    /// Expanded content insets inside the silhouette: horizontal (clear of the ear flare),
    /// below the cutout, and above the bottom corners (kept >= the arc clearance so rows
    /// never touch the rounded corners).
    public static let contentInsetX: CGFloat = 16
    public static let contentTopGap: CGFloat = 8
    public static let contentBottomInset: CGFloat = 12

    /// The expanded pill's width: the user's preferred width, but never narrower than the
    /// cutout plus both wings (the black shape must always fully cover the hardware) nor than
    /// the minimized pill it grows from (`compactWidth`, which includes grown wings and the
    /// privacy lanes), so hovering never narrows the shape while it grows taller.
    /// Pure so the sizing rule is unit-testable.
    public static func expandedPillWidth(
        preferred: CGFloat, cutoutWidth: CGFloat, wingWidth: CGFloat, compactWidth: CGFloat = 0
    ) -> CGFloat {
        max(preferred, cutoutWidth + wingWidth * 2, compactWidth)
    }

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

    /// The display that hosts the pill. `identifier` is the user's Settings choice (nil for
    /// Automatic); see `DisplaySelection.preferredIndex` for the fallback order. Returns nil
    /// only if there are no screens at all.
    public static func preferredScreen(identifier: String? = nil) -> NSScreen? {
        let screens = NSScreen.screens
        let snapshots = screens.enumerated().map { ScreenSnapshot(screen: $1, index: $0) }
        return DisplaySelection.preferredIndex(in: snapshots, identifier: identifier).map { screens[$0] }
    }

    /// Stable identifier for a display: its CoreGraphics UUID, which survives reconnects and
    /// reboots (unlike the numeric display ID). nil if macOS cannot supply one.
    public static func displayIdentifier(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String?
        else { return nil }
        return string
    }

    public static func placement(for screen: NSScreen, windowSize: CGSize) -> Placement {
        placement(
            screenFrame: screen.frame,
            hasPhysicalNotch: screen.safeAreaInsets.top > 0,
            windowSize: windowSize
        )
    }

    /// Pure form of `placement(for:windowSize:)` so the anchoring rule is testable without a
    /// real `NSScreen`.
    public static func placement(
        screenFrame: CGRect, hasPhysicalNotch: Bool, windowSize: CGSize
    ) -> Placement {
        // Integral frame only: SwiftUI reports fractional content sizes, and a fractional
        // window height puts the top edge on a half pixel - which renders as a hairline of
        // wallpaper between the pill and the screen's top edge.
        let width = windowSize.width.rounded(.up)
        let height = windowSize.height.rounded(.up)
        let x = (screenFrame.midX - width / 2).rounded()

        // Flush with the screen top on every screen: a real notch hugs the hardware cutout,
        // and a notch-less screen gets a "fake notch" drawn over the menu bar top-center.
        let y = screenFrame.maxY - height

        return Placement(
            frame: NSRect(x: x, y: y, width: width, height: height),
            hasPhysicalNotch: hasPhysicalNotch
        )
    }
}
