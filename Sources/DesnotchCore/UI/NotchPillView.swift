import SwiftUI
import UniformTypeIdentifiers

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
    @ObservedObject public var tray: TrayController
    @ObservedObject public var battery: BatteryController
    @ObservedObject public var mediaUse: MediaUseMonitor
    @ObservedObject public var presentation: NotchPillPresentation
    @ObservedObject private var settings = SettingsStore.shared
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
        tray: TrayController,
        battery: BatteryController,
        mediaUse: MediaUseMonitor,
        presentation: NotchPillPresentation,
        hasPhysicalNotch: Bool,
        notchSize: CGSize? = nil,
        onSizeChange: ((CGSize) -> Void)? = nil
    ) {
        self.controller = controller
        self.agentActivity = agentActivity
        self.calendar = calendar
        self.processMonitor = processMonitor
        self.tray = tray
        self.battery = battery
        self.mediaUse = mediaUse
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

    private var hasMedia: Bool { settings.nowPlayingEnabled && controller.hasActiveMedia }
    private var hasAgents: Bool { settings.agentActivityEnabled && agentActivity.summary.hasActivity }
    private var hasHotProcesses: Bool { settings.processMonitorEnabled && !processMonitor.hotProcesses.isEmpty }
    /// Drives the compact calendar indicator; the expanded glance row shows for anything
    /// within the lookahead window.
    private var calendarImminent: Bool { settings.calendarEnabled && calendar.isImminent }
    private var trayEnabled: Bool { settings.trayEnabled }
    /// Width of the black "wing" either side of the physical notch that hosts a minimized
    /// indicator. Sized for the widest content (agent icon + 2-digit count).
    private static let wingWidth: CGFloat = 44

    /// The cutout the layout is built around: the real hardware cutout when present,
    /// otherwise a synthetic one whose size is user-configurable (Settings > Minimized
    /// size; defaults match a MacBook Pro notch, ~200×30pt). Real hardware always wins -
    /// drawing a differently-sized "cutout" over a physical notch would look broken.
    private var effectiveNotch: CGSize {
        notchSize ?? CGSize(width: settings.minimizedWidth, height: settings.minimizedHeight)
    }

    /// Fixed width for the expanded pill (user-configurable). The rows contain greedy
    /// `Spacer`s, so without a fixed width the pill would fill whatever the panel proposes
    /// (and feed that measured size back into panel growth - a layout feedback loop). A
    /// definite value keeps it stable; it still never shrinks below cutout + wings.
    private var expandedWidth: CGFloat {
        NotchGeometry.expandedPillWidth(
            preferred: CGFloat(settings.expandedWidth),
            cutoutWidth: effectiveNotch.width,
            wingWidth: Self.wingWidth
        )
    }

    /// An agent is waiting on the user - reflected by the minimized agent icon (lightning),
    /// but it no longer forces the pill open. The pill is always minimized unless hovered.
    private var needsAttention: Bool { agentActivity.summary.needsYourTurnCount > 0 }

    /// A file drag is currently over the notch shape (drives the drop-target visuals
    /// and holds the pill open so the tray is visible while dragging).
    @State private var isDropTargeted = false

    /// Timeline position being scrubbed (drag in progress); nil when not scrubbing.
    @State private var scrubPosition: TimeInterval?

    /// Expanded while the pointer is over the pill, while a file drag hovers it, briefly
    /// after a successful drop (so the added item is seen landing) - or permanently, when
    /// the user picked the always-on mode in Settings.
    private var isExpanded: Bool {
        settings.pillMode == .alwaysOn
            || presentation.isHovering || isDropTargeted || presentation.openFlash
    }

    /// Needs-you first (action required), then stalled, then working - most recent first.
    private var orderedAgents: [AgentSession] {
        let rank: [AgentActivityState: Int] = [.needsYourTurn: 0, .stalled: 1, .working: 2]
        return agentActivity.sessions.sorted {
            (rank[$0.state] ?? 9, -$0.lastActivity.timeIntervalSinceNow) < (rank[$1.state] ?? 9, -$1.lastActivity.timeIntervalSinceNow)
        }
    }

    public var body: some View {
        // The notch is ALWAYS shown (and hover always expands it): even with nothing
        // playing and no agents it hosts the calendar glance and the file tray. On real
        // notch hardware the empty compact state is pure black wings hugging the cutout -
        // effectively invisible; on notch-less screens it's the fake notch the user wants
        // visible anyway.
        notchBody
            .background(sizeReader)
        .onPreferenceChange(PillContentWidthPreferenceKey.self) { w in
            measuredWidth = w
            onSizeChange?(CGSize(width: w, height: measuredHeight))
        }
        .onPreferenceChange(PillContentHeightPreferenceKey.self) { h in
            measuredHeight = h
            onSizeChange?(CGSize(width: measuredWidth, height: h))
        }
        .animation(spring, value: hasMedia)
        .animation(spring, value: hasAgents)
        .animation(spring, value: hasHotProcesses)
        .animation(spring, value: calendarImminent)
        .animation(spring, value: presentation.isHovering)
        .animation(spring, value: settings.pillMode)
        .animation(spring, value: settings.minimizedWidth)
        .animation(spring, value: settings.minimizedHeight)
        .animation(spring, value: settings.expandedWidth)
        .animation(spring, value: isDropTargeted)
        .animation(spring, value: presentation.openFlash)
        .animation(spring, value: tray.items)
        .animation(.easeInOut(duration: 0.15), value: presentation.volumeFlash == nil)
        .animation(.easeInOut(duration: 0.2), value: mediaUse.micInUse)
        .animation(.easeInOut(duration: 0.2), value: mediaUse.cameraInUse)
        .animation(spring, value: battery.state)
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
        .background(
            BottomRoundedRectangle(radius: shapeRadius)
                .fill(isDropTargeted ? Color(white: 0.13) : Color.black)
        )
        .overlay(
            // Drop-target affordance: the shape itself lights up while a file hovers it.
            BottomRoundedRectangle(radius: shapeRadius)
                .stroke(Color.white.opacity(isDropTargeted ? 0.6 : 0), lineWidth: 1.5)
        )
        .clipShape(BottomRoundedRectangle(radius: shapeRadius))
        .contentShape(BottomRoundedRectangle(radius: shapeRadius))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard trayEnabled else { return false }
            var accepted = false
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    if let url {
                        Task { @MainActor in
                            tray.add(url)
                            presentation.flashOpen()
                        }
                    }
                }
            }
            return accepted
        }
        .overlay(alignment: .bottom) {
            if let level = presentation.volumeFlash {
                volumeReadout(level)
                    .transition(.opacity)
                    .padding(.bottom, 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Mic/camera in-use dots, hugging the shape's top-right corner in both states
            // (the camera literally lives in the notch, so this is its natural home).
            if mediaUse.micInUse || mediaUse.cameraInUse {
                HStack(spacing: 3) {
                    if mediaUse.micInUse {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                    }
                    if mediaUse.cameraInUse {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                    }
                }
                .padding(.top, 5)
                .padding(.trailing, 7)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityLabel(Text([
                    mediaUse.micInUse ? "microphone in use" : nil,
                    mediaUse.cameraInUse ? "camera in use" : nil
                ].compactMap { $0 }.joined(separator: ", ")))
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

    private var showCalendarRow: Bool {
        settings.calendarEnabled && (calendar.nextEvent != nil || calendar.accessState == .denied)
    }

    private var showBatteryRow: Bool { settings.batteryEnabled }

    /// Blank sensitive strings while privacy mode is on (screen sharing/recording).
    private func privacyRedacted(_ text: String, fallback: String) -> String {
        settings.privacyModeEnabled ? fallback : text
    }

    private func batteryRow(_ state: BatteryController.BatteryState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: batterySymbol(state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(state.isCharging ? .green : (state.percent <= 20 ? .red : .secondary))
                .frame(width: 14)
            Text(state.isCharging ? "Charging" : "Battery")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            Text("\(state.percent)%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Battery \(state.percent) percent\(state.isCharging ? ", charging" : "")"))
    }

    private func batterySymbol(_ state: BatteryController.BatteryState) -> String {
        if state.isCharging { return "battery.100percent.bolt" }
        switch state.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// The tray is the last section (when enabled). With every section disabled or empty
    /// the expanded pill still shows a small placeholder rather than an empty black blob.
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
            if showCalendarRow {
                if let event = calendar.nextEvent {
                    calendarRow(event)
                } else {
                    calendarAccessHint
                }
            }
            if showBatteryRow, let state = battery.state {
                if hasMedia || hasAgents || hasHotProcesses || showCalendarRow {
                    sectionDivider
                }
                batteryRow(state)
            }
            if trayEnabled {
                if hasMedia || hasAgents || hasHotProcesses || showCalendarRow || (showBatteryRow && battery.state != nil) {
                    sectionDivider
                }
                traySection
            }
            if !trayEnabled && !hasMedia && !hasAgents && !hasHotProcesses && !showCalendarRow && !(showBatteryRow && battery.state != nil) {
                Text("Everything is turned off — see Settings")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    /// Shown instead of the event row when access was denied - otherwise the feature
    /// just looks broken. Click opens the Calendars privacy pane.
    private var calendarAccessHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: 14)
            Text("Calendar access needed — click to allow")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
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
                // One-shot bounce whenever the needs-you count changes, so the flip is
                // noticeable without hovering (the icon swap alone was silent).
                .availabilityGuardedBounce(trigger: agentActivity.summary.needsYourTurnCount)
            Text("\(agentActivity.summary.actionableCount)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Click-to-jump actions

    private func activateMediaApp(_ info: NowPlayingInfo) {
        guard let bundleID = info.bundleIdentifier else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            activate(app)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Terminals/editors that host agent CLIs, in preference order. The session log
    /// doesn't record which app runs it, so activate the first of these that's running;
    /// with none running, reveal the project folder instead.
    private static let agentHostBundleIDs = [
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp",
        "com.apple.Terminal",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode"
    ]

    private func activateAgentHost(_ session: AgentSession) {
        for bundleID in Self.agentHostBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                activate(app)
                return
            }
        }
        if let path = session.projectPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
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
        VStack(spacing: 5) {
            nowPlayingControlsRow(info)
            if let duration = info.duration, duration > 0, info.elapsed != nil {
                timeline(info, duration: duration)
            }
        }
    }

    private func nowPlayingControlsRow(_ info: NowPlayingInfo) -> some View {
        HStack(spacing: 10) {
            // Artwork + titles jump to the app that's playing; the transport buttons keep
            // their own actions, so only the leading cluster is tappable.
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
            }
            .contentShape(Rectangle())
            .onTapGesture { activateMediaApp(info) }
            .help("Open the playing app")

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

    /// Elapsed/total readout with a thin progress bar. `TimelineView` ticks it every
    /// second, but only while the expanded pill actually renders it - the position is
    /// extrapolated from the last adapter update, no extra polling of the adapter.
    /// Draggable (when enabled in Settings): drag or click the bar to seek; while
    /// scrubbing the local scrub position is shown, then handed to
    /// `NowPlayingController.seek` on release (optimistic, so the bar doesn't snap back).
    private func timeline(_ info: NowPlayingInfo, duration: TimeInterval) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let livePosition = min(max(info.position(at: context.date) ?? 0, 0), duration)
            let position = scrubPosition ?? livePosition
            let fraction = CGFloat(position / duration)
            HStack(spacing: 6) {
                Text(mmss(position))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * fraction, height: 3)
                        if settings.timelineSeekEnabled {
                            // The knob is the draggability affordance; it grows while scrubbing.
                            Circle()
                                .fill(Color.white)
                                .frame(width: scrubPosition != nil ? 9 : 6, height: scrubPosition != nil ? 9 : 6)
                                .offset(x: geo.size.width * fraction - (scrubPosition != nil ? 4.5 : 3))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(seekGesture(width: geo.size.width, duration: duration))
                }
                .frame(height: 12)
                Text(mmss(duration))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.12), value: scrubPosition != nil)
        .accessibilityHidden(true)
    }

    private func seekGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        // minimumDistance 0 makes a plain click seek too, not just a drag.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard settings.timelineSeekEnabled, width > 0 else { return }
                let fraction = min(max(value.location.x / width, 0), 1)
                scrubPosition = TimeInterval(fraction) * duration
            }
            .onEnded { _ in
                guard settings.timelineSeekEnabled, let target = scrubPosition else { return }
                controller.seek(to: target)
                scrubPosition = nil
            }
    }

    private func mmss(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
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

            Text(privacyRedacted(session.taskTitle ?? session.projectLabel, fallback: session.projectLabel))
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
        .contentShape(Rectangle())
        .onTapGesture { activateAgentHost(session) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(session.source.displayName) · \(session.projectLabel) · \(session.taskTitle ?? "") · \(stateLabel(session.state))"))
        .accessibilityHint(Text("Opens your terminal"))
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

    // MARK: - File tray

    /// Drop shelf: file references dragged onto the notch. Renders basenames + Finder
    /// icons only. Click opens the file; items can be dragged out; ✕ removes.
    private var traySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("tray")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if tray.items.isEmpty {
                // A visible drop zone, not just a label - it brightens while targeted.
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isDropTargeted ? Color.white.opacity(0.8) : Color.white.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(height: 26)
                    .overlay(
                        Text(isDropTargeted ? "Drop to add" : "Drop files here")
                            .font(.system(size: 10, weight: isDropTargeted ? .semibold : .regular))
                            .foregroundStyle(isDropTargeted ? .white : .secondary)
                    )
                    .padding(.vertical, 2)
            } else {
                ForEach(tray.items, id: \.self) { url in
                    trayRow(url)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            )
                        )
                }
            }
        }
        // Unlike the agent list (whose 5s re-scan must not re-animate), tray changes are
        // direct user actions - let items visibly slide in/out.
        .animation(spring, value: tray.items)
    }

    private func trayRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: tray.icon(for: url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 190, alignment: .leading)
            Spacer(minLength: 4)
            Button {
                tray.remove(url)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PillButtonStyle())
            .accessibilityLabel(Text("Remove \(url.lastPathComponent) from tray"))
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(url) }
        // `NSItemProvider(contentsOf:)` registers a file representation, so dropping in
        // Finder performs a real copy (the plain NSURL provider only carried a URL type,
        // which Finder ignores).
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
        .help(url.lastPathComponent)
    }

    // MARK: - Calendar glance

    private func calendarRow(_ event: CalendarController.NextEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(privacyRedacted(event.title, fallback: "Busy"))
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
        if s < 6 * 3600 { return "in \(s / 3600)h \((s % 3600) / 60)m" }
        // Further out (24h lookahead): an absolute time reads better than "in 19h 40m".
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let time = formatter.string(from: event.start)
        return Foundation.Calendar.current.isDateInTomorrow(event.start) ? "tmrw \(time)" : time
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

    /// `.symbolEffect(.bounce)` is macOS 14+; on 13 the icon change simply doesn't pulse.
    @ViewBuilder
    func availabilityGuardedBounce(trigger: Int) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.bounce, value: trigger)
        } else {
            self
        }
    }
}
