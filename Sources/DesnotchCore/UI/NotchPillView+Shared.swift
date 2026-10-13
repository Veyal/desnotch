import SwiftUI

/// Layout flags, privacy helpers and small pieces shared by several sections.
extension NotchPillView {
    /// How many rows each list shows: the roomiest tier whose estimated stack fits the screen
    /// (`PillRowCaps`). Depends only on counts and the screen, never on the measured size.
    var rowCaps: PillRowCaps {
        PillRowCaps.fitting(stackEstimate, maxHeight: maxContentHeight)
    }

    var stackEstimate: PillStackEstimate {
        PillStackEstimate(
            topInset: effectiveNotch.height + NotchGeometry.contentTopGap,
            hasNotification: hasNotification,
            hasMedia: hasMedia,
            hasTimer: hasTimer,
            agents: hasAgents ? agentActivity.sessions.count : 0,
            processes: hasHotProcesses ? processMonitor.hotProcesses.count : 0,
            hasCalendar: showCalendarRow,
            hasReminders: showReminderSection,
            hasBattery: showBatteryRow && battery.state != nil,
            clipboard: hasClipboard ? clipboard.entries.count : 0,
            trayEnabled: settings.trayEnabled,
            tray: tray.items.count,
            hasVoice: hasVoice,
            voiceState: voiceState,
            hasTalk: hasTalkAction
        )
    }

    /// Height of the whole expanded layer the shape springs to while the sections are still
    /// mounting, from the stack estimate. That model errs a few percent high on purpose (it picks
    /// row-cap tiers early), so it is trimmed to the measured renders; the shell's spring retargets
    /// the remaining few points when the real layout takes over.
    var estimatedExpandedHeight: CGFloat {
        let estimate = stackEstimate
        let stack = estimate.height(caps: rowCaps) - estimate.topInset - NotchGeometry.contentBottomInset
        return estimate.topInset + max(0, stack) * Self.placeholderStackScale + NotchGeometry.contentBottomInset
    }

    /// Measured expanded stacks run 3-10% under `PillStackEstimate` (media-only ~10%, mixed
    /// stacks ~6%, tray/agent-heavy lists about equal).
    private static let placeholderStackScale: CGFloat = 0.94

    /// Whether `kind` has anything to render right now (mirrors `pillContent`'s conditions); used
    /// only to skip empty stages while the stack is mounting.
    func hasSection(_ kind: PillSectionKind) -> Bool {
        switch kind {
        case .voice: return hasVoice
        case .notification: return hasNotification
        case .media: return hasMedia
        case .timer: return hasTimer
        case .agents: return hasAgents
        case .processes: return hasHotProcesses
        case .calendar: return showCalendarRow
        case .reminders: return showReminderSection
        case .battery: return showBatteryRow && battery.state != nil
        case .clipboard: return hasClipboard
        case .talk: return hasTalkAction
        case .privacy: return true
        case .tray: return settings.trayEnabled
        }
    }

    /// Per-side width the wings grow by so a wide indicator (timer label, two-digit agent
    /// count) keeps air at both edges. Always symmetric, so the cutout gap stays centered.
    var wingExtraWidth: CGFloat {
        let selection = WingSelection.select(wingInputs)
        return WingMetrics.extraWidth(
            left: selection.left,
            right: selection.right,
            timerShowsLabel: focusTimer.state != .completed,
            agentLabelLength: PillCountLabel.text(agentActivity.summary.actionableCount).count
        )
    }

    /// Lane reserved on each side while the mic or camera is in use (see `WingMetrics`).
    var privacyLaneWidth: CGFloat {
        mediaUse.micInUse || mediaUse.cameraInUse ? WingMetrics.privacyLane : 0
    }

    var compactWidth: CGFloat {
        effectiveNotch.width + 2 * (Self.wingWidth + wingExtraWidth + privacyLaneWidth)
    }

    var showCalendarRow: Bool {
        settings.calendarEnabled && (calendar.nextEvent != nil || calendar.accessState == .denied)
    }

    var showReminderSection: Bool { settings.remindersEnabled }

    var showBatteryRow: Bool { settings.batteryEnabled }

    /// Any section that renders between the notification row and the privacy row.
    var hasMiddleSection: Bool {
        hasMedia || hasTimer || hasAgents || hasHotProcesses || hasClipboard || showCalendarRow
            || showReminderSection
            || (showBatteryRow && battery.state != nil)
    }

    var hasContentBeforePrivacyAction: Bool {
        hasVoice || hasNotification || hasMiddleSection || hasTalkAction
    }

    /// Blank sensitive strings while privacy mode is on (screen sharing/recording).
    /// Scope: now-playing title/artist, agent task titles, calendar event titles, reminder titles,
    /// clipboard previews, and tray filenames - keep any new user-content string behind this too.
    func privacyRedacted(_ text: String, fallback: String) -> String {
        settings.privacyModeEnabled ? fallback : text
    }

    /// Generic tray label that keeps only the (non-identifying) file type.
    func trayPrivacyName(_ url: URL) -> String {
        url.pathExtension.isEmpty ? "file" : "file.\(url.pathExtension)"
    }

    var sectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.vertical, 6)
    }

    /// A section's header: 10pt semibold uppercase caption with its glyph, and an optional
    /// trailing control or chip. Decorative glyph; the title reads as a heading to VoiceOver.
    func sectionHeader<Trailing: View>(
        _ title: String,
        icon: String,
        iconTint: Color? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconTint ?? captionColor)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(title)
                .font(PillTextStyle.captionStrong.font)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(captionColor)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(minHeight: PillRowHeight.compact)
    }

    func sectionHeader(_ title: String, icon: String, iconTint: Color? = nil) -> some View {
        sectionHeader(title, icon: icon, iconTint: iconTint) { EmptyView() }
    }

    /// "+N more" caption under a bounded list.
    func overflowCaption(_ text: String) -> some View {
        Text(text)
            .font(PillTextStyle.caption.font)
            .foregroundStyle(captionColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, PillSpace.xs)
    }

    /// Icon-only control button (24pt minimum hit target, icon press style).
    func controlButton(
        systemName: String, label: String, alignsTrailing: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            PillIconLabel(systemName: systemName, alignsTrailing: alignsTrailing)
        }
        .buttonStyle(PillButtonStyle())
        .help(label)
        .accessibilityLabel(Text(label))
    }
}
