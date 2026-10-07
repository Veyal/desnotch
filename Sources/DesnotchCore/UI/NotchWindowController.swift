import AppKit
import Combine
import SwiftUI

/// Pure grow-only sizing rules for the AppKit bridge. The panel starts at the (large,
/// transparent) content floor so ordinary open/close never resizes it; SwiftUI can still
/// report many fractional intermediate sizes during one spring, so measurements are
/// normalized and coalesced, and the rare real growth is quantized with headroom so a
/// spring overshoot cannot re-trigger it.
enum PillPanelSizingPolicy {
    static let growthThreshold: CGFloat = 1

    /// Growth rounds up to a multiple of this, plus `growthHeadroom`, so a stack that is
    /// a few points too tall for the floor grows once instead of on every new row.
    static let growthQuantum: CGFloat = 64
    static let growthHeadroom: CGFloat = 64

    static func normalizedContentSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite else { return .zero }
        return CGSize(
            width: max(0, size.width).rounded(.up),
            height: max(0, size.height).rounded(.up)
        )
    }

    static func coalesced(_ first: CGSize, _ second: CGSize) -> CGSize {
        CGSize(width: max(first.width, second.width), height: max(first.height, second.height))
    }

    /// One axis: keep the current content capacity unless `content` exceeds it, then grow
    /// to the next quantum with headroom. Never below `floor`, never shrinks.
    static func grownCapacity(content: CGFloat, current: CGFloat, floor: CGFloat) -> CGFloat {
        let base = max(current, floor)
        guard content > base else { return base }
        let needed = content + growthHeadroom
        return (needed / growthQuantum).rounded(.up) * growthQuantum
    }

    static func growthTarget(
        contentSize: CGSize,
        currentWindowSize: CGSize,
        floor: CGSize = NotchGeometry.contentFloor
    ) -> CGSize? {
        let content = normalizedContentSize(contentSize)
        guard content.width > 0, content.height > 0 else { return nil }
        let currentContent = CGSize(
            width: max(0, currentWindowSize.width - NotchGeometry.shadowInsetX * 2),
            height: max(0, currentWindowSize.height - NotchGeometry.shadowInsetBottom)
        )
        let target = NotchGeometry.windowSize(forContent: CGSize(
            width: grownCapacity(content: content.width, current: currentContent.width, floor: floor.width),
            height: grownCapacity(content: content.height, current: currentContent.height, floor: floor.height)
        ))
        guard target.width - currentWindowSize.width >= growthThreshold
                || target.height - currentWindowSize.height >= growthThreshold
        else { return nil }
        return CGSize(
            width: max(currentWindowSize.width, target.width),
            height: max(currentWindowSize.height, target.height)
        )
    }
}

/// Owns the borderless, transparent, always-on-top panel the pill lives in.
///
/// The panel is resized to fit the pill's reported content size (plus shadow room) so
/// the expanded pill is never clipped. Mouse events are let through entirely when there
/// is nothing to show, so an empty panel never eats menu-bar clicks.
public final class NotchWindowController {
    private let panel: NSPanel
    private let controller: NowPlayingController
    private let focusTimer: FocusTimerController
    private let agentActivity: AgentActivityController
    private let calendar: CalendarController
    private let reminders: RemindersController
    private let onAddReminder: () -> Void
    private let processMonitor: ProcessMonitorController
    private let clipboard: ClipboardController
    private let tray: TrayController
    private let battery: BatteryController
    private let mediaUse: MediaUseMonitor
    private let notificationMirror: NotificationMirrorController
    private let presentation: NotchPillPresentation

    private var currentScreen: NSScreen
    private var hasPhysicalNotch: Bool
    private var notchSize: CGSize?
    private var scrollMonitor: Any?
    private var mouseMoveMonitors: [Any] = []
    private var pendingContentSize: CGSize = .zero
    private var resizeWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var displaySettingObserver: AnyCancellable?

    /// Held open from the status menu or the global shortcut. A second input to the same
    /// `updateInteractivity()` decision that hover uses - never a second hover source.
    public private(set) var isPinnedOpen = false

    /// The pill's current visual size as reported by SwiftUI (tracks the collapse/expand
    /// animation), used to compute the only region of the panel that should take events.
    private var pillContentSize: CGSize = .zero

