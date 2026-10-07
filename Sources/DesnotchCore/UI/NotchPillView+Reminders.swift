import SwiftUI

/// Reminders section.
extension NotchPillView {
    /// The reminder the row shows: the one being completed (kept for a beat so the capture is
    /// seen) or, otherwise, the next due one.
    private var displayedReminder: RemindersController.NextReminder? {
        completingReminder ?? reminders.nextReminder
    }

    var reminderSection: some View {
        VStack(alignment: .leading, spacing: PillSpace.xs) {
            sectionHeader(
                "Reminders",
                icon: "checklist",
                iconTint: reminderUrgent ? PillPalette.amber.color : nil
            ) {
                Button(action: onAddReminder) {
                    PillIconLabel(
                        systemName: "plus.circle.fill",
                        size: 12,
                        weight: .semibold,
                        color: reminders.accessState == .granted ? secondaryColor : captionColor,
                        alignsTrailing: true
                    )
                }
                .buttonStyle(PillButtonStyle())
                .disabled(reminders.accessState != .granted)
                .help("Add reminder")
                .accessibilityLabel(Text("Add reminder"))
            }

            // A fixed-height stack: a replacement row crossfades in place, so the section
            // never grows by a row while the old one is still fading out.
            ZStack(alignment: .topLeading) {
                if let reminder = displayedReminder {
                    reminderRow(reminder, completing: completingReminder?.id == reminder.id)
                        .id(reminder.id)
                        .transition(arrivalTransition)
                } else {
                    reminderEmptyState
                        .transition(.pillFade)
                }
            }
            .frame(maxWidth: .infinity, minHeight: PillRowHeight.standard, alignment: .topLeading)
            .animation(motion.swap, value: displayedReminder?.id)
        }
    }

    private func reminderRow(_ reminder: RemindersController.NextReminder, completing: Bool) -> some View {
        let title = privacyRedacted(reminder.title, fallback: "Reminder")
        return HStack(spacing: PillRowLeading.gap) {
            Button {
                completeReminder(reminder)
            } label: {
                PillCheckbox(completed: completing, motion: motion, reduceTransparency: reduceTransparency)
                    .frame(width: PillRowLeading.slot, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PillButtonStyle())
            .disabled(completing)
            .help("Mark reminder complete")
            .accessibilityLabel(Text("Complete \(privacyRedacted(reminder.title, fallback: "reminder"))"))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(PillTextStyle.title.font)
                    .foregroundStyle(completing ? secondaryColor : Color.white)
                    .lineLimit(1)
                    .overlay(alignment: .leading) { strikeLine(completing: completing) }
                    .pillRedactionFade(settings.privacyModeEnabled, motion: motion)
                PillClock { now in
                    Text(RemindersController.dueLabel(reminder, now: now))
                        .font(PillTextStyle.caption.font)
                        .foregroundStyle(reminderUrgent && !completing ? PillPalette.amber.color : captionColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: max(64, expandedContentWidth - PillRowLeading.titleInset), alignment: .leading)
            .animation(motion.swap, value: completing)
            Spacer(minLength: 0)
        }
        .frame(minHeight: PillRowHeight.standard)
        .accessibilityElement(children: .contain)
    }

    /// A 1.5pt line that draws left to right across the title as it completes (opacity-only
    /// under Reduce Motion).
    private func strikeLine(completing: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(height: 1.5)
            .scaleEffect(x: completing || !motion.allowsGeometry ? 1 : 0, anchor: .leading)
            .opacity(completing ? 1 : 0)
            .animation(
                motion.strikeDuration > 0 ? .easeOut(duration: motion.strikeDuration) : motion.swap,
                value: completing
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var reminderEmptyState: some View {
        switch reminders.accessState {
        case .denied:
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: PillSpace.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PillPalette.amber.color)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Reminders access needed — click to allow")
                        .font(PillTextStyle.body.font)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: PillRowHeight.standard)
                .contentShape(Rectangle())
            }
            .buttonStyle(PillButtonStyle(role: .row))
            .accessibilityLabel(Text("Reminders access needed"))
            .accessibilityHint(Text("Opens Reminders privacy settings"))
        case .granted:
            Text("No due reminders")
                .font(PillTextStyle.body.font)
                .foregroundStyle(secondaryColor)
                .frame(minHeight: PillRowHeight.standard, alignment: .leading)
        case .undetermined:
            Text("Checking Reminders…")
                .font(PillTextStyle.body.font)
                .foregroundStyle(secondaryColor)
                .frame(minHeight: PillRowHeight.standard, alignment: .leading)
        }
    }
}
