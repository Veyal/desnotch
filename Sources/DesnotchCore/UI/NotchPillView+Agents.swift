import SwiftUI

/// Agent activity section (inline list).
extension NotchPillView {
    /// One displayed agent row with a stable identity (`AgentSession.identityKey`, made
    /// unique), so reorders animate as moves and the 5s re-scan never re-creates rows.
    struct AgentRow: Identifiable {
        let key: String
        let session: AgentSession
        var id: String { key }
    }

    /// The rows the section shows: needs-you first, bounded to `PillLimits.agentRows`.
    var visibleAgentRows: [AgentRow] {
        let ordered = orderedAgents
        let keys = PillRowIdentity.unique(ordered.map(\.identityKey))
        return zip(keys, ordered).prefix(rowCaps.agents).map { AgentRow(key: $0, session: $1) }
    }

    var agentSection: some View {
        let rows = visibleAgentRows
        let hidden = PillLimits.hiddenCount(total: agentActivity.sessions.count, shown: rows.count)
        let summary = agentActivity.summary
        return VStack(alignment: .leading, spacing: PillSpace.xs) {
            sectionHeader("Agents", icon: priorityIcon(for: summary), iconTint: priorityIconColor(for: summary)) {
                PillChip(
                    text: "\(summary.actionableCount)",
                    tint: PillPalette.white,
                    reduceTransparency: reduceTransparency
                )
                .accessibilityLabel(Text("\(summary.actionableCount) agent\(summary.actionableCount == 1 ? "" : "s")"))
            }
            ForEach(rows) { row in
                agentRow(row.session)
                    .transition(arrivalTransition)
            }
            if hidden > 0 {
                overflowCaption("+\(hidden) more")
            }
        }
    }

    /// Width the row title may use: the row minus the leading slot, the state chip's slot and gaps.
    private var agentTitleWidth: CGFloat {
        max(64, expandedContentWidth - PillRowLeading.titleInset - 72 - PillSpace.s)
    }

    private func agentRow(_ session: AgentSession) -> some View {
        let title = privacyRedacted(session.taskTitle ?? session.projectLabel, fallback: session.projectLabel)
        return Button {
            activateAgentHost(session)
        } label: {
            HStack(spacing: PillRowLeading.gap) {
                Image(systemName: session.source.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(captionColor)
                    .frame(width: PillRowLeading.slot)
                    .availabilityGuardedBounce(
                        trigger: session.state == .needsYourTurn ? 1 : 0, enabled: motion.allowsPulse
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(PillTextStyle.title.font)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .pillRedactionFade(settings.privacyModeEnabled, motion: motion)
                        .help(session.projectLabel)
                    // Source + freshness live on one quiet line (moved off the right edge so
                    // the chip has the trailing slot). The 5s re-scan updates this text
                    // without animation.
                    Text("\(session.source.displayName) · \(freshness(session.lastActivity))")
                        .font(PillTextStyle.caption.font)
                        .foregroundStyle(captionColor)
                        .lineLimit(1)
                        .transaction { $0.animation = nil }
                }
                .frame(maxWidth: agentTitleWidth, alignment: .leading)

                Spacer(minLength: PillSpace.xs)

                stateChip(session.state)
            }
            .frame(minHeight: PillRowHeight.standard)
            .contentShape(Rectangle())
        }
        .buttonStyle(PillButtonStyle(role: .row))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Self.agentRowLabel(
            source: session.source.displayName,
            project: session.projectLabel,
            title: title,
            state: stateLabel(session.state),
            reason: stateReason(session.state),
            freshness: freshness(session.lastActivity)
        )))
        .accessibilityHint(Text("Opens your terminal"))
    }

    /// The spoken row. With task titles off (the default) or in Privacy mode the title IS the
    /// project label, which must not be read twice.
    static func agentRowLabel(
        source: String, project: String, title: String, state: String, reason: String, freshness: String
    ) -> String {
        [source, project, title == project ? nil : title, state, reason, freshness]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The state chip is replaced (not mutated) when the state changes, so the old chip
    /// fades while the new one scales in with its colour: a state change reads as an event.
    /// Needs-you also sends one ring ripple around the chip.
    private func stateChip(_ state: AgentActivityState) -> some View {
        ZStack(alignment: .trailing) {
            PillChip(
                text: chipLabel(state),
                tint: stateTint(state),
                reduceTransparency: reduceTransparency
            )
            .id(state)
            .transition(chipTransition)
        }
        .frame(minWidth: 64, alignment: .trailing)
        .overlay {
            PillRipple(
                trigger: state == .needsYourTurn ? 1 : 0,
                passes: min(1, motion.attentionPulseCount),
                duration: motion.attentionPulseDuration,
                gap: motion.attentionPulseGap,
                growth: 1 + (motion.ringPulseScale - 1) / 2,
                tint: PillPalette.amber.color,
                lineWidth: 1,
                outline: .capsule
            )
        }
        .animation(motion.swap, value: state)
    }

    private var chipTransition: AnyTransition {
        motion.chipArrivalScale == 1
            ? .opacity
            : .opacity.combined(with: .scale(scale: motion.chipArrivalScale))
    }

    /// Short chip text (the spoken label stays the longer `presentationLabel`).
    private func chipLabel(_ state: AgentActivityState) -> String {
        switch state {
        case .working: return "running"
        case .needsYourTurn: return "needs you"
        case .stalled: return "stalled"
        case .idle: return "finished"
        }
    }

    private func stateLabel(_ state: AgentActivityState) -> String {
        state.presentationLabel
    }

    private func stateReason(_ state: AgentActivityState) -> String {
        state.presentationReason
    }

    private func freshness(_ date: Date) -> String {
        AgentActivityPresentation.freshness(for: date)
    }

    private func stateTint(_ state: AgentActivityState) -> PillPalette.Swatch {
        switch state {
        case .needsYourTurn: return PillPalette.amber
        case .stalled: return PillPalette.orange
        case .working: return PillPalette.white
        case .idle: return PillPalette.mist
        }
    }

    func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    /// Most-urgent state wins the section icon/color: stalled (orange) > needs-you (amber) > working (white).
    private func priorityIcon(for s: AgentActivitySummary) -> String {
        if s.stalledCount > 0 { return "exclamationmark.triangle.fill" }
        return s.needsYourTurnCount > 0 ? "bolt.fill" : "gearshape.fill"
    }

    private func priorityIconColor(for s: AgentActivitySummary) -> Color {
        if s.stalledCount > 0 { return PillPalette.orange.color }
        return s.needsYourTurnCount > 0 ? PillPalette.amber.color : .white
    }
}
