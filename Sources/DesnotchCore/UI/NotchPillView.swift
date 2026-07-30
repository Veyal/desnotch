import SwiftUI

/// The single live-activity pill. Minimized by default while anything is active; hovering
/// expands it to a stacked view (now-playing row when media is active, per-agent list when
/// agents are active). When nothing is active it hides entirely.
///
/// On a screen with a physical notch the pill hugs the hardware: the minimized state is a
/// solid-black extension of the notch with the indicators in small "wings" either side of
/// the cutout (never behind it - that area is opaque hardware), and the expanded state
/// draws below the cutout. On notch-less screens it is a free-floating capsule/pill.
///
/// Privacy: the agent list renders ONLY `AgentSession.projectLabel` (a folder basename),
/// the `source`, the coarse `state`, and a relative time - never transcript text, prompts,
/// or absolute paths. Keep additions on that side of the boundary.
public struct NotchPillView: View {
    @ObservedObject public var controller: NowPlayingController
    @ObservedObject public var agentActivity: AgentActivityController
    @ObservedObject public var calendar: CalendarController
    @ObservedObject public var processMonitor: ProcessMonitorController
    @ObservedObject public var presentation: NotchPillPresentation
    public let hasPhysicalNotch: Bool
    /// Physical notch cutout size (`NotchGeometry.notchSize(for:)`); nil on notch-less screens.
    public let notchSize: CGSize?

    /// Invoked with the pill's natural content size whenever SwiftUI lays it out, so
    /// the owning `NSPanel` can resize to fit content + shadow/overshoot room.
    public var onSizeChange: ((CGSize) -> Void)?