    public init?(
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
        presentation: NotchPillPresentation
    ) {
        guard let screen = NotchGeometry.preferredScreen(
            identifier: MainActor.assumeIsolated { SettingsStore.shared.pillDisplayIdentifier }
        ) else { return nil }
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
        self.currentScreen = screen
        self.hasPhysicalNotch = screen.safeAreaInsets.top > 0
        self.notchSize = NotchGeometry.notchSize(for: screen)

        // Start at the content-floor size so the first content measurement doesn't trigger a
        // grow/recenter (which would look like a slide on launch).
        let placement = NotchGeometry.placement(
            for: screen,
            windowSize: NotchGeometry.windowSize(
                forContent: NotchGeometry.effectiveContentFloor(forScreenSize: screen.frame.size)
            )
        )

        panel = NSPanel(
            contentRect: placement.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Driven by content presence below - an empty panel passes all clicks through.
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        // Borderless, so the title is never drawn; it names the window for VoiceOver when pinned open.
        panel.title = "desnotch notch"
        panel.setAccessibilityLabel("desnotch notch")

        rebuildHosting()

        panel.orderFrontRegardless()

        // Keep the panel click-through in sync with whether anything is actually shown.
        // init runs on the main thread (from applicationDidFinishLaunching), so the
        // main-actor-isolated published projections are reachable here.
        // The panel is much wider than the visible pill (stable size for clean animation),
        // and an event-accepting window swallows clicks meant for the menu bar underneath -
        // per-view hitTest can't give them back. So the *window* only accepts events while
        // the cursor is actually over the pill's current visual rect, tracked via mouse
        // monitors (global = cursor over other apps; local = over us). The same tracker is
        // the single authority for hover-expansion - SwiftUI's .onHover raced panel
        // resizes and could strand the pill open or closed. `.leftMouseDragged` is
        // included so dragging a file over the notch makes the panel interactive and the
        // tray's drop target reachable.
        let moveHandler: (NSEvent) -> Void = { [weak self] _ in
            self?.updateInteractivity()
        }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        mouseMoveMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: events) { moveHandler($0) },
            NSEvent.addLocalMonitorForEvents(matching: events) { moveHandler($0); return $0 }
        ].compactMap { $0 }
        updateInteractivity()

