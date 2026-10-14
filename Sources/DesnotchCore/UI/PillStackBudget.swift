import CoreGraphics

/// How many rows each list section may show given how tall a screen is.
///
/// `PillLimits` bounds each list on its own, but a user with every section enabled and a
/// few items in each could still stack past a 13" display (the expanded pill is not
/// scrollable on purpose: scrolling over it adjusts the volume). This picks the first of three
/// fixed tiers whose estimated stack fits the screen, so the lower, lower-priority lists
/// shrink first and the choice is a pure function of counts and the screen (no layout
/// feedback loop with the measured size).
struct PillRowCaps: Equatable {
    var agents: Int
    var processes: Int
    var tray: Int
    var clipboard: Int

    /// The per-list maximums (`PillLimits`).
    static let full = PillRowCaps(
        agents: PillLimits.agentRows, processes: PillLimits.processRows,
        tray: PillLimits.trayRows, clipboard: PillLimits.clipboardRows
    )
    static let reduced = PillRowCaps(agents: 2, processes: 2, tray: 2, clipboard: 2)
    static let minimal = PillRowCaps(agents: 1, processes: 1, tray: 1, clipboard: 1)

    /// The roomiest tier whose estimated stack fits `maxHeight` (the last tier when none
    /// does). A nil/non-finite `maxHeight` means unlimited.
    static func fitting(_ stack: PillStackEstimate, maxHeight: CGFloat?) -> PillRowCaps {
        guard let maxHeight, maxHeight.isFinite else { return .full }
        for tier in [PillRowCaps.full, .reduced] where stack.height(caps: tier) <= maxHeight {
            return tier
        }
        return .minimal
    }
}

/// Coarse height model of the expanded stack, from the row-height tokens (measured against
/// renders; it errs a few percent high so a tier is chosen early rather than late).
struct PillStackEstimate: Equatable {
    var topInset: CGFloat
    var hasNotification = false
    var hasMedia = false
    var hasTimer = false
    var agents = 0
    var processes = 0
    var hasCalendar = false
    var hasReminders = false
    var hasBattery = false
    var clipboard = 0
    var trayEnabled = false
    var tray = 0
    var hasVoice = false
    var voiceState: VoiceState? = nil
    var hasTalk = false

    static let notificationHeight = PillRowHeight.tall
    static let mediaHeight: CGFloat = 80
    static let timerHeight = PillRowHeight.tall
    static let calendarHeight: CGFloat = 36
    static let remindersHeight: CGFloat = 60
    static let batteryHeight: CGFloat = 28
    static let privacyHeight: CGFloat = 32
    static let emptyTrayHeight: CGFloat = 72
    /// A divider with the spacing around it.
    static let dividerHeight: CGFloat = 14
    static let voiceHeight = VoiceCardLayout.sectionHeightBudget
    static let voiceApprovalHeight = VoiceCardLayout.approvalHeightBudget

    private static func list(rows: Int, rowHeight: CGFloat) -> CGFloat {
        guard rows > 0 else { return 0 }
        return PillRowHeight.compact + PillSpace.xs + CGFloat(rows) * (rowHeight + PillSpace.xs)
    }

    func height(caps: PillRowCaps) -> CGFloat {
        var sections: [CGFloat] = []
        if hasVoice {
            sections.insert(
                voiceState == .awaitingApproval ? Self.voiceApprovalHeight : Self.voiceHeight,
                at: 0
            )
        }
        if hasNotification { sections.append(Self.notificationHeight) }
        if hasMedia { sections.append(Self.mediaHeight) }
        if hasTimer { sections.append(Self.timerHeight) }
        if agents > 0 {
            sections.append(Self.list(rows: min(agents, caps.agents), rowHeight: PillRowHeight.standard))
        }
        if processes > 0 {
            sections.append(Self.list(rows: min(processes, caps.processes), rowHeight: PillRowHeight.listRow))
        }
        if hasCalendar { sections.append(Self.calendarHeight) }
        if hasReminders { sections.append(Self.remindersHeight) }
        if hasBattery { sections.append(Self.batteryHeight) }
        if clipboard > 0 {
            sections.append(Self.list(rows: min(clipboard, caps.clipboard), rowHeight: PillRowHeight.listRow))
        }
        if hasTalk { sections.append(Self.privacyHeight) }
        sections.append(Self.privacyHeight)
        if trayEnabled {
            sections.append(
                tray > 0
                    ? Self.list(rows: min(tray, caps.tray), rowHeight: PillRowHeight.listRow)
                    : Self.emptyTrayHeight
            )
        }
        let dividers = CGFloat(max(0, sections.count - 1)) * Self.dividerHeight
        return topInset + sections.reduce(0, +) + dividers + NotchGeometry.contentBottomInset
    }
}
