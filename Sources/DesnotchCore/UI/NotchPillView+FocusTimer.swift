import SwiftUI

/// Focus timer section.
extension NotchPillView {
    /// One persistent row for every timer state. The ring (`PillTimerRing`) is the same view
    /// across running -> paused -> completed, so the states morph (tint crossfade, fill to
    /// full, check drawn in) instead of the row being replaced. The countdown comes from a
    /// 1 Hz `TimelineView` that only ticks while the timer runs (a paused or completed
    /// timer schedules an hourly no-op), and the ring glides between ticks - no per-frame
    /// timeline.
    @ViewBuilder
    var focusTimerSection: some View {
        TimelineView(.periodic(from: .now, by: focusTimer.state == .running ? 1 : 3600)) { context in
            focusTimerRow(at: context.date)
        }
    }

    private var timerRingPhase: PillTimerRing.Phase {
        switch focusTimer.state {
        case .paused: return .paused
        case .completed: return .completed
        case .running, .idle: return .running
        }
    }

    /// The completion happened moments ago (it is why the pill is open): ripple and draw
    /// the check as the ring appears.
    var isFreshTimerCompletion: Bool {
        guard let completedAt = focusTimer.completion?.completedAt else { return false }
        return Date().timeIntervalSince(completedAt) < 5
    }

    private func focusTimerRow(at date: Date) -> some View {
        let phase = timerRingPhase
        let remaining = timerRemaining(at: date)
        return HStack(spacing: PillSpace.s) {
            PillTimerRing(
                phase: phase,
                progress: PillTimerRing.progress(remaining: remaining, duration: focusTimer.duration),
                size: 32,
                lineWidth: 3,
                glyphSize: 12,
                duration: focusTimer.duration,
                motion: motion,
                reduceTransparency: reduceTransparency,
                increasedContrast: contrast == .increased,
                completionTrigger: phase == .completed ? 1 : 0,
                isFreshCompletion: isFreshTimerCompletion
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(phase == .completed ? "Focus complete" : "Focus")
                    .font(PillTextStyle.title.font)
                    .foregroundStyle(.white)
                    .accessibilityLabel(Text(phase == .completed ? "Focus complete" : "Focus timer"))
                Text(timerStatusText(phase))
                    .font(PillTextStyle.caption.font)
                    .foregroundStyle(phase == .paused ? PillPalette.amber.color : captionColor)
            }
            .contentTransition(.opacity)
            .animation(motion.swap, value: phase)

            Spacer(minLength: PillSpace.xs)

            if phase == .completed {
                Button("Done") { focusTimer.reset() }
                    .font(PillTextStyle.bodyStrong.font)
                    .foregroundStyle(PillPalette.cyan.color)
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel(Text("Dismiss completed focus timer"))
                    .transition(.pillFade)
            } else {
                timerCountdownText(remaining)
                    .transition(.pillFade)
                controlButton(
                    systemName: phase == .paused ? "play.fill" : "pause.fill",
                    label: phase == .paused ? "Resume focus timer" : "Pause focus timer"
                ) {
                    phase == .paused ? focusTimer.resume() : focusTimer.pause()
                }
                .availabilityGuardedSymbolReplace(enabled: motion.allowsPulse)
                controlButton(systemName: "xmark", label: "Cancel focus timer", alignsTrailing: true) {
                    focusTimer.cancel()
                }
                .transition(.pillFade)
            }
        }
        .animation(motion.swap, value: phase)
        .frame(minHeight: PillRowHeight.tall)
        .accessibilityElement(children: .contain)
    }

    private func timerStatusText(_ phase: PillTimerRing.Phase) -> String {
        switch phase {
        case .running: return "In focus"
        case .paused: return "Paused"
        case .completed: return "Nice work — take a break"
        }
    }

    private func timerCountdownText(_ remaining: TimeInterval) -> some View {
        Text(TimeFormatting.clock(ceil(remaining)))
            .font(PillTextStyle.display.font)
            .foregroundStyle(.white)
            .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
            .animation(motion.swap, value: Int(ceil(remaining)))
            .accessibilityLabel(Text("\(TimeFormatting.clock(ceil(remaining))) remaining"))
    }

    func timerRemaining(at date: Date) -> TimeInterval {
        guard focusTimer.state == .running, let endDate = focusTimer.endDate else {
            return focusTimer.remaining
        }
        return max(0, endDate.timeIntervalSince(date))
    }
}
