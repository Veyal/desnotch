import SwiftUI
import UniformTypeIdentifiers

/// Only changes that add/remove laid-out sections participate in the structural spring.
/// Text, progress, polling refreshes, indicator swaps, and transient feedback are scoped
/// to their own subviews so they cannot restart the whole notch morph.
private struct PillStructuralAnimationState: Equatable {
    let hasMedia: Bool
    let hasTimer: Bool
    let hasAgents: Bool
    let hasHotProcesses: Bool
    let hasCalendarRow: Bool
    let hasReminderSection: Bool
    let hasBattery: Bool
    let hasClipboard: Bool
    let hasNotification: Bool
    let trayItems: [URL]
    let clipboardEntryIDs: [UUID]
}

/// The single live-activity pill: always rendered as a (real or synthetic) notch shape,
/// minimized to indicator wings by default, expanded on hover/drag/always-on mode to the
/// stacked enabled feature sections.
///
/// On a screen with a physical notch the pill hugs the hardware: the minimized state is a
/// solid-black extension of the notch with the indicators in small "wings" either side of
/// the cutout (never behind it - that area is opaque hardware), and the expanded state
/// draws below the cutout. Notch-less screens use the synthetic cutout.
///
/// Privacy: rows render basenames, 48-char task-title hints, counts, and states - never
/// full prompts or absolute paths (`AgentSession.projectPath` is a click target only).
/// Privacy mode (`SettingsStore.privacyModeEnabled`) additionally blanks now-playing
/// title/artist, agent task titles, calendar event titles, reminder titles, clipboard previews, tray filenames,
/// and mirrored notification content via `privacyRedacted` - route any new user-content string
/// through it.
public struct NotchPillView: View {
    @ObservedObject public var controller: NowPlayingController
    @ObservedObject public var focusTimer: FocusTimerController
    @ObservedObject public var agentActivity: AgentActivityController
    @ObservedObject public var calendar: CalendarController
    @ObservedObject public var reminders: RemindersController
    @ObservedObject public var processMonitor: ProcessMonitorController
    @ObservedObject public var clipboard: ClipboardController
    @ObservedObject public var tray: TrayController
    @ObservedObject public var battery: BatteryController
    @ObservedObject public var mediaUse: MediaUseMonitor
    @ObservedObject public var notificationMirror: NotificationMirrorController
    @ObservedObject public var presentation: NotchPillPresentation
    public let onAddReminder: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    public let hasPhysicalNotch: Bool
    /// Physical notch cutout size (`NotchGeometry.notchSize(for:)`); nil on notch-less screens.
    public let notchSize: CGSize?

    /// Invoked with the pill's natural content size whenever SwiftUI lays it out, so
    /// the owning `NSPanel` can resize to fit content + shadow/overshoot room.
    public var onSizeChange: ((CGSize) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        controller: NowPlayingController,
        focusTimer: FocusTimerController,
        agentActivity: AgentActivityController,
        calendar: CalendarController,
        reminders: RemindersController,
        onAddReminder: @escaping () -> Void,
        processMonitor: ProcessMonitorController,
        clipboard: ClipboardController,
        tray: TrayController,
        battery: BatteryController,
        mediaUse: MediaUseMonitor,
        notificationMirror: NotificationMirrorController,
        presentation: NotchPillPresentation,
        hasPhysicalNotch: Bool,
        notchSize: CGSize? = nil,
        onSizeChange: ((CGSize) -> Void)? = nil
    ) {
        self.controller = controller
        self.focusTimer = focusTimer
        self.agentActivity = agentActivity
        self.calendar = calendar
        self.reminders = reminders
        self.onAddReminder = onAddReminder
        self.processMonitor = processMonitor
        self.clipboard = clipboard
        self.tray = tray
        self.battery = battery
        self.mediaUse = mediaUse
        self.notificationMirror = notificationMirror
        self.presentation = presentation
        self.hasPhysicalNotch = hasPhysicalNotch
        self.notchSize = notchSize
        self.onSizeChange = onSizeChange
    }

    /// The pill's whole motion vocabulary for the current settings + Reduce Motion.
    /// Every animation below reads from this - don't hand-roll curves in a row.
    private var motion: NotchAnimation.Motion {
        NotchAnimation.resolve(style: settings.animationStyle, reduceMotion: reduceMotion)
    }

