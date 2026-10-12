import Foundation

/// Which indicator a collapsed wing shows. Indicators are identity-keyed, so one handing
/// over to another (media -> timer, a timer displaced to the other wing) animates as a swap
/// instead of snapping.
enum WingIndicator: Hashable {
    case media, timer, hotProcess, calendar, reminder, agent, notification, volume, voice
}

/// Everything the wing selection depends on.
struct WingInputs: Equatable {
    var volumeActive = false
    var hasMedia = false
    var hasTimer = false
    var hasAgents = false
    var hasHotProcesses = false
    var hasNotification = false
    var calendarImminent = false
    var reminderUrgent = false
    /// Nil while voice is idle. Defaults to nil so existing callers keep today's wings.
    var voiceState: VoiceState? = nil
}

/// The collapsed pill's wing priorities, as a pure function so a refactor cannot change which
/// indicator wins. One indicator per wing. Left: the volume readout, then media (it has
/// controls), an active focus timer, a stuck-process warning, an imminent meeting, and an
/// urgent reminder. Right: the volume percent, agents, a timer displaced by media,
/// notifications, then whichever urgent item the left wing displaced. Anything squeezed out is
/// one hover away.
enum WingSelection {
    static func select(_ i: WingInputs) -> (left: WingIndicator?, right: WingIndicator?) {
        (left(i), right(i))
    }

    private static func left(_ i: WingInputs) -> WingIndicator? {
        if i.voiceState != nil { return .voice }
        if i.volumeActive { return .volume }
        if i.hasMedia { return .media }
        if i.hasTimer { return .timer }
        if i.hasHotProcesses { return .hotProcess }
        if i.calendarImminent { return .calendar }
        if i.reminderUrgent { return .reminder }
        return nil
    }

    private static func right(_ i: WingInputs) -> WingIndicator? {
        if i.voiceState == .listening || i.voiceState == .awaitingApproval { return .voice }
        if i.volumeActive { return .volume }
        if i.hasAgents { return .agent }
        if i.hasMedia && i.hasTimer { return .timer }
        if i.hasNotification { return .notification }
        if i.hasMedia && i.hasHotProcesses { return .hotProcess }
        if !i.hasMedia && i.hasHotProcesses && i.calendarImminent { return .calendar }
        if i.reminderUrgent && (i.hasMedia || i.hasHotProcesses || i.calendarImminent) { return .reminder }
        return nil
    }
}

/// How wide a collapsed wing must be for its indicator to keep air on both sides, and the
/// extra lane the mic/camera dots claim. The wing slot is 44pt (`NotchPillView.wingWidth`),
/// of which the shape's top ear eats `NotchGeometry.topEar` on the outer edge; most
/// indicators (a single 14-18pt glyph) fit with 10pt to spare, but the focus timer's ring +
/// "25m" label and a two-digit agent count are wider. Rather than crowd the edge, the wings
/// grow symmetrically (so the hardware cutout gap stays centered) by `extraWidth`.
/// Widths are measured system-font values (see `WingMetricsTests`), rounded up.
enum WingMetrics {
    /// The wing slot every indicator is laid out in.
    static let baseWidth: CGFloat = 44
    /// Minimum clear space between a transient indicator (the volume readout) and either edge
    /// of the wing's visible area.
    static let minimumInset: CGFloat = 5
    /// The same for the persistent single-glyph indicators: a 16-18pt glyph in the 44pt wing
    /// keeps 10-11pt (the base width is sized for it), which reads as 12-15pt on screen because
    /// glyphs are narrower than their boxes.
    static let persistentInset: CGFloat = 10
    /// The text-bearing wings (focus timer label, agent count) fill their box, so they get a
    /// touch more than a glyph does to read at the same distance from the shape's rounded edge.
    static let textInset: CGFloat = 13
    /// Width added on EACH side of the compact pill while the mic or camera is in use, so
    /// the in-use dots live in their own lane instead of on top of a wing indicator.
    static let privacyLane: CGFloat = 14

    /// Focus-timer wing: the 14pt ring (its 2pt track stroke overhangs the frame by 1pt on
    /// each side, so 16pt on screen), a 2pt gap, then a label up to "50m" (22.6pt at 10pt
    /// semibold, monospaced digits).
    static let timerRingWidth: CGFloat = 16
    static let timerGap: CGFloat = 2
    static let timerLabelWidth: CGFloat = 23
    /// Agent wing: 16pt glyph box, 4pt gap, then ~8pt per count character (12pt bold).
    static let agentGlyphWidth: CGFloat = 16
    static let agentGap: CGFloat = 4
    static let agentCharacterWidth: CGFloat = 8

    static func contentWidth(
        of indicator: WingIndicator, timerShowsLabel: Bool, agentLabelLength: Int
    ) -> CGFloat {
        switch indicator {
        case .media: return 18
        case .timer:
            return timerShowsLabel
                ? timerRingWidth + timerGap + timerLabelWidth
                : timerRingWidth
        case .hotProcess, .calendar, .reminder, .notification, .voice: return 16
        case .agent:
            return agentGlyphWidth + agentGap + agentCharacterWidth * CGFloat(max(1, agentLabelLength))
        case .volume: return 23 // speaker glyph (left) / up to "100" (right)
        }
    }

    /// Clear space an indicator keeps from either edge of the wing's visible area.
    static func inset(of indicator: WingIndicator, timerShowsLabel: Bool = true) -> CGFloat {
        switch indicator {
        case .volume: return minimumInset
        case .timer: return timerShowsLabel ? textInset : persistentInset // ring alone is a glyph
        case .agent: return textInset
        case .voice: return persistentInset
        default: return persistentInset
        }
    }

    /// Width to add on each side of the base wing so the widest shown indicator keeps its
    /// `inset(of:)` clear on both edges. 0 for every single-glyph indicator.
    static func extraWidth(
        left: WingIndicator?, right: WingIndicator?, timerShowsLabel: Bool, agentLabelLength: Int
    ) -> CGFloat {
        let required = [left, right].compactMap { $0 }.map {
            contentWidth(of: $0, timerShowsLabel: timerShowsLabel, agentLabelLength: agentLabelLength)
                + inset(of: $0, timerShowsLabel: timerShowsLabel) * 2 + NotchGeometry.topEar
        }.max() ?? 0
        return max(0, (required - baseWidth).rounded(.up))
    }
}

/// Short label for the wing's agent count: two digits fit with air, beyond 99 it reads "99+".
enum PillCountLabel {
    static let cap = 99

    static func text(_ count: Int) -> String {
        count > cap ? "\(cap)+" : "\(max(0, count))"
    }
}
