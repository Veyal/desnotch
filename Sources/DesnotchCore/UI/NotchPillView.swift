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
        presentation: NotchPillPresentation,
        hasPhysicalNotch: Bool,
        notchSize: CGSize? = nil,
        onSizeChange: ((CGSize) -> Void)? = nil
    ) {
        self.controller = controller
        self.agentActivity = agentActivity
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
    private var isActive: Bool { hasMedia || hasAgents }
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
                if isExpanded {
                    pill
                        .transition(collapseTransition)
                } else {
                    compact
                        .transition(collapseTransition)
                }
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
        .animation(spring, value: presentation.isHovering)
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

    private var collapseTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.7, anchor: .top).combined(with: .opacity)
    }

    // MARK: - Pill

    /// The expanded (hovered) pill stacking every active section. A thin divider separates
    /// now-playing and agents when both show. Flush with the screen top in the same
    /// solid-black bottom-rounded shape as the minimized state, with all content pushed
    /// below the cutout (real hardware on a notch screen, the synthetic black region on a
    /// notch-less one - identical look either way).
    private var pill: some View {
        pillContent
            .padding(.horizontal, 14)
            .padding(.top, effectiveNotch.height + 4)
            .padding(.bottom, 8)
            .frame(width: expandedWidth)
            .background(BottomRoundedRectangle(radius: 14).fill(Color.black))
            .contentShape(BottomRoundedRectangle(radius: 14))
    }

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
        }
    }

    /// Minimized state: a solid-black extension of the notch with the indicators in small
    /// wings either side of the cutout. On a real notch screen the cutout is the opaque
    /// hardware (nothing is ever drawn behind it); on a notch-less screen it is the
    /// synthetic MacBook-sized cutout, so both look identical.
    private var compact: some View {
        notchCompact(effectiveNotch)
    }

    /// Wings flanking the physical cutout, drawn as one bottom-rounded black shape flush
    /// with the screen top so it reads as a slightly wider notch. Both wings are always
    /// drawn while anything is active (symmetry); an inactive side is just black.
    private func notchCompact(_ notch: CGSize) -> some View {
        HStack(spacing: 0) {
            wing { if hasMedia { mediaIndicator } }
            Color.clear
                .frame(width: notch.width)
            wing { if hasAgents { agentIndicator } }
        }
        .frame(height: notch.height)
        .background(BottomRoundedRectangle(radius: 10).fill(Color.black))
        .contentShape(BottomRoundedRectangle(radius: 10))
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

    private var compactAccessibilityLabel: String {
        var parts: [String] = []
        if hasMedia { parts.append("media") }
        if hasAgents {
            parts.append(needsAttention ? "agent needs you" : "\(agentActivity.summary.actionableCount) agents working")
        }
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

            Text(session.projectLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)

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
        .accessibilityLabel(Text("\(session.source.displayName) · \(session.projectLabel) · \(stateLabel(session.state))"))
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