    /// Transition for content arriving in an expanded row - fade always, plus a small
    /// grow/slide when the vocabulary allows it. Travel stays bounded rather than using
    /// `.move(edge:)`, which dragged a row its full height.
    private var arrivalTransition: AnyTransition {
        let offset: CGFloat = motion.arrivalSlides ? -5 : 0
        let active = PillArrivalModifier(
            opacity: 0,
            scale: motion.arrivalScale,
            verticalOffset: offset
        )
        let identity = PillArrivalModifier(opacity: 1, scale: 1, verticalOffset: 0)
        return .modifier(active: active, identity: identity)
    }

    /// Swap transition for the small wing indicators.
    private var indicatorTransition: AnyTransition {
        motion.arrivalScale == 1
            ? .opacity
            : .opacity.combined(with: .scale(scale: motion.arrivalScale))
    }

    private var hasMedia: Bool { settings.nowPlayingEnabled && controller.hasActiveMedia }
    private var hasTimer: Bool { focusTimer.state != .idle }
    private var hasNotification: Bool { settings.notificationMirrorEnabled && notificationMirror.latest != nil }
    private var hasAgents: Bool { settings.agentActivityEnabled && agentActivity.summary.hasActivity }
    private var hasHotProcesses: Bool { settings.processMonitorEnabled && !processMonitor.hotProcesses.isEmpty }
    private var hasClipboard: Bool { settings.clipboardHistoryEnabled && !clipboard.entries.isEmpty }
    /// Drives the compact calendar indicator; the expanded glance row shows for anything
    /// within the lookahead window.
    private var calendarImminent: Bool { settings.calendarEnabled && calendar.isImminent }
    /// Reminders only claim compact space when action is timely: overdue, due today,
    /// or due within 30 minutes. The full section remains one hover away when enabled.
    private var reminderUrgent: Bool { settings.remindersEnabled && reminders.isUrgent }
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

    /// Explicit two-stage choreography. The hover source remains solely in the window
    /// controller; these states only decide how the latest target is rendered.
    @State private var expansionPhase: PillExpansionPhase = .collapsed
    @State private var expandedContentVisible = false
    @State private var compactContentVisible = true
    @State private var expansionGeneration = 0
    @State private var feedbackGlow = false
    @State private var feedbackGeneration = 0

    /// Expanded while the pointer is over the pill, while a file drag hovers it, briefly
    /// after a successful drop (so the added item is seen landing) - or permanently, when
    /// the user picked the always-on mode in Settings.
    private var isExpanded: Bool {
        settings.pillMode == .alwaysOn
            || presentation.isHovering || isDropTargeted || presentation.openFlash
    }

