import SwiftUI

/// Minimized wing indicators.
extension NotchPillView {
    /// Minimized content: indicators in small wings either side of the cutout (real
    /// hardware on a notch screen - nothing is ever drawn behind it - or the synthetic
    /// MacBook-sized cutout on a notch-less one). Both wings are always laid out while
    /// anything is active (symmetry); an inactive side is just black. The black shape
    /// itself is owned by `notchBody`.
    /// One indicator per wing (priorities live in `WingSelection`, tested). Each wing is
    /// identity-keyed: an indicator handing over to another scales/fades in on the wing
    /// spring while the old one shrinks out, instead of snapping. Idle cost: with nothing
    /// playing and no pulse running there are no timelines, timers or animations here.
    var compactContent: some View {
        let selection = WingSelection.select(wingInputs)
        let wingWidth = Self.wingWidth + wingExtraWidth
        return HStack(spacing: 0) {
            wing(selection.left, side: .left, width: wingWidth)
            Color.clear
                .frame(width: effectiveNotch.width)
            wing(selection.right, side: .right, width: wingWidth)
        }
        .frame(height: effectiveNotch.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(compactAccessibilityLabel))
    }

    enum WingSide { case left, right }

    var wingInputs: WingInputs {
        WingInputs(
            volumeActive: presentation.volumeFlash != nil,
            hasMedia: hasMedia,
            hasTimer: hasTimer,
            hasAgents: hasAgents,
            hasHotProcesses: hasHotProcesses,
            hasNotification: hasNotification,
            calendarImminent: calendarImminent,
            reminderUrgent: reminderUrgent,
            voiceState: voiceState == .idle ? nil : voiceState
        )
    }

    /// One wing slot: a fixed-width (44pt, plus `WingMetrics.extraWidth` on both sides when an
    /// indicator is wide), notch-high box (so the cutout gap stays centered on
    /// the physical notch even when this side is empty) hosting at most one indicator. The
    /// shape's concave top ear eats `topEar` of the outer edge, and the indicator is anchored
    /// that far plus its own `WingMetrics.inset(of:)` in from the outer edge. In a base wing that
    /// is exactly centred; in a grown wing (a wide neighbour on the other side) the spare width
    /// opens toward the cutout instead of pushing a narrow indicator away from its edge.
    func wing(_ indicator: WingIndicator?, side: WingSide, width: CGFloat) -> some View {
        let outer: Edge.Set = side == .left ? .leading : .trailing
        let inset = indicator.map {
            WingMetrics.inset(of: $0, timerShowsLabel: focusTimer.state != .completed)
        } ?? 0
        return ZStack {
            if let indicator {
                wingIndicatorView(indicator, side: side)
                    .id(indicator)
                    .transition(.pillWing(motion, blurAllowed: blurAllowed))
            }
        }
        .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
        .padding(outer, NotchGeometry.topEar + inset)
        .frame(width: width, height: effectiveNotch.height)
        .animation(motion.wing, value: indicator)
    }

    @ViewBuilder
    private func wingIndicatorView(_ indicator: WingIndicator, side: WingSide) -> some View {
        switch indicator {
        case .media: mediaIndicator
        case .timer: focusTimerIndicator
        case .hotProcess: hotProcessIndicator
        case .calendar: calendarIndicator
        case .reminder: reminderIndicator
        case .agent: agentIndicator
        case .notification: notificationIndicator
        case .voice:
            if side == .left {
                voiceWingGlyph(for: voiceState)
            } else if voiceState == .listening {
                VoiceWingMeterHost(model: voice, motion: motion)
            } else if voiceState == .awaitingApproval {
                Circle()
                    .fill(PillPalette.amber.color)
                    .frame(width: 6, height: 6)
            }
        case .volume:
            if let level = presentation.volumeFlash {
                if side == .left {
                    volumeGlyphIndicator(level)
                } else {
                    volumePercentIndicator(level)
                }
            }
        }
    }

