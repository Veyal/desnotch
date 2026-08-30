import SwiftUI
import UniformTypeIdentifiers

/// Collapses the pill's many structural animation triggers into one Equatable value.
/// A single transaction is cheaper and, when several states change together, avoids
/// whichever chained `.animation` modifier happened to be outermost winning by accident.
private struct PillPrimaryAnimationState: Equatable {
    let hasMedia: Bool
    let hasAgents: Bool
    let hasHotProcesses: Bool
    let calendarImminent: Bool
    let reminderUrgent: Bool
    let reminderID: String?
    let remindersEnabled: Bool
    let isHovering: Bool
    let pillMode: String
    let minimizedWidth: Double
    let minimizedHeight: Double
    let expandedWidth: Double
    let isDropTargeted: Bool
    let openFlash: Bool
    let trayItems: [URL]
    let animationStyle: String
    let batteryState: BatteryController.BatteryState?
    let hasNotification: Bool
    let notificationArrivalCount: Int
}

private struct PillSecondaryAnimationState: Equatable {
    let volumeReadoutVisible: Bool
    let micInUse: Bool
    let cameraInUse: Bool
    let privacyModeEnabled: Bool
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

    /// The event spring (shape growth, sections appearing).
    private var spring: Animation { motion.primary }

    /// Transition for content arriving in an expanded row - fade always, plus a small
    /// grow/slide when the vocabulary allows it.
    private var arrivalTransition: AnyTransition {
        guard motion.arrivalSlides || motion.arrivalScale != 1 else { return .opacity }
        var insertion = AnyTransition.opacity
        if motion.arrivalScale != 1 {
            insertion = insertion.combined(with: .scale(scale: motion.arrivalScale, anchor: .top))
        }
        if motion.arrivalSlides {
            insertion = insertion.combined(with: .move(edge: .top))
        }
        return .asymmetric(insertion: insertion, removal: .opacity)
    }

    /// Swap transition for the small wing indicators.
    private var indicatorTransition: AnyTransition {
        motion.arrivalScale == 1
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.6))
    }

    private var hasMedia: Bool { settings.nowPlayingEnabled && controller.hasActiveMedia }
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

    /// Expanded while the pointer is over the pill, while a file drag hovers it, briefly
    /// after a successful drop (so the added item is seen landing) - or permanently, when
    /// the user picked the always-on mode in Settings.
    private var isExpanded: Bool {
        settings.pillMode == .alwaysOn
            || presentation.isHovering || isDropTargeted || presentation.openFlash
    }

    private var primaryAnimationState: PillPrimaryAnimationState {
        PillPrimaryAnimationState(
            hasMedia: hasMedia,
            hasAgents: hasAgents,
            hasHotProcesses: hasHotProcesses,
            calendarImminent: calendarImminent,
            reminderUrgent: reminderUrgent,
            reminderID: reminders.nextReminder?.id,
            remindersEnabled: settings.remindersEnabled,
            isHovering: presentation.isHovering,
            pillMode: settings.pillMode.rawValue,
            minimizedWidth: settings.minimizedWidth,
            minimizedHeight: settings.minimizedHeight,
            expandedWidth: settings.expandedWidth,
            isDropTargeted: isDropTargeted,
            openFlash: presentation.openFlash,
            trayItems: tray.items,
            animationStyle: settings.animationStyle.rawValue,
            batteryState: battery.state,
            hasNotification: hasNotification,
            notificationArrivalCount: notificationMirror.arrivalCount
        )
    }

    private var secondaryAnimationState: PillSecondaryAnimationState {
        PillSecondaryAnimationState(
            volumeReadoutVisible: presentation.volumeFlash != nil,
            micInUse: mediaUse.micInUse,
            cameraInUse: mediaUse.cameraInUse,
            privacyModeEnabled: settings.privacyModeEnabled,
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
        .animation(motion.secondary, value: secondaryAnimationState)
        .animation(spring, value: primaryAnimationState)
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

    private var showReminderSection: Bool { settings.remindersEnabled }

    private var showBatteryRow: Bool { settings.batteryEnabled }

    private var hasContentBeforePrivacyAction: Bool {
        hasNotification || hasMedia || hasAgents || hasHotProcesses || hasClipboard || showCalendarRow
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
            if hasNotification, let banner = notificationMirror.latest {
                notificationRow(banner)
                if hasMedia || hasAgents || hasHotProcesses || showCalendarRow
                    || showReminderSection || (showBatteryRow && battery.state != nil)
                    || hasClipboard || trayEnabled {
                    sectionDivider
                }
            }
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
            if showReminderSection {
                if hasMedia || hasAgents || hasHotProcesses || showCalendarRow {
                    sectionDivider
                }
                reminderSection
            }
            if showBatteryRow, let state = battery.state {
                if hasMedia || hasAgents || hasHotProcesses || showCalendarRow || showReminderSection {
                    sectionDivider
                }
                batteryRow(state)
            }
            if hasClipboard {
                if hasMedia || hasAgents || hasHotProcesses || showCalendarRow || showReminderSection
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
    /// expiry never change the pill's measured height mid-animation. `.id` on the
    /// arrival counter makes every new banner re-run the insertion transition even
    /// when it replaces a still-visible one.
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
        .transition(arrivalTransition)
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
    /// warning, then an imminent meeting, then an urgent reminder. Right: agents,
    /// notifications, then whichever urgent item the left wing displaced. Anything
    /// squeezed out is one hover away.
    private var compactContent: some View {
        HStack(spacing: 0) {
            wing {
                if hasMedia {
                    mediaIndicator
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
        .animation(spring, value: controller.info?.isPlaying == true)
        .animation(spring, value: settings.musicIndicatorStyle)
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
                    Text(privacyRedacted(info.artist ?? "", fallback: ""))
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
                .availabilityGuardedSymbolReplace(enabled: motion.allowsPulse)
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
        .animation(motion.secondary, value: scrubPosition != nil)
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
        .onTapGesture { NSWorkspace.shared.open(url) }
        // `NSItemProvider(contentsOf:)` registers a file representation, so dropping in
        // Finder performs a real copy (the plain NSURL provider only carried a URL type,
        // which Finder ignores).
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
        .help(privacyRedacted(url.lastPathComponent, fallback: trayPrivacyName(url)))
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