    private var structuralAnimationState: PillStructuralAnimationState {
        PillStructuralAnimationState(
            hasMedia: hasMedia,
            hasTimer: hasTimer,
            hasAgents: hasAgents,
            hasHotProcesses: hasHotProcesses,
            hasCalendarRow: showCalendarRow,
            hasReminderSection: showReminderSection,
            hasBattery: showBatteryRow && battery.state != nil,
            hasClipboard: hasClipboard,
            hasNotification: hasNotification,
            trayItems: tray.items,
            clipboardEntryIDs: clipboard.entries.map(\.id)
        )
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
            .onPreferenceChange(PillContentSizePreferenceKey.self) { size in
                onSizeChange?(size)
            }
            .onAppear { synchronizeExpansion(animated: false) }
            .onChange(of: isExpanded) { _ in synchronizeExpansion(animated: true) }
            .onChange(of: presentation.feedbackToken) { _ in playFeedbackGlow() }
            .onDisappear {
                expansionGeneration += 1
                feedbackGeneration += 1
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The pill renders on an always-dark surface; force a dark color scheme so
            // `.secondary` text stays legible in Light Mode too.
            .environment(\.colorScheme, .dark)
    }

    private var sizeReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: PillContentSizePreferenceKey.self, value: proxy.size)
        }
    }

    // MARK: - Pill

    /// One continuous shape, with compact and expanded content sharing a stable layer.
    /// Expansion is staged: the shape retargets first, then the compact indicators hand
    /// off to the rows. On collapse the hand-off reverses before the shape shrinks. This
    /// keeps rapid hover reversals interruptible and avoids unrelated data updates ever
    /// owning the container spring.
    private var notchBody: some View {
        ZStack(alignment: .top) {
            if expansionPhase.keepsExpandedContainer {
                pillContent
                    .padding(.horizontal, 14)
                    .padding(.top, effectiveNotch.height + 4)
                    .padding(.bottom, 8)
                    .opacity(expandedContentVisible ? 1 : motion.expansionContentOpacity)
                    .scaleEffect(
                        expandedContentVisible ? 1 : motion.expansionContentScale,
                        anchor: .top
                    )
                    .offset(y: expandedContentVisible ? 0 : motion.expansionContentOffset)
                    .allowsHitTesting(expandedContentVisible)
                    .transition(.identity)
            } else {
                Color.clear
                    .frame(height: effectiveNotch.height)
                    .transition(.identity)
            }

            if compactContentVisible {
                compactContent
                    .transition(.opacity)
            }
        }
        .frame(width: expansionPhase.keepsExpandedContainer ? expandedWidth : compactWidth)
        .background(
            BottomRoundedRectangle(radius: shapeRadius)
                .fill(isDropTargeted ? Color(white: 0.13) : Color.black)
                .animation(motion.secondary, value: isDropTargeted)
        )
        .overlay(
            // Drop-target affordance: the shape itself lights up while a file hovers it.
            BottomRoundedRectangle(radius: shapeRadius)
                .stroke(
                    Color.white.opacity(isDropTargeted ? 0.6 : (feedbackGlow ? 0.22 : 0)),
                    lineWidth: isDropTargeted ? 1.5 : 1
                )
                .animation(motion.secondary, value: isDropTargeted || feedbackGlow)
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
            Group {
                if let level = presentation.volumeFlash {
                    volumeReadout(level)
                        .transition(.opacity)
                        .padding(.bottom, 3)
                }
            }
            .animation(motion.secondary, value: presentation.volumeFlash != nil)
        }
        .overlay(alignment: .topTrailing) {
            // Mic/camera in-use dots, hugging the shape's top-right corner in both states
            // (the camera literally lives in the notch, so this is its natural home).
            Group {
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
            .animation(
                motion.secondary,
                value: mediaUse.micInUse || mediaUse.cameraInUse
            )
        }
    }

    /// Retargets the shared container to the latest expansion source. Delayed work is
    /// generation-guarded, so a fast hover exit/re-entry cannot replay stale phases.
    private func synchronizeExpansion(animated: Bool) {
        expansionGeneration += 1
        let generation = expansionGeneration

        guard animated else {
            expansionPhase = isExpanded ? .expanded : .collapsed
            expandedContentVisible = isExpanded
            compactContentVisible = !isExpanded
            return
        }

        if isExpanded {
            withAnimation(motion.allowsGeometry ? motion.primary : nil) {
                expansionPhase = .expanding
            }
            scheduleExpansionStep(after: motion.expansionContentDelay, generation: generation) {
                withAnimation(motion.expansionContent) {
                    expandedContentVisible = true
                    compactContentVisible = false
                    expansionPhase = .expanded
                }
            }
        } else {
            withAnimation(motion.expansionContent) {
                expandedContentVisible = false
                compactContentVisible = true
                expansionPhase = .collapsing
            }
            scheduleExpansionStep(after: motion.collapseShapeDelay, generation: generation) {
                withAnimation(motion.allowsGeometry ? motion.primary : nil) {
                    expansionPhase = .collapsed
                }
            }
        }
    }

    private func scheduleExpansionStep(
        after delay: TimeInterval,
        generation: Int,
        action: @escaping () -> Void
    ) {
        guard delay > 0 else {
            guard generation == expansionGeneration else { return }
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == expansionGeneration else { return }
            action()
        }
    }

    private func playFeedbackGlow() {
        feedbackGeneration += 1
        let generation = feedbackGeneration
        withAnimation(motion.secondary) { feedbackGlow = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.feedbackHoldDuration) {
            guard generation == feedbackGeneration else { return }
            withAnimation(motion.secondary) { feedbackGlow = false }
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

    private var shapeRadius: CGFloat {
        expansionPhase.keepsExpandedContainer ? 14 : 10
    }

    private var compactWidth: CGFloat { effectiveNotch.width + Self.wingWidth * 2 }

    private var showCalendarRow: Bool {
        settings.calendarEnabled && (calendar.nextEvent != nil || calendar.accessState == .denied)
    }

    private var showReminderSection: Bool { settings.remindersEnabled }

    private var showBatteryRow: Bool { settings.batteryEnabled }

    private var hasContentBeforePrivacyAction: Bool {
        hasNotification || hasMedia || hasTimer || hasAgents || hasHotProcesses || hasClipboard || showCalendarRow
            || showReminderSection
            || (showBatteryRow && battery.state != nil)
    }

    /// Blank sensitive strings while privacy mode is on (screen sharing/recording).
    /// Scope: now-playing title/artist, agent task titles, calendar event titles, reminder titles,
    /// clipboard previews, and tray filenames - keep any new user-content string behind this too.
    private func privacyRedacted(_ text: String, fallback: String) -> String {
        settings.privacyModeEnabled ? fallback : text
    }

    /// Generic tray label that keeps only the (non-identifying) file type.
    private func trayPrivacyName(_ url: URL) -> String {
        url.pathExtension.isEmpty ? "file" : "file.\(url.pathExtension)"
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
                .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
        }
        .padding(.vertical, 1)
        .animation(motion.secondary, value: state)
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
            if hasNotification, let banner = notificationMirror.latest {
                notificationRow(banner)
                if hasMedia || hasTimer || hasAgents || hasHotProcesses || showCalendarRow
                    || showReminderSection || (showBatteryRow && battery.state != nil)
                    || hasClipboard || trayEnabled {
                    sectionDivider
                }
            }
            if hasMedia, let info = controller.info {
                nowPlayingRow(info)
            }
            if hasMedia && hasTimer {
                sectionDivider
            }
            if hasTimer {
                focusTimerSection
            }
            if (hasMedia || hasTimer) && hasAgents {
                sectionDivider
            }
            if hasAgents {
                agentSection
            }
            if (hasMedia || hasTimer || hasAgents) && hasHotProcesses {
                sectionDivider
            }
            if hasHotProcesses {
                processSection
            }
            if (hasMedia || hasTimer || hasAgents || hasHotProcesses) && showCalendarRow {
                sectionDivider
            }
            if showCalendarRow {
                if let event = calendar.nextEvent {
                    calendarRow(event)
                } else {
                    calendarAccessHint
                }
            }
            if showReminderSection {
                if hasMedia || hasTimer || hasAgents || hasHotProcesses || showCalendarRow {
                    sectionDivider
                }
                reminderSection
            }
            if showBatteryRow, let state = battery.state {
                if hasMedia || hasTimer || hasAgents || hasHotProcesses || showCalendarRow || showReminderSection {
                    sectionDivider
                }
                batteryRow(state)
            }
            if hasClipboard {
                if hasMedia || hasTimer || hasAgents || hasHotProcesses || showCalendarRow || showReminderSection
                    || (showBatteryRow && battery.state != nil) {
                    sectionDivider
                }
                clipboardSection
            }
            if hasContentBeforePrivacyAction {
                sectionDivider
            }
            privacyAction
            if trayEnabled {
                sectionDivider
                traySection
            }
        }
        .animation(
            motion.allowsGeometry ? motion.primary : nil,
            value: structuralAnimationState
        )
    }

    // MARK: - Focus timer

    @ViewBuilder
    private var focusTimerSection: some View {
        Group {
            switch focusTimer.state {
            case .running:
                focusTimerRunningRow
            case .paused:
                focusTimerRow(
                    remaining: focusTimer.remaining,
                    progress: focusTimer.progress,
                    paused: true
                )
            case .completed:
                focusTimerCompletedRow
            case .idle:
                EmptyView()
            }
        }
        .id(focusTimer.state)
        .transition(.opacity)
        .animation(motion.secondary, value: focusTimer.state)
    }

    private var focusTimerRunningRow: some View {
        VStack(spacing: 6) {
            focusTimerControlsRow(paused: false) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    timerCountdownText(timerRemaining(at: context.date))
                }
            }
            TimelineView(.animation(minimumInterval: motion.progressMinimumInterval)) { context in
                timerProgressBar(progress: timerProgress(at: context.date), paused: false)
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 1)
        .frame(minHeight: 38)
        .accessibilityElement(children: .contain)
    }

    private func focusTimerRow(
        remaining: TimeInterval,
        progress: Double,
        paused: Bool
    ) -> some View {
        VStack(spacing: 6) {
            focusTimerControlsRow(paused: paused) {
                timerCountdownText(remaining)
            }
            timerProgressBar(progress: progress, paused: paused)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 1)
        .frame(minHeight: 38)
        .accessibilityElement(children: .contain)
    }

    private func focusTimerControlsRow<Countdown: View>(
        paused: Bool,
        @ViewBuilder countdown: () -> Countdown
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: paused ? "pause.circle.fill" : "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(paused ? .yellow : .cyan)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Focus timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(paused ? "Paused" : "In focus")
                    .font(.system(size: 9))
                    .foregroundStyle(paused ? .yellow : .secondary)
            }

            Spacer(minLength: 4)
            countdown()

            controlButton(
                systemName: paused ? "play.fill" : "pause.fill",
                label: paused ? "Resume focus timer" : "Pause focus timer"
            ) {
                paused ? focusTimer.resume() : focusTimer.pause()
            }
            controlButton(systemName: "xmark", label: "Cancel focus timer") {
                focusTimer.cancel()
            }
        }
    }

    private func timerCountdownText(_ remaining: TimeInterval) -> some View {
        Text(TimeFormatting.clock(ceil(remaining)))
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
            .animation(motion.secondary, value: Int(ceil(remaining)))
            .accessibilityLabel(Text("\(TimeFormatting.clock(ceil(remaining))) remaining"))
    }

    private func timerProgressBar(progress: Double, paused: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(paused ? Color.yellow : Color.cyan)
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, progress))))
            }
        }
        .frame(height: 3)
    }

    private var focusTimerCompletedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 16)
                .availabilityGuardedBounce(
                    trigger: focusTimer.completion?.token.hashValue ?? 0,
                    enabled: motion.allowsPulse
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Focus complete")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Nice work — take a break")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Done") { focusTimer.reset() }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(PillButtonStyle())
                .foregroundStyle(.cyan)
                .accessibilityLabel(Text("Dismiss completed focus timer"))
        }
        .padding(.vertical, 2)
        .frame(minHeight: 38)
        .accessibilityElement(children: .contain)
    }

    private func timerRemaining(at date: Date) -> TimeInterval {
        guard focusTimer.state == .running, let endDate = focusTimer.endDate else {
            return focusTimer.remaining
        }
        return max(0, endDate.timeIntervalSince(date))
    }

    private func timerProgress(at date: Date) -> Double {
        guard focusTimer.duration > 0 else { return 0 }
        return min(1, max(0, 1 - timerRemaining(at: date) / focusTimer.duration))
    }

    // MARK: - Reminders

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(reminderUrgent ? .yellow : .secondary)
                Text("reminders")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onAddReminder) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(reminders.accessState == .granted ? Color.white.opacity(0.65) : Color.gray)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(reminders.accessState != .granted)
                .help("Add reminder")
                .accessibilityLabel(Text("Add reminder"))
            }

            if let reminder = reminders.nextReminder {
                reminderRow(reminder)
                    .id(reminder.id)
                    .transition(arrivalTransition)
            } else {
                reminderEmptyState
            }
        }
        .animation(motion.secondary, value: reminders.nextReminder?.id)
    }

    private func reminderRow(_ reminder: RemindersController.NextReminder) -> some View {
        HStack(spacing: 8) {
            Text(privacyRedacted(reminder.title, fallback: "Reminder"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
            Spacer(minLength: 4)
            Text(RemindersController.dueLabel(reminder))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(reminderUrgent ? .yellow : .secondary)
            Button {
                if reminders.complete(reminder.id) {
                    presentation.flashOpen()
                } else {
                    NSSound.beep()
                }
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .buttonStyle(PillButtonStyle())
            .help("Mark reminder complete")
            .accessibilityLabel(Text("Complete \(privacyRedacted(reminder.title, fallback: "reminder"))"))
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .contain)
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
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.yellow)
                    Text("Reminders access needed — click to allow")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PillButtonStyle())
            .accessibilityLabel(Text("Reminders access needed"))
            .accessibilityHint(Text("Opens Reminders privacy settings"))
        case .granted:
            Text("No due reminders")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .undetermined:
            Text("Checking Reminders…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy action

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("clipboard")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    clipboard.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PillButtonStyle())
                .help("Clear clipboard history")
                .accessibilityLabel(Text("Clear clipboard history"))
            }

            ForEach(Array(clipboard.entries.prefix(3))) { entry in
                HStack(spacing: 6) {
                    Button {
                        clipboard.copy(entry.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: clipboard.copiedEntryID == entry.id ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(clipboard.copiedEntryID == entry.id ? Color.green : Color.secondary)
                                .frame(width: 12)
                            Text(privacyRedacted(entry.preview, fallback: "Clipboard text hidden"))
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(maxWidth: 220, alignment: .leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PillButtonStyle())
                    .help("Copy this item")
                    .accessibilityLabel(Text("Copy \(privacyRedacted(entry.preview, fallback: "clipboard item"))"))

                    Button {
                        clipboard.remove(entry.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(PillButtonStyle())
                    .help("Remove from clipboard history")
                    .accessibilityLabel(Text("Remove clipboard item"))
                }
                .padding(.vertical, 1)
                .id(entry.id)
                .transition(arrivalTransition)
            }

            if clipboard.entries.count > 3 {
                Text("\(clipboard.entries.count - 3) more in the status menu")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacyAction: some View {
        Button {
            settings.privacyModeEnabled.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: settings.privacyModeEnabled ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(settings.privacyModeEnabled ? Color.cyan : Color.white)
                    .frame(width: 14)
                Text("Privacy mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Text(settings.privacyModeEnabled ? "On" : "Off")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(settings.privacyModeEnabled ? Color.cyan : Color.secondary)
                Image(systemName: settings.privacyModeEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(settings.privacyModeEnabled ? Color.cyan : Color.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(settings.privacyModeEnabled ? Color.cyan.opacity(0.14) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        settings.privacyModeEnabled ? Color.cyan.opacity(0.35) : Color.white.opacity(0.1),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PillButtonStyle())
        .help(settings.privacyModeEnabled ? "Show private details" : "Hide private details while sharing your screen")
        .accessibilityLabel(Text("Privacy mode"))
        .accessibilityValue(Text(settings.privacyModeEnabled ? "On" : "Off"))
    }

    /// The mirrored banner row - always the top section (it's the newest event).
    /// Fixed vertical metrics (two fixed-size lines, capped widths) so arrival and
    /// expiry never change the pill's measured height mid-animation. Replacements
    /// crossfade locally; only the section's first appearance changes stack geometry.
    private func notificationRow(_ banner: MirroredNotification) -> some View {
        HStack(spacing: 9) {
            // The icon is the alert's anchor: app-sized, rounded like a system badge,
            // bell fallback in a matching tile so both variants share one silhouette.
            Group {
                if let icon = notificationMirror.sourceIcon(for: banner.appName) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            Image(systemName: "bell.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(banner.appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                Text(privacyRedacted(banner.content ?? "Notification", fallback: "Notification"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 190, alignment: .leading)
            }

            Spacer(minLength: 4)

            Text(relativeTime(banner.receivedAt))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { notificationMirror.activateSource(appName: banner.appName) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Notification from \(banner.appName)\(settings.privacyModeEnabled ? "" : (banner.content.map { ": \($0)" } ?? ""))"))
        .accessibilityHint(Text("Opens \(banner.appName)"))
        .id(notificationMirror.arrivalCount)
        .transition(.opacity)
        .animation(motion.secondary, value: notificationMirror.arrivalCount)
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
    /// One indicator per wing. Left: media wins (it has controls), then an active focus
    /// timer, a stuck-process warning, an imminent meeting, and an urgent reminder.
    /// Right: agents, a timer displaced by media, notifications, then whichever urgent
    /// item the left wing displaced. Anything squeezed out is one hover away.
    private var compactContent: some View {
        HStack(spacing: 0) {
            wing {
                if hasMedia {
                    mediaIndicator
                } else if hasTimer {
                    focusTimerIndicator
                } else if hasHotProcesses {
                    hotProcessIndicator
                } else if calendarImminent {
                    calendarIndicator
                } else if reminderUrgent {
                    reminderIndicator
                }
            }
            Color.clear
                .frame(width: effectiveNotch.width)
            wing {
                if hasAgents {
                    agentIndicator
                } else if hasMedia && hasTimer {
                    focusTimerIndicator
                } else if hasNotification {
                    notificationIndicator
                } else if hasMedia && hasHotProcesses {
                    hotProcessIndicator
                } else if !hasMedia && hasHotProcesses && calendarImminent {
                    calendarIndicator
                } else if reminderUrgent && (hasMedia || hasHotProcesses || calendarImminent) {
                    reminderIndicator
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

    /// User-selectable (Settings > Music indicator): equalizer bars while playing,
    /// the static note, or the current track's album art. Fallback rules live in
    /// `MusicIndicatorResolver` (no artwork or privacy mode → equalizer/note;
    /// reduced motion → never the animated bars). All variants share one fixed
    /// 14×14 slot so style/state changes never shift the wing's layout.
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
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        // Dimmed while paused: a state signal with zero ongoing cost.
                        .opacity(controller.info?.isPlaying == true ? 1 : 0.55)
                        .transition(indicatorTransition)
                }
            case .equalizer:
                NowPlayingEqualizer()
                    .transition(indicatorTransition)
            case .note:
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .transition(indicatorTransition)
            }
        }
        .frame(width: 14, height: 14)
        .foregroundStyle(.white)
        .animation(motion.secondary, value: resolved)
    }

    private var agentIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: needsAttention ? "bolt.fill" : "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(needsAttention ? .yellow : .white)
                // One-shot bounce whenever the needs-you count changes, so the flip is
                // noticeable without hovering (the icon swap alone was silent).
                .availabilityGuardedBounce(
                    trigger: agentActivity.summary.needsYourTurnCount, enabled: motion.allowsPulse
                )
            Text("\(agentActivity.summary.actionableCount)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var focusTimerIndicator: some View {
        switch focusTimer.state {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                compactTimerContents(
                    remaining: timerRemaining(at: context.date),
                    symbol: "timer",
                    color: .cyan
                )
            }
        case .paused:
            compactTimerContents(
                remaining: focusTimer.remaining,
                symbol: "pause.fill",
                color: .yellow
            )
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .availabilityGuardedBounce(
                    trigger: focusTimer.completion?.token.hashValue ?? 0,
                    enabled: motion.allowsPulse
                )
        case .idle:
            EmptyView()
        }
    }

    private func compactTimerContents(
        remaining: TimeInterval,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(TimeFormatting.clock(ceil(remaining)))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }

    // MARK: - Click-to-jump actions (shared with the status-menu mirror)

    private func activateMediaApp(_ info: NowPlayingInfo) {
        AppActivation.activateMediaApp(bundleIdentifier: info.bundleIdentifier)
    }

    private func activateAgentHost(_ session: AgentSession) {
        AppActivation.activateAgentHost(projectPath: session.projectPath)
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

    private var reminderIndicator: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.yellow)
    }

    /// A recent banner is waiting behind a hover; the bell pulses once per arrival.
    private var notificationIndicator: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .availabilityGuardedBounce(
                trigger: notificationMirror.arrivalCount, enabled: motion.allowsPulse
            )
    }

    private var compactAccessibilityLabel: String {
        var parts: [String] = []
        if hasMedia { parts.append(controller.info?.isPlaying == true ? "media playing" : "media paused") }
        if hasTimer {
            switch focusTimer.state {
            case .running:
                parts.append("focus timer \(TimeFormatting.clock(ceil(focusTimer.remaining))) remaining")
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
            parts.append("reminder \(RemindersController.dueLabel(reminder))")
        }
        if hasNotification, let banner = notificationMirror.latest {
            parts.append("notification from \(banner.appName)")
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
                    Text(privacyRedacted(info.title ?? "Unknown Title", fallback: "Now Playing"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(privacyRedacted(info.artist ?? "", fallback: ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: 140, alignment: .leading)
                .animation(
                    motion.secondary,
                    value: "\(info.title ?? "")\u{0}\(info.artist ?? "")"
                )
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
                .availabilityGuardedSymbolReplace(enabled: motion.allowsPulse)
                .animation(motion.secondary, value: info.isPlaying)
                controlButton(systemName: "forward.fill", label: "Next track") {
                    controller.next()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(privacyRedacted(
            "\(info.title ?? "Unknown Title")\(info.artist.map { ", \($0)" } ?? "")",
            fallback: "Now Playing"
        )))
    }

    /// Elapsed/total readout with a thin progress bar. `TimelineView` redraws at the
    /// resolved progress cadence only while the expanded pill renders active playback;
    /// the position is extrapolated from the last adapter update, with no extra polling.
    /// Draggable (when enabled in Settings): drag or click the bar to seek; while
    /// scrubbing the local scrub position is shown, then handed to
    /// `NowPlayingController.seek` on release (optimistic, so the bar doesn't snap back).
    private func timeline(_ info: NowPlayingInfo, duration: TimeInterval) -> some View {
        TimelineView(.animation(
            minimumInterval: motion.progressMinimumInterval,
            paused: !info.isPlaying || scrubPosition != nil
        )) { context in
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
                            // The knob is the draggability affordance; it grows while
                            // scrubbing - but growth is geometric, so Minimal/Reduce
                            // Motion keeps it a constant size (it still tracks the drag,
                            // which is direct manipulation, not decoration).
                            let knob: CGFloat = (motion.allowsGeometry && scrubPosition != nil) ? 9 : 6
                            Circle()
                                .fill(Color.white)
                                .frame(width: knob, height: knob)
                                .offset(x: geo.size.width * fraction - knob / 2)
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
        .animation(motion.press, value: scrubPosition != nil)
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
        TimeFormatting.clock(t)
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

            VStack(alignment: .trailing, spacing: 1) {
                Text(stateLabel(session.state))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(stateColor(session.state))
                Text(freshness(session.lastActivity))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { activateAgentHost(session) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(session.source.displayName) · \(session.projectLabel) · \(privacyRedacted(session.taskTitle ?? session.projectLabel, fallback: session.projectLabel)) · \(stateLabel(session.state)) · \(stateReason(session.state)) · \(freshness(session.lastActivity))"))
        .accessibilityHint(Text("Opens your terminal"))
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
                        .transition(arrivalTransition)
                }
            }
        }
    }

    private func trayRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: tray.icon(for: url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(privacyRedacted(url.lastPathComponent, fallback: trayPrivacyName(url)))
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
            .accessibilityLabel(Text("Remove \(privacyRedacted(url.lastPathComponent, fallback: trayPrivacyName(url))) from tray"))
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { _ = tray.open(url) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(privacyRedacted(
            url.lastPathComponent,
            fallback: trayPrivacyName(url)
        )))
        .accessibilityHint(Text("Opens file; more file actions are available"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open")) { _ = tray.open(url) }
        .accessibilityAction(named: Text("Reveal in Finder")) { _ = tray.revealInFinder(url) }
        .accessibilityAction(named: Text("Copy File")) { _ = tray.copyToPasteboard([url]) }
        .accessibilityAction(named: Text("Share")) { shareTrayItem(url) }
        .contextMenu {
            Button("Open") { _ = tray.open(url) }
            Button("Reveal in Finder") { _ = tray.revealInFinder(url) }
            Button("Copy File") { _ = tray.copyToPasteboard([url]) }
            Button("Share…") { shareTrayItem(url) }
            Divider()
            Button("Remove from Tray", role: .destructive) { tray.remove(url) }
        }
        // `NSItemProvider(contentsOf:)` registers a file representation, so dropping in
        // Finder performs a real copy (the plain NSURL provider only carried a URL type,
        // which Finder ignores).
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
        .help(privacyRedacted(url.lastPathComponent, fallback: trayPrivacyName(url)))
    }

    private func shareTrayItem(_ url: URL) {
        guard tray.items.contains(url),
              FileManager.default.fileExists(atPath: url.path),
              let panel = NSApp.windows.compactMap({ $0 as? NSPanel }).first(where: {
                  $0.styleMask.contains(.nonactivatingPanel)
              }),
              let anchor = panel.contentView
        else { return }
        let picker = NSSharingServicePicker(items: [url])
        let rect = NSRect(x: anchor.bounds.midX, y: anchor.bounds.maxY - 1, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }

    // MARK: - Calendar glance

    private func calendarRow(_ event: CalendarController.NextEvent) -> some View {
        Group {
            if let joinURL = event.joinURL {
                Button {
                    NSWorkspace.shared.open(joinURL)
                } label: {
                    calendarRowContents(event, canJoin: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PillButtonStyle())
                .help("Join meeting")
                .accessibilityLabel(Text("Join next event: \(privacyRedacted(event.title, fallback: "Busy")), \(timeUntil(event))"))
                .accessibilityHint(Text("Opens the meeting link"))
            } else {
                calendarRowContents(event, canJoin: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Next event: \(privacyRedacted(event.title, fallback: "Busy")), \(timeUntil(event))"))
            }
        }
        .padding(.vertical, 1)
    }

    private func calendarRowContents(_ event: CalendarController.NextEvent, canJoin: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(privacyRedacted(event.title, fallback: "Busy"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: canJoin ? 145 : 170, alignment: .leading)
            Spacer(minLength: 4)
            Text(timeUntil(event))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(calendarImminent ? .yellow : .secondary)
            if canJoin {
                Image(systemName: "video.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
        }
    }

    private func timeUntil(_ event: CalendarController.NextEvent) -> String {
        let s = Int(event.start.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        if s < 3600 { return "in \(max(1, s / 60))m" }
        if s < 6 * 3600 { return "in \(s / 3600)h \((s % 3600) / 60)m" }
        // Further out (24h lookahead): an absolute time reads better than "in 19h 40m".
        let time = event.start.formatted(date: .omitted, time: .shortened)
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
