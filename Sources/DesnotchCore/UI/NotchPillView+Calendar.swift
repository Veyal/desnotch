import SwiftUI

/// Calendar glance.
extension NotchPillView {
    /// Shown instead of the event row when access was denied - otherwise the feature
    /// just looks broken. Click opens the Calendars privacy pane.
    var calendarAccessHint: some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: PillSpace.s) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PillPalette.amber.color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text("Calendar access needed — click to allow")
                    .font(PillTextStyle.body.font)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: PillRowHeight.standard)
            .contentShape(Rectangle())
        }
        .buttonStyle(PillButtonStyle(role: .row))
    }

    /// One minute clock drives both the visible "in 12m" and the spoken label, so VoiceOver
    /// never reads a time the screen no longer shows (the body only re-runs when a controller
    /// publishes, which is far rarer than a minute).
    func calendarRow(_ event: CalendarController.NextEvent) -> some View {
        PillClock { now in
            if let joinURL = event.joinURL {
                Button {
                    NSWorkspace.shared.open(joinURL)
                } label: {
                    calendarRowContents(event, canJoin: true, now: now)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PillButtonStyle(role: .row))
                .help("Join meeting")
                .accessibilityLabel(Text("Join next event: \(privacyRedacted(event.title, fallback: "Busy")), \(timeUntil(event, now: now))"))
                .accessibilityHint(Text("Opens the meeting link"))
            } else {
                calendarRowContents(event, canJoin: false, now: now)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Next event: \(privacyRedacted(event.title, fallback: "Busy")), \(timeUntil(event, now: now))"))
            }
        }
    }

    /// Width the event title may use: the row minus the leading slot, gaps and (with a meeting
    /// link) the Join capsule.
    private func calendarTitleWidth(canJoin: Bool) -> CGFloat {
        max(64, expandedContentWidth - PillRowLeading.titleInset - PillSpace.s - (canJoin ? 60 : 0))
    }

    private func calendarRowContents(
        _ event: CalendarController.NextEvent, canJoin: Bool, now: Date
    ) -> some View {
        HStack(spacing: PillRowLeading.gap) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captionColor)
                .frame(width: PillRowLeading.slot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(privacyRedacted(event.title, fallback: "Busy"))
                    .font(PillTextStyle.title.font)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .pillRedactionFade(settings.privacyModeEnabled, motion: motion)
                // Minute ticks roll the digits (macOS 14) or crossfade; crossing into
                // "imminent" crossfades the tint to amber. The clock only runs while this
                // row is on screen (nothing ticks while the pill is minimized).
                let until = timeUntil(event, now: now)
                Text(until)
                    .font(PillTextStyle.caption.font.monospacedDigit())
                    .foregroundStyle(calendarImminent ? PillPalette.amber.color : captionColor)
                    .lineLimit(1)
                    .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
                    .animation(motion.swap, value: until)
                    .animation(motion.swap, value: calendarImminent)
            }
            .frame(maxWidth: calendarTitleWidth(canJoin: canJoin), alignment: .leading)
            Spacer(minLength: PillSpace.xs)
            if canJoin {
                joinCapsule
            }
        }
        .frame(minHeight: PillRowHeight.standard)
    }

    /// Visual "Join" affordance (the whole row is the button). Pops once, springing back,
    /// when the meeting crosses into imminent.
    private var joinCapsule: some View {
        HStack(spacing: 3) {
            Image(systemName: "video.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Join")
                .font(PillTextStyle.bodyStrong.font)
        }
        .foregroundStyle(PillPalette.cyan.color)
        .padding(.horizontal, PillSpace.s)
        .frame(minWidth: 44, minHeight: 24)
        .background(
            Capsule(style: .continuous)
                .fill(PillPalette.cyan.fill(alpha: 0.16, reduceTransparency: reduceTransparency))
        )
        .pillPop(trigger: calendarImminent ? 1 : 0, peak: motion.popScale, motion: motion)
        .accessibilityHidden(true)
    }

    private func timeUntil(_ event: CalendarController.NextEvent, now: Date = Date()) -> String {
        let s = Int(event.start.timeIntervalSince(now))
        if s <= 0 { return "now" }
        if s < 3600 { return "in \(max(1, s / 60))m" }
        if s < 6 * 3600 { return "in \(s / 3600)h \((s % 3600) / 60)m" }
        // Further out (24h lookahead): an absolute time reads better than "in 19h 40m".
        let time = event.start.formatted(date: .omitted, time: .shortened)
        return Foundation.Calendar.current.isDateInTomorrow(event.start) ? "tmrw \(time)" : time
    }
}
