import AppKit

/// Works out where to dock the pill for a given screen.
///
/// Real notch (`NSScreen.safeAreaInsets.top > 0`, macOS 12.1+ MacBooks): the notch's
/// horizontal extent is the gap between `auxiliaryTopLeftArea` and
/// `auxiliaryTopRightArea`, the two menu-bar-height regions macOS reserves on either
/// side of the notch. That gap is exactly the physical camera housing.
///
/// No notch (every other Mac, including this dev machine's Mac mini display): there is
/// no safe-area gap to hug, so we fall back to a fixed-width capsule floating
/// top-center of the screen, in the same location a notch would occupy. Final
/// geometry/animation polish against the *real* notch cutout needs a MacBook - see
/// README.
enum NotchGeometry {
    struct Placement {
        let frame: NSRect
        let hasPhysicalNotch: Bool
    }

    static let fallbackWidth: CGFloat = 220
    static let fallbackHeight: CGFloat = 32

    static func placement(for screen: NSScreen, expandedSize: CGSize) -> Placement {
        let hasNotch = screen.safeAreaInsets.top > 0

        let width: CGFloat
        if hasNotch,
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea
        {
            width = max(rightArea.minX - leftArea.maxX, expandedSize.width)
        } else {
            width = expandedSize.width
        }

        let height = hasNotch ? max(screen.safeAreaInsets.top, expandedSize.height) : expandedSize.height
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height - (hasNotch ? 0 : 6)

        return Placement(
            frame: NSRect(x: x, y: y, width: width, height: height),
            hasPhysicalNotch: hasNotch
        )
    }
}