        // Scroll over the notch adjusts system volume (with a brief readout in the pill).
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            guard MainActor.assumeIsolated({ SettingsStore.shared.volumeScrollEnabled }) else { return event }
            let scale: Float = event.hasPreciseScrollingDeltas ? 0.002 : 0.02
            let delta = Float(event.scrollingDeltaY) * scale
            guard delta != 0 else { return event }
            // Consume the scroll only when the adjustment actually landed; devices with
            // no settable volume (some DACs/displays) pass the event through instead of
            // silently eating it.
            guard let level = SystemVolume.adjust(by: delta) else { return event }
            MainActor.assumeIsolated { self.presentation.flashVolume(level) }
            return nil
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateForScreenChange()
        }

        // Picking another display in Settings moves the pill right away. `$pillDisplay` fires
        // before the value is stored, so hop to the next main-queue turn and read it then.
        displaySettingObserver = MainActor.assumeIsolated { SettingsStore.shared.$pillDisplay }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateForScreenChange() }
    }

    /// Holds the pill open (or releases it) for keyboard and VoiceOver users, who cannot hover.
    public func setPinnedOpen(_ pinned: Bool) {
        guard pinned != isPinnedOpen else { return }
        isPinnedOpen = pinned
        updateInteractivity()
        MainActor.assumeIsolated {
            AccessibilityAnnouncer.announce(PillAnnouncements.pinned(pinned))
        }
    }

    public func togglePinnedOpen() {
        setPinnedOpen(!isPinnedOpen)
    }

    /// Plain-text description of every display and where the pill sits, for bug reports.
    public func displayDiagnostics() -> String {
        let screens = ScreenSnapshot.current()
        let setting = MainActor.assumeIsolated { SettingsStore.shared.pillDisplay }
        let index = DisplaySelection.preferredIndex(
            in: screens,
            identifier: MainActor.assumeIsolated { SettingsStore.shared.pillDisplayIdentifier }
        )
        return DisplayDiagnostics.report(
            screens: screens,
            chosenIndex: index,
            setting: setting,
            panelFrame: panel.frame,
            pinnedOpen: isPinnedOpen
        )
    }

    private func rebuildHosting() {
        let rootView = NotchPillView(
            controller: controller,
            focusTimer: focusTimer,
            agentActivity: agentActivity,
            calendar: calendar,
            reminders: reminders,
            onAddReminder: onAddReminder,
            processMonitor: processMonitor,
            clipboard: clipboard,
            tray: tray,
            battery: battery,
            mediaUse: mediaUse,
            notificationMirror: notificationMirror,
            presentation: presentation,
            hasPhysicalNotch: hasPhysicalNotch,
            notchSize: notchSize,
            maxContentHeight: Self.maxContentHeight(for: currentScreen),
            onSizeChange: { [weak self] size in
                guard let self else { return }
                let normalized = PillPanelSizingPolicy.normalizedContentSize(size)
                self.pillContentSize = normalized
                self.scheduleResize(toContent: normalized)
                self.updateInteractivity()
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = hosting
    }

    /// The tallest the expanded stack may be on `screen`: its height minus a margin below the
    /// pill. Longer stacks trim their lists first (`PillRowCaps`) instead of running off.
    static func maxContentHeight(for screen: NSScreen) -> CGFloat {
        max(0, screen.frame.height - 24)
    }

    private func resize(toContent contentSize: CGSize) {
        guard let target = PillPanelSizingPolicy.growthTarget(
            contentSize: contentSize,
            currentWindowSize: panel.frame.size,
            floor: NotchGeometry.effectiveContentFloor(forScreenSize: currentScreen.frame.size)
        ) else { return }
        applyPlacement(windowSize: target)
    }

    /// Coalesce one layout pass of feedback. Importantly this is leading/coalescing,
    /// not a trailing debounce: growth is applied on the next main-queue turn (before the
    /// next frame is committed, so the first frame after a threshold breach is not
    /// clipped by the old panel size), but never per fractional spring sample. Deferring
    /// out of the preference-change callback also avoids resizing the host mid-layout.
    private func scheduleResize(toContent contentSize: CGSize) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        pendingContentSize = PillPanelSizingPolicy.coalesced(pendingContentSize, contentSize)
        guard resizeWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pending = self.pendingContentSize
            self.pendingContentSize = .zero
            self.resizeWorkItem = nil
            self.resize(toContent: pending)
        }
        resizeWorkItem = item
        DispatchQueue.main.async(execute: item)
    }

    /// Positions the panel for `currentScreen` at the given size, unconditionally.
    /// `resize(toContent:)` gates this behind grow-only; screen changes must NOT -
    /// a resolution switch or display reconnect needs a re-anchor even at the same size,
    /// or the pill is left at stale (possibly off-screen) coordinates.
    private func applyPlacement(windowSize: CGSize) {
        let placement = NotchGeometry.placement(for: currentScreen, windowSize: windowSize)
        panel.setFrame(placement.frame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: placement.frame.size)
    }

    private func updateForScreenChange() {
        guard let screen = NotchGeometry.preferredScreen(
            identifier: MainActor.assumeIsolated { SettingsStore.shared.pillDisplayIdentifier }
        ) else { return }
        let wasHeight = Self.maxContentHeight(for: currentScreen)
        currentScreen = screen
        let wasNotch = hasPhysicalNotch
        let wasNotchSize = notchSize
        hasPhysicalNotch = screen.safeAreaInsets.top > 0
        notchSize = NotchGeometry.notchSize(for: screen)
        if hasPhysicalNotch != wasNotch || notchSize != wasNotchSize
            || Self.maxContentHeight(for: screen) != wasHeight {
            // The pill's notch-aware layout depends on these; rebuild the view. The old
            // measurement belongs to the discarded view, so drop it: until the new one
            // reports, no stale rect may define the hit region.
            pillContentSize = .zero
            rebuildHosting()
        }
        // Grow if the content needs it, then ALWAYS re-anchor to the new screen geometry
        // (the grow-only guard in resize used to swallow the reposition entirely).
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        let content = PillPanelSizingPolicy.coalesced(lastContentSize(), pendingContentSize)
        pendingContentSize = .zero
        resize(toContent: content)
        applyPlacement(windowSize: panel.frame.size)
        // The panel moved (or the hosted view changed) under a possibly stationary cursor:
        // re-run the one hover/click-through decision instead of waiting for the next
        // mouse event.
        updateInteractivity()
    }

    /// The panel takes mouse events only while the cursor is inside the pill's current
    /// visual rect (top-centered in the panel); everywhere else the window is
    /// click-through so menu-bar items beside/under the transparent margins work.
    /// The same cursor test drives hover-expansion (exit goes through the presentation's
    /// grace period, so edge flicker doesn't collapse the pill); `isPinnedOpen` keeps the
    /// hover state on without the cursor (see `PillInteractionPolicy`).
    private func updateInteractivity() {
        let inside = cursorInsidePill()
        let acceptsMouse = PillInteractionPolicy.acceptsMouse(cursorInside: inside)
        if panel.ignoresMouseEvents == acceptsMouse {
            panel.ignoresMouseEvents = !acceptsMouse
        }
        MainActor.assumeIsolated {
            presentation.setHovering(
                PillInteractionPolicy.wantsHover(cursorInside: inside, pinnedOpen: isPinnedOpen)
            )
        }
    }

    private func cursorInsidePill() -> Bool {
        guard let rect = PillInteractionPolicy.interactiveRect(
            panelFrame: panel.frame, pillContentSize: pillContentSize
        ) else { return false }
        return rect.contains(NSEvent.mouseLocation)
    }

    deinit {
        resizeWorkItem?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        for monitor in mouseMoveMonitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func lastContentSize() -> CGSize {
        let frame = panel.contentView?.frame.size ?? .zero
        if frame.width > 0 {
            return CGSize(
                width: max(frame.width - NotchGeometry.shadowInsetX * 2, 0),
                height: max(frame.height - NotchGeometry.shadowInsetBottom, 0)
            )
        }
        return CGSize(width: NotchGeometry.fallbackWidth, height: NotchGeometry.fallbackHeight)
    }
}
