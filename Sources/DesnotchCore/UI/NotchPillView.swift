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
    let agentRowKeys: [String]
    let hotProcessIDs: [Int32]
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

    @ObservedObject var settings = SettingsStore.shared

    public let hasPhysicalNotch: Bool

    /// Physical notch cutout size (`NotchGeometry.notchSize(for:)`); nil on notch-less screens.
    public let notchSize: CGSize?

    /// Tallest the expanded stack may be (the host screen's height minus a margin); nil =
    /// unlimited. Longer stacks trim their lists (`PillRowCaps`), they never scroll.
    public let maxContentHeight: CGFloat?

    /// Invoked with the pill's natural content size whenever SwiftUI lays it out, so
    /// the owning `NSPanel` can resize to fit content + shadow/overshoot room.
    public var onSizeChange: ((CGSize) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.accessibilityReduceTransparency) var reduceTransparency

    @Environment(\.colorSchemeContrast) var contrast

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

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
        maxContentHeight: CGFloat? = nil,
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
        self.maxContentHeight = maxContentHeight
        self.onSizeChange = onSizeChange
    }

    /// The pill's whole motion vocabulary for the current settings + Reduce Motion.
    /// Every animation below reads from this - don't hand-roll curves in a row.
    var motion: NotchAnimation.Motion {
        NotchAnimation.resolve(style: settings.animationStyle, reduceMotion: reduceMotion)
    }

    /// Blur is a reveal/arrival effect only: Reduce Transparency (and Reduce Motion /
    /// Minimal, via the tokens) turn it off, leaving plain fades and springs.
    var blurAllowed: Bool { motion.allowsBlur && !reduceTransparency }

    /// Secondary row text (Mist Gray; Silver under Increase Contrast).
    var secondaryColor: Color { PillPalette.secondaryText(increasedContrast: contrast == .increased) }

    /// Captions, headers and tertiary glyphs (Slate Gray; Silver under Increase Contrast).
    var captionColor: Color { PillPalette.captionText(increasedContrast: contrast == .increased) }

    /// Transition for a row inserted/removed while the pill is open - bounded grow/slide
    /// in, plain fade out (never `.move(edge:)`, which dragged a row its full height).
    var arrivalTransition: AnyTransition {
        .pillRow(motion, blurAllowed: blurAllowed)
    }

    /// Swap transition for the small wing indicators.
    var indicatorTransition: AnyTransition {
        motion.rowArrivalScale == 1
            ? .opacity
            : .opacity.combined(with: .scale(scale: motion.rowArrivalScale))
    }

    var hasMedia: Bool { settings.nowPlayingEnabled && controller.hasActiveMedia }

    var hasTimer: Bool { focusTimer.state != .idle }

    var hasNotification: Bool { settings.notificationMirrorEnabled && notificationMirror.latest != nil }

    var hasAgents: Bool { settings.agentActivityEnabled && agentActivity.summary.hasActivity }

    var hasHotProcesses: Bool { settings.processMonitorEnabled && !processMonitor.hotProcesses.isEmpty }

    var hasClipboard: Bool { settings.clipboardHistoryEnabled && !clipboard.entries.isEmpty }

    /// Drives the compact calendar indicator; the expanded glance row shows for anything
    /// within the lookahead window.
    var calendarImminent: Bool { settings.calendarEnabled && calendar.isImminent }

    /// Reminders only claim compact space when action is timely: overdue, due today,
    /// or due within 30 minutes. The full section remains one hover away when enabled.
    var reminderUrgent: Bool { settings.remindersEnabled && reminders.isUrgent }

    private var trayEnabled: Bool { settings.trayEnabled }

    /// Width of the black "wing" either side of the physical notch that hosts a minimized
    /// indicator. Sized for the widest content (agent icon + 2-digit count).
    static let wingWidth: CGFloat = WingMetrics.baseWidth

    /// The cutout the layout is built around: the real hardware cutout when present,
    /// otherwise a synthetic one whose size is user-configurable (Settings > Minimized
    /// size; defaults match a MacBook Pro notch, ~200×30pt). Real hardware always wins -
    /// drawing a differently-sized "cutout" over a physical notch would look broken.
    var effectiveNotch: CGSize {
        notchSize ?? CGSize(width: settings.minimizedWidth, height: settings.minimizedHeight)
    }

    /// Fixed width for the expanded pill (user-configurable). The rows contain greedy
    /// `Spacer`s, so without a fixed width the pill would fill whatever the panel proposes
    /// (and feed that measured size back into panel growth - a layout feedback loop). A
    /// definite value keeps it stable; it still never shrinks below the minimized pill
    /// (cutout + wings + grown wings + privacy lanes).
    private var expandedWidth: CGFloat {
        NotchGeometry.expandedPillWidth(
            preferred: CGFloat(settings.expandedWidth),
            cutoutWidth: effectiveNotch.width,
            wingWidth: Self.wingWidth,
            compactWidth: compactWidth
        )
    }

    /// Width the expanded sections are laid out at: constant, independent of the
    /// animating container frame.
    var expandedContentWidth: CGFloat {
        max(0, expandedWidth - NotchGeometry.contentInsetX * 2)
    }

    /// An agent is waiting on the user - reflected by the minimized agent icon (lightning),
    /// but it no longer forces the pill open. The pill is always minimized unless hovered.
    var needsAttention: Bool { agentActivity.summary.needsYourTurnCount > 0 }

    /// A file drag is currently over the notch shape (drives the drop-target visuals
    /// and holds the pill open so the tray is visible while dragging).
    @State var isDropTargeted = false

    /// Timeline position being scrubbed (drag in progress); nil when not scrubbing.
    @State var scrubPosition: TimeInterval?

    /// Explicit two-stage choreography. The hover source remains solely in the window
    /// controller; these states only decide how the latest target is rendered.
    @State var expansionPhase: PillExpansionPhase = .collapsed

    @State private var expandedContentVisible = false

    /// Staged mount of the section stack. Building every section's view graph in one pass costs
    /// tens of milliseconds (it was the dead time and dropped frames at the start of an open), so
    /// the sections are mounted a few at a time on successive run-loop turns, hidden, while the
    /// shell is already moving (Fluid / Lively, over a height placeholder) or still held at the
    /// collapsed size (Minimal / Reduce Motion). Sections up to and including this stacking index
    /// (`PillSectionKind.order`) are mounted; -1 = none, `Int.max` = all.
    @State private var mountedThrough = -1

    @State private var prewarmed = false

    /// Every section is mounted, so the layer may leave the placeholder height and size itself.
    @State private var mountComplete = false

    @State private var compactContentVisible = true

    @State private var expansionGeneration = 0

    @State private var feedbackGlow = false

    @State private var feedbackGeneration = 0

    /// Kind of the flash whose rim glow is showing, kept after the flash ends so the
    /// glow fades out in its own color.
    @State private var glowKind: PillFlashKind?

    /// A flash-open spotlight is lit: the flash's section shows a highlight and the other
    /// sections start dimmed, then both ease back (see `PillRevealModifier`).
    @State private var spotlightLit = false

    /// The tray file / clipboard entry that just landed (drives a one-shot row highlight),
    /// cleared shortly after. Nil on first read so the initial list never flashes.
    @State var landedTrayItem: URL?

    @State var landedClipboardID: UUID?

    @State private var knownTrayItems: [URL]?

    @State private var knownClipboardIDs: [UUID]?

    /// The reminder being completed: kept on screen for `motion.completionHold` (checkbox
    /// filled, strike drawn) after the controller has already dropped it.
    @State var completingReminder: RemindersController.NextReminder?

    @State private var completionGeneration = 0

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
            agentRowKeys: visibleAgentRows.map(\.key),
            hotProcessIDs: processMonitor.hotProcesses.prefix(rowCaps.processes).map(\.id),
            trayItems: tray.items,
            clipboardEntryIDs: clipboard.entries.map(\.id)
        )
    }

    /// Needs-you first (action required), then stalled, then working - most recent first.
    var orderedAgents: [AgentSession] {
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
            .onAppear {
                knownTrayItems = tray.items
                knownClipboardIDs = clipboard.entries.map(\.id)
                synchronizeExpansion(animated: false)
                prewarmSections()
            }
            .onChange(of: isExpanded) { _ in synchronizeExpansion(animated: true) }
            .onChange(of: presentation.feedbackToken) { _ in playFeedbackGlow() }
            .onChange(of: tray.items) { items in noteTrayItems(items) }
            .onChange(of: clipboard.entries.map(\.id)) { ids in noteClipboardEntries(ids) }
            .onChange(of: focusTimer.completion?.token) { token in
                // A timer the user started ran out: the one observer-driven haptic.
                if token != nil { PillHaptics.play(.timerComplete) }
            }
            .onDisappear {
                expansionGeneration += 1
                feedbackGeneration += 1
                completionGeneration += 1
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

    /// One continuous shape, with compact and expanded content sharing a stable layer.
    /// Expansion is staged: the shape retargets first, then the compact wings hand off to
    /// the sections (revealed one by one, see `PillRevealModifier`). On collapse the
    /// content fades before the shape settles back into the hardware. This keeps rapid
    /// hover reversals interruptible and avoids unrelated data updates ever owning the
    /// container spring.
    ///
    /// Layout model: the expanded content is laid out at a CONSTANT width
    /// (`expandedContentWidth`) inside a container whose frame is the one animated
    /// geometry, clipped by the morphing silhouette. Content never sees an animated width,
    /// so text truncation is decided once at the final width and rows do not re-wrap while
    /// the shell grows or shrinks. Height stays layout-driven so it rides the same
    /// transaction as the phase flip.
    var notchBody: some View {
        ZStack(alignment: .top) {
            if expansionPhase.keepsExpandedContainer || mountedThrough >= 0 {
                expandedLayer
                    .allowsHitTesting(expandedContentVisible)
                    // Invisible content (before the reveal starts, after the collapse fade
                    // starts) is not VoiceOver-reachable either; the wings own that moment.
                    .accessibilityHidden(!expandedContentVisible)
                    // Collapse removes the layer mid-fade; finish the fade on the fast
                    // exit curve instead of popping, whatever curve the shape is using.
                    // Insertion is instant: the sections inside reveal themselves (they are
                    // mounted hidden first, so Minimal / Reduce Motion fade them in too).
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .opacity.animation(motion.contentOut)
                    ))
            } else {
                Color.clear
                    .frame(height: effectiveNotch.height)
                    .transition(.identity)
            }

            if compactContentVisible {
                compactContent
                    .transition(.pillWingsLeave(motion, blurAllowed: blurAllowed))
            }
        }
        .frame(width: expansionPhase.keepsExpandedContainer ? expandedWidth : compactWidth)
        // The wings grow for a wide indicator or the privacy-dot lane (`WingMetrics`) on the
        // wing spring; keyed to the compact width alone, so the open/close transactions
        // keep owning every other frame change.
        .animation(motion.wing, value: compactWidth)
        // Solid black, never a material or a lighter drop-target fill: the pill must read
        // as the hardware (nothing is drawn behind the cutout).
        .background(silhouette.fill(Color.black))
        .overlay(
            // Rim: drop-target affordance and flash-open acknowledgement. Fixed 1pt
            // visible width (a 2pt centered stroke, half clipped) so it never jumps size.
            silhouette
                .stroke(rimColor, lineWidth: 2)
                .opacity(rimVisible ? 1 : 0)
                .animation(rimVisible ? motion.fade : motion.glowOut, value: rimVisible)
        )
        .clipShape(silhouette)
        .contentShape(silhouette)
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
                            PillHaptics.play(.trayDrop)
                            presentation.flashOpen(announcement: PillAnnouncements.trayAdded, kind: .tray)
                        }
                    }
                }
            }
            return accepted
        }
        .overlay(alignment: .bottom) {
            // Expanded only: while minimized the readout lives in the wings (see
            // `compactContent`), because a bottom-centered chip on the cutout-high shape
            // would sit entirely behind the hardware.
            let level = expansionPhase == .expanded ? presentation.volumeFlash : nil
            Group {
                if let level {
                    volumeChip(level)
                        .transition(.opacity)
                        .padding(.bottom, 8)
                }
            }
            .animation(motion.swap, value: level != nil)
        }
        .overlay(alignment: .topTrailing) {
            // Mic/camera in-use dots, in a lane at the shape's top-right corner in both states
            // (the camera literally lives in the notch, so this is its natural home). They
            // pop in on the wing spring and vanish instantly; they never pulse (a pulsing
            // privacy indicator trains people to ignore it).
            Group {
                if mediaUse.micInUse || mediaUse.cameraInUse {
                    // A column in the privacy lane (`WingMetrics.privacyLane`), clear of the wing
                    // indicators and their badges; in the expanded pill the lane is the empty
                    // band beside the cutout.
                    VStack(spacing: 3) {
                        if mediaUse.micInUse {
                            mediaUseDot(symbol: "mic.fill", tint: PillPalette.orange)
                        }
                        if mediaUse.cameraInUse {
                            mediaUseDot(symbol: "video.fill", tint: PillPalette.green)
                        }
                    }
                    .padding(.top, 5)
                    // The same ~12pt from the visible edge as the right-wing indicators (the
                    // ear flare eats `topEar` of the frame edge at this row).
                    .padding(.trailing, NotchGeometry.topEar + WingMetrics.textInset - 1)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text([
                        mediaUse.micInUse ? "microphone in use" : nil,
                        mediaUse.cameraInUse ? "camera in use" : nil
                    ].compactMap { $0 }.joined(separator: ", ")))
                }
            }
            .animation(
                motion.wing,
                value: mediaUse.micInUse || mediaUse.cameraInUse
            )
        }
    }

    /// One in-use indicator: a 6pt dot, or a 7pt glyph when Differentiate Without Color is on.
    /// Scales/fades in on the wing spring (plain fade without geometry), removal is instant.
    @ViewBuilder
    private func mediaUseDot(symbol: String, tint: PillPalette.Swatch) -> some View {
        Group {
            if differentiateWithoutColor {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint.color)
            } else {
                Circle().fill(tint.color).frame(width: 6, height: 6)
            }
        }
        .transition(.asymmetric(
            insertion: motion.allowsGeometry
                ? .opacity.combined(with: .scale(scale: 0.5))
                : .opacity,
            removal: .identity
        ))
    }

    /// The expanded layer at its constant width. While the sections are still mounting it holds
    /// the estimated final height, so the shell springs once instead of chasing each section; when
    /// prepared but not yet opened (`.collapsed`, snapping styles) it holds the collapsed height so
    /// nothing shows until the open is one cheap pass.
    private var expandedLayer: some View {
        pillContent
            .frame(width: expandedContentWidth)
            .padding(.horizontal, NotchGeometry.contentInsetX)
            .padding(.top, effectiveNotch.height + NotchGeometry.contentTopGap)
            .padding(.bottom, NotchGeometry.contentBottomInset)
            .frame(height: expandedLayerHeight, alignment: .top)
    }

    private var expandedLayerHeight: CGFloat? {
        guard expansionPhase.keepsExpandedContainer else { return effectiveNotch.height }
        return mountComplete ? nil : estimatedExpandedHeight
    }

    /// Retargets the shared container to the latest expansion source. Delayed work is
    /// generation-guarded, so a fast hover exit/re-entry cannot replay stale phases.
    ///
    /// Open (ms, Fluid): 0 shape springs open (holding the estimated height) and the wings start
    /// leaving; from ~8 the sections mount hidden, a few per turn; once all are mounted (and at
    /// least `shapeLeadDelay` has passed) they reveal, staggered. Minimal / Reduce Motion mount
    /// with the shell still collapsed, then snap it open and fade the sections in together.
    /// Close: 0 sections fade together and the wings fade in; 50 the shape settles back into the
    /// hardware and the stack unmounts.
    private func synchronizeExpansion(animated: Bool) {
        expansionGeneration += 1
        let generation = expansionGeneration

        guard animated else {
            expansionPhase = isExpanded ? .expanded : .collapsed
            expandedContentVisible = isExpanded
            compactContentVisible = !isExpanded
            mountedThrough = isExpanded ? .max : -1
            mountComplete = isExpanded
            return
        }

        if isExpanded {
            let openedAt = CACurrentMediaTime()
            if motion.shapeOpen == nil {
                // Snapping geometry: nothing to stage behind, so never show a shell with an empty
                // body. Mount the stack first (hidden, shell held at the collapsed size, wings
                // untouched), then snap open in one cheap pass while the sections fade in over
                // the wings' fade-out.
                let open = {
                    withAnimation(motion.shapeOpen) {
                        mountComplete = true
                        expansionPhase = .expanded
                        expandedContentVisible = true
                    }
                    withAnimation(motion.contentOut) {
                        compactContentVisible = false
                    }
                }
                if mountComplete {
                    open()
                } else {
                    mountSections(generation: generation, then: open)
                }
                return
            }
            withAnimation(motion.shapeOpen) {
                expansionPhase = .expanding
            }
            withAnimation(motion.contentOut) {
                compactContentVisible = false
            }
            let reveal = {
                withAnimation(motion.contentIn) {
                    expandedContentVisible = true
                    expansionPhase = .expanded
                }
            }
            if mountComplete {
                // `.expanding` renders the hidden sections first; hop to the next turn even
                // with no lead delay so the reveal is a real transition, not the first frame.
                scheduleExpansionStep(after: motion.shapeLeadDelay, generation: generation, forceDefer: true, action: reveal)
            } else {
                mountSections(generation: generation) {
                    // The estimate gives way to the real height on the shape's own spring.
                    withAnimation(motion.shapeOpen) { mountComplete = true }
                    let remaining = max(0, motion.shapeLeadDelay - (CACurrentMediaTime() - openedAt))
                    scheduleExpansionStep(after: remaining, generation: generation, forceDefer: true, action: reveal)
                }
            }
        } else {
            guard expansionPhase != .collapsed else {
                // Prepared (snapping styles) but never opened: just drop the stack.
                mountedThrough = -1
                mountComplete = false
                return
            }
            withAnimation(motion.contentOut) {
                expandedContentVisible = false
                expansionPhase = .collapsing
            }
            withAnimation(motion.wing) {
                compactContentVisible = true
            }
            scheduleExpansionStep(after: motion.collapseShapeDelay, generation: generation) {
                withAnimation(motion.shapeClose) {
                    expansionPhase = .collapsed
                    mountedThrough = -1
                    mountComplete = false
                }
            }
        }
    }

    /// Mounts the sections one stacking index at a time (skipping kinds with nothing to show),
    /// each on its own run-loop turn so no single pass costs more than about a frame, then calls
    /// `completion`. Generation-guarded: a hover reversal abandons the remaining stages.
    private func mountSections(generation: Int, then completion: @escaping () -> Void) {
        let kinds = PillSectionKind.allCases.filter(hasSection)
        func step(_ index: Int) {
            guard generation == expansionGeneration else { return }
            guard index < kinds.count else {
                mountedThrough = .max
                completion()
                return
            }
            mountedThrough = max(mountedThrough, kinds[index].order)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mountStageGap) { step(index + 1) }
        }
        // The first stage waits a beat so the pass that starts the shape stays tiny.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mountStageGap * 2) { step(0) }
    }

    /// Pays the first-use costs of the section views (type metadata, fonts, symbols) once, shortly
    /// after launch while the pill is idle: mounts the stack hidden and collapsed, then drops it.
    /// Without it the first hover after launch spends two or three frames on the first stage.
    private func prewarmSections() {
        guard !prewarmed else { return }
        prewarmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prewarmDelay) {
            guard expansionPhase == .collapsed, !isExpanded, mountedThrough < 0 else { return }
            // Take the choreography's generation so a hover arriving mid-way supersedes this.
            expansionGeneration += 1
            mountSections(generation: expansionGeneration) {
                mountedThrough = -1
                mountComplete = false
            }
        }
    }

    private static let prewarmDelay: TimeInterval = 1.5

    /// Pause between mount stages: long enough for the previous stage to flush and draw.
    private static let mountStageGap: TimeInterval = 0.004

    private func scheduleExpansionStep(
        after delay: TimeInterval,
        generation: Int,
        forceDefer: Bool = false,
        action: @escaping () -> Void
    ) {
        guard delay > 0 || forceDefer else {
            guard generation == expansionGeneration else { return }
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == expansionGeneration else { return }
            action()
        }
    }

    /// Highlights the tray file that just arrived, then lets the highlight fade.
    private func noteTrayItems(_ items: [URL]) {
        defer { knownTrayItems = items }
        guard let added = PillLanding.added(old: knownTrayItems, new: items) else { return }
        landedTrayItem = added
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.landingHold) {
            if landedTrayItem == added { landedTrayItem = nil }
        }
    }

    /// Same for a new clipboard entry. A re-copy only moves an existing entry, so no flash.
    private func noteClipboardEntries(_ ids: [UUID]) {
        defer { knownClipboardIDs = ids }
        guard let added = PillLanding.added(old: knownClipboardIDs, new: ids) else { return }
        landedClipboardID = added
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.landingHold) {
            if landedClipboardID == added { landedClipboardID = nil }
        }
    }

    /// Completes a reminder: the controller call is immediate, but the row stays as a local
    /// "completing" snapshot (checkbox fills, strike draws) for `completionHold` before it
    /// leaves, so the capture is seen, not just a row vanishing.
    func completeReminder(_ reminder: RemindersController.NextReminder) {
        if reminders.complete(reminder.id) {
            PillHaptics.play(.reminderComplete)
            completionGeneration += 1
            let generation = completionGeneration
            completingReminder = reminder
            presentation.flashOpen(announcement: PillAnnouncements.reminderCompleted, kind: .reminder)
            DispatchQueue.main.asyncAfter(deadline: .now() + motion.completionHold) {
                guard generation == completionGeneration else { return }
                completingReminder = nil
            }
        } else {
            AccessibilityAnnouncer.announce(PillAnnouncements.reminderFailed)
            NSSound.beep()
        }
    }

    /// One-shot acknowledgement for a flash-open or drop: the rim glows (tinted by the
    /// flash kind) and, for a classified flash, the spotlight highlight lights. Both are
    /// finite: every step is generation-guarded and ends at rest.
    private func playFeedbackGlow() {
        feedbackGeneration += 1
        let generation = feedbackGeneration
        glowKind = presentation.flashKind
        withAnimation(motion.fade) { feedbackGlow = true }
        if presentation.flashKind != nil {
            withAnimation(motion.fade) { spotlightLit = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.feedbackHold) {
            guard generation == feedbackGeneration else { return }
            withAnimation(motion.glowOut) { feedbackGlow = false }
        }
        if presentation.flashKind != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(motion.feedbackHold, motion.spotlightHold)) {
                guard generation == feedbackGeneration else { return }
                spotlightLit = false
            }
        }
    }

    /// The silhouette, with both radii tied to the expansion phase so corners animate on
    /// the same spring as the frame.
    var silhouette: NotchShape {
        NotchShape(
            topEar: NotchGeometry.topEar,
            bottomRadius: expansionPhase.keepsExpandedContainer
                ? NotchGeometry.expandedBottomRadius : NotchGeometry.collapsedBottomRadius
        )
    }

    private var rimVisible: Bool { isDropTargeted || feedbackGlow }

    private var rimColor: Color {
        if reduceTransparency {
            // Opaque stand-in for `white 0.35` over black.
            return Color(white: 0.35)
        }
        guard !isDropTargeted, let kind = glowKind else {
            return Color.white.opacity(isDropTargeted ? 0.35 : 0.30)
        }
        let rim = kind.rim(pluggedIn: battery.state?.isPluggedIn ?? true)
        switch rim.hue {
        case .neutral: return Color.white.opacity(rim.opacity)
        case .green: return Color.green.opacity(rim.opacity)
        case .amber: return Color.yellow.opacity(rim.opacity)
        case .cyan: return Color.cyan.opacity(rim.opacity)
        }
    }

    /// The flash's section, or the tray while a file is being dragged over: it reveals
    /// first ("this is why I opened").
    private var spotlightSection: PillSectionKind? {
        if presentation.openFlash, let kind = presentation.flashKind { return kind.spotlight }
        return isDropTargeted ? .tray : nil
    }

    /// Wraps a section in the staggered reveal. Dividers pass `spotlightable: false` so
    /// they never get the highlight or the dim.
    @ViewBuilder
    private func reveal<Content: View>(
        _ kind: PillSectionKind,
        spotlightable: Bool = true,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        if kind.order <= mountedThrough {
            revealed(kind, spotlightable: spotlightable, content)
        }
    }

    private func revealed<Content: View>(
        _ kind: PillSectionKind,
        spotlightable: Bool,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let flashed = presentation.openFlash ? presentation.flashKind?.spotlight : nil
        let role: PillSpotlightRole
        if !spotlightable || flashed == nil {
            role = .none
        } else {
            role = flashed == kind ? .lead : .follower
        }
        return content().modifier(
            PillRevealModifier(
                visible: expandedContentVisible,
                rank: PillStagger.rank(of: kind, spotlight: spotlightSection),
                motion: motion,
                blurAllowed: blurAllowed,
                role: role,
                spotlightLit: spotlightLit,
                isLastInStack: kind == (trayEnabled ? .tray : .privacy)
            )
        )
    }

    private func revealDivider(_ kind: PillSectionKind) -> some View {
        reveal(kind, spotlightable: false) { sectionDivider }
    }

    /// Momentary readout after scroll-to-adjust while expanded: a floating 24pt chip hugging
    /// the shape's bottom edge. The level bar follows the scroll on the direct-manipulation
    /// spring. Opaque black under Reduce Transparency (the translucent chip is only
    /// legible because it is nearly opaque anyway), with a hairline so it reads against
    /// the rows behind it.
    private func volumeChip(_ level: Float) -> some View {
        let clamped = CGFloat(max(0, min(1, level)))
        return HStack(spacing: 6) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 72, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 72 * clamped, height: 4)
                        .animation(motion.direct, value: clamped)
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            Capsule()
                .fill(Color.black.opacity(reduceTransparency ? 1 : 0.92))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The tray is the last section (when enabled). With every section disabled or empty
    /// the expanded pill still shows a small placeholder rather than an empty black blob.
    private var pillContent: some View {
        VStack(spacing: 0) {
            if hasNotification, let banner = notificationMirror.latest {
                reveal(.notification) { notificationRow(banner) }
                // Only a section that renders between the notification and the privacy row
                // counts: the privacy divider already separates it from the privacy row and
                // the tray, so counting the tray here stacked two rules back to back.
                if hasMiddleSection {
                    revealDivider(.media)
                }
            }
            if hasMedia, let info = controller.info {
                reveal(.media) { nowPlayingRow(info) }
            }
            if hasMedia && hasTimer {
                revealDivider(.timer)
            }
            if hasTimer {
                reveal(.timer) { focusTimerSection }
            }
            if (hasMedia || hasTimer) && hasAgents {
                revealDivider(.agents)
            }
            if hasAgents {
                reveal(.agents) { agentSection }
            }
            if (hasMedia || hasTimer || hasAgents) && hasHotProcesses {
                revealDivider(.processes)
            }
            if hasHotProcesses {
                reveal(.processes) { processSection }
            }
            if (hasMedia || hasTimer || hasAgents || hasHotProcesses) && showCalendarRow {
                revealDivider(.calendar)
            }
            if showCalendarRow {
                reveal(.calendar) {
                    if let event = calendar.nextEvent {
                        calendarRow(event)
                    } else {
                        calendarAccessHint
                    }
                }
            }
            if showReminderSection {
                if hasMedia || hasTimer || hasAgents || hasHotProcesses || showCalendarRow {
                    revealDivider(.reminders)
                }
                reveal(.reminders) { reminderSection }
            }
            if showBatteryRow, let state = battery.state {
                if hasMedia || hasTimer || hasAgents || hasHotProcesses || showCalendarRow || showReminderSection {
                    revealDivider(.battery)
                }
                reveal(.battery) { batteryRow(state) }
            }
            if hasClipboard {
                if hasMedia || hasTimer || hasAgents || hasHotProcesses || showCalendarRow || showReminderSection
                    || (showBatteryRow && battery.state != nil) {
                    revealDivider(.clipboard)
                }
                reveal(.clipboard) { clipboardSection }
            }
            if hasContentBeforePrivacyAction {
                revealDivider(.privacy)
            }
            reveal(.privacy) { privacyAction }
            if trayEnabled {
                revealDivider(.tray)
                reveal(.tray) { traySection }
            }
        }
        // The single owner of section layout animation: only structural changes (a
        // section or row appearing/disappearing) animate the stack.
        .animation(motion.structural, value: structuralAnimationState)
    }
}