    /// User-selectable (Settings > Music indicator): equalizer bars while playing,
    /// the static note, or the current track's album art. Fallback rules live in
    /// `MusicIndicatorResolver` (no artwork or privacy mode → equalizer/note;
    /// reduced motion → never the animated bars). All variants share one fixed
    /// 18×18 slot so style/state changes never shift the wing's layout.
    private var mediaIndicator: some View {
        let resolved = MusicIndicatorResolver.resolve(
            style: settings.musicIndicatorStyle,
            hasArtwork: controller.info?.artwork != nil,
            isPlaying: controller.info?.isPlaying == true,
            allowsLooping: motion.allowsLooping,
            privacyMode: settings.privacyModeEnabled
        )
        return ZStack {
            switch resolved {
            case .art:
                if let art = controller.info?.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                        // Hairline edge so near-black covers keep a silhouette on the pill.
                        .overlay(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(
                                PillPalette.artworkEdge(increasedContrast: contrast == .increased),
                                lineWidth: 0.5
                            )
                        )
                        // Dimmed while paused: a state signal with zero ongoing cost.
                        .opacity(controller.info?.isPlaying == true ? 1 : 0.55)
                        .transition(indicatorTransition)
                }
            case .equalizer:
                NowPlayingEqualizer(tint: mediaAccent)
                    .transition(indicatorTransition)
            case .note:
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .transition(indicatorTransition)
            }
        }
        .frame(width: 18, height: 18)
        .foregroundStyle(.white)
        .animation(motion.wing, value: resolved)
    }

    /// Volume readout, left wing: the speaker with its waves filled to the level. Lives in
    /// the wings (never behind the cutout), so it is visible on notch hardware.
    private func volumeGlyphIndicator(_ level: Float) -> some View {
        Image(
            systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
            variableValue: Double(max(0, min(1, level)))
        )
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .animation(motion.direct, value: level)
    }

    /// Volume readout, right wing: the level as a percentage.
    private func volumePercentIndicator(_ level: Float) -> some View {
        let percent = Int((max(0, min(1, level)) * 100).rounded())
        return Text("\(percent)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
            .animation(motion.direct, value: percent)
    }

    /// Agent count. When the needs-you count rises: the bolt turns amber and bounces once
    /// (macOS 14) while a ring ripples `attentionPulseCount` times, then it rests as a static
    /// amber bolt with a badge dot. Finite: no repeat, no timeline.
    private var agentIndicator: some View {
        let needs = agentActivity.summary.needsYourTurnCount
        return HStack(spacing: 4) {
            ZStack {
                PillRipple(
                    trigger: needs,
                    passes: motion.attentionPulseCount,
                    duration: motion.attentionPulseDuration,
                    gap: motion.attentionPulseGap,
                    growth: motion.ringPulseScale,
                    tint: PillPalette.amber.color
                )
                .frame(width: 16, height: 16)
                Image(systemName: needsAttention ? "bolt.fill" : "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(needsAttention ? PillPalette.amber.color : Color.white)
                    // One-shot bounce whenever the needs-you count changes, so the flip is
                    // noticeable without hovering (the icon swap alone was silent).
                    .availabilityGuardedBounce(trigger: needs, enabled: motion.allowsPulse)
                    .availabilityGuardedSymbolReplace(enabled: motion.allowsPulse)
                    .animation(motion.fade, value: needsAttention)
            }
            .overlay(alignment: .topTrailing) {
                if needsAttention {
                    Circle()
                        .fill(PillPalette.amber.color)
                        .frame(width: 5, height: 5)
                        .overlay(
                            Circle().stroke(Color.white, lineWidth: contrast == .increased ? 1 : 0)
                        )
                        .offset(x: 2, y: -1)
                        .transition(.opacity)
                }
            }
            .animation(motion.fade, value: needsAttention)
            Text(PillCountLabel.text(agentActivity.summary.actionableCount))
                .font(PillTextStyle.wingCount.font.monospacedDigit())
                .foregroundStyle(.white)
                .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
                .animation(motion.swap, value: agentActivity.summary.actionableCount)
        }
    }

    /// Focus timer wing: the same persistent ring as the expanded row, shrunk to 14pt (ring +
    /// "24m" must leave air inside the 38pt visible wing), with
    /// the remaining time as minutes ("24m") or seconds under a minute. One 1 Hz timeline
    /// while it runs; a paused or completed timer schedules an hourly no-op.
    private var focusTimerIndicator: some View {
        TimelineView(.periodic(from: .now, by: focusTimer.state == .running ? 1 : 3600)) { context in
            let remaining = timerRemaining(at: context.date)
            let phase: PillTimerRing.Phase = {
                switch focusTimer.state {
                case .paused: return .paused
                case .completed: return .completed
                case .running, .idle: return .running
                }
            }()
            HStack(spacing: 2) {
                PillTimerRing(
                    phase: phase,
                    progress: PillTimerRing.progress(remaining: remaining, duration: focusTimer.duration),
                    size: 14,
                    lineWidth: 2,
                    glyphSize: 7,
                    duration: focusTimer.duration,
                    motion: motion,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: contrast == .increased,
                    completionTrigger: phase == .completed ? 1 : 0,
                    isFreshCompletion: isFreshTimerCompletion
                )
                if phase != .completed {
                    Text(TimeFormatting.compact(remaining))
                        .font(PillTextStyle.wingTimer.font)
                        .foregroundStyle(PillTimerRing.tint(for: phase).color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
                        .animation(motion.swap, value: TimeFormatting.compact(remaining))
                        .transition(.opacity)
                }
            }
            .animation(motion.swap, value: phase)
        }
    }

    /// Stuck process: an orange flame that sends one ripple when a new hot process appears.
    private var hotProcessIndicator: some View {
        ZStack {
            PillRipple(
                trigger: processMonitor.hotProcesses.count,
                passes: min(1, motion.attentionPulseCount),
                duration: motion.attentionPulseDuration,
                gap: motion.attentionPulseGap,
                growth: motion.ringPulseScale,
                tint: PillPalette.orange.color
            )
            .frame(width: 16, height: 16)
            Image(systemName: "flame.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PillPalette.orange.color)
        }
    }

    private var calendarIndicator: some View {
        Image(systemName: "calendar")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
    }

    private var reminderIndicator: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PillPalette.amber.color)
    }

    /// A recent banner is waiting behind a hover; the bell pulses once per arrival (bounce
    /// only, no ripple).
    private var notificationIndicator: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .availabilityGuardedBounce(
                trigger: notificationMirror.arrivalCount, enabled: motion.allowsPulse
            )
    }

    private var compactAccessibilityLabel: String {
        var parts: [String] = []
        if let voiceLabel = Self.voiceCompactLabel(voiceState) {
            parts.append(voiceLabel)
        }
        if hasMedia { parts.append(controller.info?.isPlaying == true ? "media playing" : "media paused") }
        if hasTimer {
            switch focusTimer.state {
            case .running:
                // Not the remaining time: this label re-renders only on state changes, so a
                // countdown here would stay frozen at its first value while the wing ticks.
                // The expanded row carries the live time.
                parts.append("focus timer running")
            case .paused:
                parts.append("focus timer paused")
            case .completed:
                parts.append("focus timer complete")
            case .idle:
                break
            }
        }
        if hasAgents {
            parts.append(needsAttention ? "agent needs you" : "\(agentActivity.summary.actionableCount) agents working")
        }
        if hasHotProcesses { parts.append("process may be stuck") }
        if calendarImminent { parts.append("meeting soon") }
        if reminderUrgent, let reminder = reminders.nextReminder {
            // The state, not a relative time: this label re-renders only when a controller
            // publishes, so a due time here would go stale (the clock state flips on overdue).
            parts.append(RemindersController.dueLabel(reminder) == "Overdue" ? "reminder overdue" : "reminder due soon")
        }
        if hasNotification, let banner = notificationMirror.latest {
            parts.append("notification from \(banner.appName)")
        }
        return parts.joined(separator: ", ")
    }
}
