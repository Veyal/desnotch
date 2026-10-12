import Foundation

/// The pure decisions behind `NotchWindowController.updateInteractivity()`, pulled out so they
/// are unit-testable. Hover still has exactly one authority (that cursor-in-pill test); a
/// keyboard/VoiceOver "pin" is just a second input to the same decision, never a second
/// hover source.
enum PillInteractionPolicy {
    /// Whether the pill should be treated as hovered. The cursor, a keyboard pin, and an
    /// active voice session are inputs to this one decision, not separate hover sources.
    static func wantsHover(cursorInside: Bool, pinnedOpen: Bool, voiceActive: Bool) -> Bool {
        cursorInside || pinnedOpen || voiceActive
    }

    /// The panel takes mouse events only while the cursor is over the pill itself. A pin keeps
    /// the pill open but must not turn the rest of the transparent panel into a click blocker
    /// over the menu bar.
    static func acceptsMouse(cursorInside: Bool) -> Bool {
        cursorInside
    }

    /// The region (in screen coordinates) where the cursor counts as "over the pill": the
    /// pill's measured visual size, top-centered in the panel, with a little slack. nil until
    /// the pill has reported a size.
    static func interactiveRect(panelFrame: CGRect, pillContentSize: CGSize) -> CGRect? {
        guard pillContentSize.width > 0, pillContentSize.height > 0 else { return nil }
        let slack: CGFloat = 4
        // `NSRect.contains` excludes the top edge (y < maxY), and a cursor pinned against
        // the top of the screen reports y == screen top exactly - the most natural place
        // to point at a notch. Extend the rect a couple of points above the screen so the
        // absolute-top position still counts as inside.
        let topOverscan: CGFloat = 2
        let width = min(panelFrame.width, pillContentSize.width + slack * 2)
        let height = min(panelFrame.height, pillContentSize.height + slack)
        return CGRect(
            x: panelFrame.midX - width / 2,
            y: panelFrame.maxY - height,
            width: width,
            height: height + topOverscan
        )
    }
}