    @State private var measuredWidth: CGFloat = 0
    @State private var measuredHeight: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        controller: NowPlayingController,
        agentActivity: AgentActivityController,
        calendar: CalendarController,
        processMonitor: ProcessMonitorController,
        presentation: NotchPillPresentation,
        hasPhysicalNotch: Bool,
        notchSize: CGSize? = nil,
        onSizeChange: ((CGSize) -> Void)? = nil
    ) {
        self.controller = controller
        self.agentActivity = agentActivity
        self.calendar = calendar
        self.processMonitor = processMonitor
        self.presentation = presentation
        self.hasPhysicalNotch = hasPhysicalNotch
        self.notchSize = notchSize
        self.onSizeChange = onSizeChange
    }

    private var spring: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.22)
            : .spring(response: 0.5, dampingFraction: 0.82)
    }

    private var hasMedia: Bool { controller.hasActiveMedia }
    private var hasAgents: Bool { agentActivity.summary.hasActivity }
    private var hasHotProcesses: Bool { !processMonitor.hotProcesses.isEmpty }
    /// A calendar event keeps the pill alive on its own only when imminent/ongoing;
    /// the expanded glance row shows for anything within the lookahead window.
    private var calendarImminent: Bool { calendar.isImminent }
    private var isActive: Bool { hasMedia || hasAgents || calendarImminent || hasHotProcesses }
    /// Width of the black "wing" either side of the physical notch that hosts a minimized
    /// indicator. Sized for the widest content (agent icon + 2-digit count).
    private static let wingWidth: CGFloat = 44

    /// Synthetic cutout used on notch-less screens so the pill replicates the MacBook notch
    /// exactly: a black "cutout" region in the middle (just black here - no camera) with the
    /// indicators in wings either side. Sized like a MacBook Pro notch (~200×32pt).
    private static let fakeNotchSize = CGSize(width: 200, height: 30)

    /// The cutout the layout is built around: the real hardware cutout when present,
    /// otherwise the synthetic MacBook-sized one.
    private var effectiveNotch: CGSize { notchSize ?? Self.fakeNotchSize }

    /// Fixed width for the expanded pill. The rows contain greedy `Spacer`s, so without a
    /// fixed width the pill would fill whatever the panel proposes (and feed that measured
    /// size back into panel growth). A constant keeps it compact and the layout stable.
    private static let expandedBaseWidth: CGFloat = 300

    /// The expanded pill must at least span the cutout plus the wings, so the black shape
    /// always fully covers the hardware (or matches the minimized fake-notch footprint).
    private var expandedWidth: CGFloat {
        max(Self.expandedBaseWidth, effectiveNotch.width + Self.wingWidth * 2)
    }

    /// An agent is waiting on the user - reflected by the minimized agent icon (lightning),
    /// but it no longer forces the pill open. The pill is always minimized unless hovered.
    private var needsAttention: Bool { agentActivity.summary.needsYourTurnCount > 0 }

    /// Expanded only while the pointer is over the pill (hover). Otherwise it stays
    /// minimized to the left/right indicators - even when an agent needs action.
    private var isExpanded: Bool { presentation.isHovering }

    /// Needs-you first (action required), then stalled, then working - most recent first.
    private var orderedAgents: [AgentSession] {
        let rank: [AgentActivityState: Int] = [.needsYourTurn: 0, .stalled: 1, .working: 2]
        return agentActivity.sessions.sorted {
            (rank[$0.state] ?? 9, -$0.lastActivity.timeIntervalSinceNow) < (rank[$1.state] ?? 9, -$1.lastActivity.timeIntervalSinceNow)
        }
    }

    public var body: some View {
        Group {
            if isActive {
                notchBody
            } else {
                Color.clear
                    .frame(width: NotchGeometry.fallbackWidth, height: NotchGeometry.fallbackHeight)
                    .allowsHitTesting(false)
            }
        }
        .background(sizeReader)
        .onPreferenceChange(PillContentWidthPreferenceKey.self) { w in
            measuredWidth = w
            onSizeChange?(CGSize(width: w, height: measuredHeight))
        }
        .onPreferenceChange(PillContentHeightPreferenceKey.self) { h in
            measuredHeight = h
            onSizeChange?(CGSize(width: measuredWidth, height: h))
        }
        .animation(spring, value: isActive)
        .animation(spring, value: hasMedia)
        .animation(spring, value: hasAgents)
        .animation(spring, value: hasHotProcesses)
        .animation(spring, value: calendarImminent)
        .animation(spring, value: presentation.isHovering)
        .animation(.easeInOut(duration: 0.15), value: presentation.volumeFlash == nil)
        .onHover { hovering in
            guard isActive else { return }
            presentation.setHovering(hovering)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The pill renders on an always-dark surface; force a dark color scheme so
        // `.secondary` text stays legible in Light Mode too.
        .environment(\.colorScheme, .dark)
    }

    private var sizeReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: PillContentWidthPreferenceKey.self, value: proxy.size.width)
                .preference(key: PillContentHeightPreferenceKey.self, value: proxy.size.height)
        }
    }

    // MARK: - Pill

    /// One continuous black shape for both states. The container's width/height animate
    /// between the minimized notch footprint and the expanded panel, so the notch visually
    /// *grows into* the panel (and shrinks back on collapse) - never two shapes
    /// cross-fading, which read as the notch shrinking away while a bigger one appeared.
    /// Only the content inside cross-fades; `clipShape` keeps the incoming full-size
    /// content inside the still-growing shape mid-animation.
    private var notchBody: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                pillContent
                    .padding(.horizontal, 14)
                    .padding(.top, effectiveNotch.height + 4)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else {
                compactContent
                    .transition(.opacity)
            }
        }
        .frame(width: isExpanded ? expandedWidth : compactWidth)
        .background(BottomRoundedRectangle(radius: shapeRadius).fill(Color.black))
        .clipShape(BottomRoundedRectangle(radius: shapeRadius))
        .contentShape(BottomRoundedRectangle(radius: shapeRadius))
        .overlay(alignment: .bottom) {
            if let level = presentation.volumeFlash {
                volumeReadout(level)
                    .transition(.opacity)
                    .padding(.bottom, 3)
            }
        }
    }

    /// Momentary readout after scroll-to-adjust: a thin level bar hugging the shape's
    /// bottom edge, so it works in both the minimized and expanded states.
    private func volumeReadout(_ level: Float) -> some View {
        HStack(spacing: 5) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white)
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 64, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 64 * CGFloat(max(0, min(1, level))), height: 3)
                }
        }
        .allowsHitTesting(false)
    }

    private var shapeRadius: CGFloat { isExpanded ? 14 : 10 }

    private var compactWidth: CGFloat { effectiveNotch.width + Self.wingWidth * 2 }

    private var showCalendarRow: Bool { calendar.nextEvent != nil }

    private var pillContent: some View {
        VStack(spacing: 0) {
            if hasMedia, let info = controller.info {
                nowPlayingRow(info)
            }
            if hasMedia && hasAgents {
                sectionDivider
            }
            if hasAgents {
                agentSection
            }
            if (hasMedia || hasAgents) && hasHotProcesses {
                sectionDivider
            }
            if hasHotProcesses {
                processSection
            }
            if (hasMedia || hasAgents || hasHotProcesses) && showCalendarRow {
                sectionDivider
            }
            if showCalendarRow, let event = calendar.nextEvent {
                calendarRow(event)
            }
        }
    }

    /// Minimized content: indicators in small wings either side of the cutout (real
    /// hardware on a notch screen - nothing is ever drawn behind it - or the synthetic
    /// MacBook-sized cutout on a notch-less one). Both wings are always laid out while
    /// anything is active (symmetry); an inactive side is just black. The black shape
    /// itself is owned by `notchBody`.
    /// One indicator per wing. Left: media wins (it has controls), then a stuck-process
    /// warning, then an imminent meeting. Right: agents, then stuck-process if the left
    /// wing is occupied by media. Anything squeezed out is one hover away.
    private var compactContent: some View {
        HStack(spacing: 0) {
            wing {
                if hasMedia {
                    mediaIndicator
                } else if hasHotProcesses {
                    hotProcessIndicator
                } else if calendarImminent {
                    calendarIndicator
                }
            }
            Color.clear
                .frame(width: effectiveNotch.width)
            wing {
                if hasAgents {
                    agentIndicator
                } else if hasMedia && hasHotProcesses {
                    hotProcessIndicator
                } else if !hasMedia && hasHotProcesses && calendarImminent {
                    calendarIndicator
                }
            }
        }
        .frame(height: effectiveNotch.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(compactAccessibilityLabel))
    }

    private func wing<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Color.clear keeps the wing at full size even when its indicator is inactive,
        // so the cutout gap stays centered on the physical notch.
        Color.clear
            .frame(width: Self.wingWidth)
            .overlay(content())
    }

    private var mediaIndicator: some View {
        Image(systemName: "music.note")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
    }

    private var agentIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: needsAttention ? "bolt.fill" : "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(needsAttention ? .yellow : .white)
            Text("\(agentActivity.summary.actionableCount)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var hotProcessIndicator: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
    }

    private var calendarIndicator: some View {
        Image(systemName: "calendar")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
    }

    private var compactAccessibilityLabel: String {
        var parts: [String] = []
        if hasMedia { parts.append("media") }
        if hasAgents {
            parts.append(needsAttention ? "agent needs you" : "\(agentActivity.summary.actionableCount) agents working")
        }
        if hasHotProcesses { parts.append("process may be stuck") }
        if calendarImminent { parts.append("meeting soon") }
        return parts.joined(separator: ", ")
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.vertical, 6)
    }

    // MARK: - Now-playing row

    private func nowPlayingRow(_ info: NowPlayingInfo) -> some View {
        HStack(spacing: 10) {
            artwork(info.artwork, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(info.title ?? "Unknown Title")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(info.artist ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 140, alignment: .leading)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                controlButton(systemName: "backward.fill", label: "Previous track") {
                    controller.previous()
                }
                controlButton(
                    systemName: info.isPlaying ? "pause.fill" : "play.fill",
                    label: info.isPlaying ? "Pause" : "Play"
                ) {
                    controller.togglePlayPause()
                }
                .availabilityGuardedSymbolReplace()
                controlButton(systemName: "forward.fill", label: "Next track") {
                    controller.next()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(info.title ?? "Unknown Title")\(info.artist.map { ", \($0)" } ?? "")"))
    }

    // MARK: - Agent section (inline list)

    private var agentSection: some View {
        // Render without identity churn so the 5s re-scan doesn't re-animate the list;
        // tracking by position keeps updates instant and stable.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: priorityIcon(for: agentActivity.summary))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(priorityIconColor(for: agentActivity.summary))
                Text("\(agentActivity.summary.actionableCount) agent\(agentActivity.summary.actionableCount == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            ForEach(Array(orderedAgents.enumerated()), id: \.offset) { _, session in
                agentRow(session)
            }
        }
        .animation(nil, value: orderedAgents.count)
    }

    private func agentRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.source.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(session.taskTitle ?? session.projectLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .help(session.projectLabel)

            Spacer(minLength: 4)

            Text(stateLabel(session.state))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(stateColor(session.state))

            Text(relativeTime(session.lastActivity))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(session.source.displayName) · \(session.projectLabel) · \(session.taskTitle ?? "") · \(stateLabel(session.state))"))
    }

    private func stateLabel(_ state: AgentActivityState) -> String {
        switch state {
        case .working: return "working"
        case .needsYourTurn: return "needs you"
        case .stalled: return "stalled"
        case .idle: return "idle"
        }
    }

    private func stateColor(_ state: AgentActivityState) -> Color {
        switch state {
        case .needsYourTurn: return .yellow
        case .stalled: return .orange
        case .working: return .white
        case .idle: return .secondary
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow * -1))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    /// Most-urgent state wins the section icon/color: stalled (orange) > needs-you (yellow) > working (white).
    private func priorityIcon(for s: AgentActivitySummary) -> String {
        if s.stalledCount > 0 { return "exclamationmark.triangle.fill" }
        return s.needsYourTurnCount > 0 ? "bolt.fill" : "gearshape.fill"
    }

    private func priorityIconColor(for s: AgentActivitySummary) -> Color {
        if s.stalledCount > 0 { return .orange }
        return s.needsYourTurnCount > 0 ? .yellow : .white
    }

    // MARK: - Stuck-process section

    /// Presumed-stuck processes (sustained high CPU). Rows show name, current CPU%, and
    /// how long the streak has lasted - enough to decide whether to go kill something.
    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                Text("high CPU")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            ForEach(processMonitor.hotProcesses) { proc in
                HStack(spacing: 8) {
                    Text(proc.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                    Spacer(minLength: 4)
                    Text("\(Int(proc.cpu))%")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(relativeTime(proc.since))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.vertical, 1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(proc.name) at \(Int(proc.cpu)) percent CPU"))
            }
        }
        .animation(nil, value: processMonitor.hotProcesses.count)
    }

    // MARK: - Calendar glance

    private func calendarRow(_ event: CalendarController.NextEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(event.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
            Spacer(minLength: 4)
            Text(timeUntil(event))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(calendarImminent ? .yellow : .secondary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Next event: \(event.title), \(timeUntil(event))"))
    }

    private func timeUntil(_ event: CalendarController.NextEvent) -> String {
        let s = Int(event.start.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        if s < 3600 { return "in \(max(1, s / 60))m" }
        return "in \(s / 3600)h \((s % 3600) / 60)m"
    }

    // MARK: - Shared pieces

    private func artwork(_ image: NSImage?, size: CGFloat) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.gray.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size >= 24 ? 5 : 4))
    }

    private func controlButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PillButtonStyle())
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// Rectangle with only the bottom two corners rounded - flush with the screen's top edge,
/// so the pill reads as an extension of the physical notch. (Custom shape rather than
/// `UnevenRoundedRectangle`, which needs macOS 13.3; the package targets 13.0.)
struct BottomRoundedRectangle: Shape {
    var radius: CGFloat

    /// Animate radius changes so the minimized→expanded morph doesn't snap corners.
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// Press + hover feedback for pill buttons.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private extension View {
    /// `.contentTransition(.symbolEffect(.replace))` is macOS 14+; fall back to no
    /// transition on macOS 13 so the play/pause swap still builds for the 13 min target.
    @ViewBuilder
    func availabilityGuardedSymbolReplace() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }
}
