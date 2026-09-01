import AppKit
import SwiftUI

/// Pure grow-only sizing rules for the AppKit bridge. SwiftUI can report many fractional
/// intermediate sizes during one spring; normalizing and coalescing them keeps the panel
/// from chasing every frame while preserving a stable top-center anchor.
enum PillPanelSizingPolicy {
    static let growthThreshold: CGFloat = 1

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

    static func growthTarget(contentSize: CGSize, currentWindowSize: CGSize) -> CGSize? {
        let content = normalizedContentSize(contentSize)
        guard content.width > 0, content.height > 0 else { return nil }
        let floored = CGSize(
            width: max(content.width, NotchGeometry.contentFloor.width),
            height: max(content.height, NotchGeometry.contentFloor.height)
        )
        let proposed = NotchGeometry.windowSize(forContent: floored)
        let target = CGSize(
            width: max(currentWindowSize.width, proposed.width),
            height: max(currentWindowSize.height, proposed.height)
        )
        guard target.width - currentWindowSize.width >= growthThreshold
                || target.height - currentWindowSize.height >= growthThreshold
        else { return nil }
        return target
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
        guard let screen = NotchGeometry.preferredScreen() else { return nil }
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
            for: screen, windowSize: NotchGeometry.windowSize(forContent: NotchGeometry.contentFloor)
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

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateForScreenChange()
        }
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

    private func resize(toContent contentSize: CGSize) {
        guard let target = PillPanelSizingPolicy.growthTarget(
            contentSize: contentSize,
            currentWindowSize: panel.frame.size
        ) else { return }
        applyPlacement(windowSize: target)
    }

    /// Coalesce one frame of layout feedback. Importantly this is leading/coalescing,
    /// not a long trailing debounce: the panel still grows promptly when content truly
    /// exceeds the stable floor, but never processes every fractional spring sample.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: item)
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
        guard let screen = NotchGeometry.preferredScreen() else { return }
        currentScreen = screen
        let wasNotch = hasPhysicalNotch
        let wasNotchSize = notchSize
        hasPhysicalNotch = screen.safeAreaInsets.top > 0
        notchSize = NotchGeometry.notchSize(for: screen)
        if hasPhysicalNotch != wasNotch || notchSize != wasNotchSize {
            // The pill's notch-aware layout depends on these; rebuild the view.
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
    }

    /// The panel takes mouse events only while the cursor is inside the pill's current
    /// visual rect (top-centered in the panel); everywhere else the window is
    /// click-through so menu-bar items beside/under the transparent margins work.
    /// The same cursor test drives hover-expansion (exit goes through the presentation's
    /// grace period, so edge flicker doesn't collapse the pill).
    private func updateInteractivity() {
        let inside = cursorInsidePill()
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        MainActor.assumeIsolated {
            presentation.setHovering(inside)
        }
    }

    private func cursorInsidePill() -> Bool {
        guard pillContentSize.width > 0, pillContentSize.height > 0 else { return false }
        let slack: CGFloat = 4
        // `NSRect.contains` excludes the top edge (y < maxY), and a cursor pinned against
        // the top of the screen reports y == screen top exactly - the most natural place
        // to point at a notch. Extend the rect a couple of points above the screen so the
        // absolute-top position still counts as inside.
        let topOverscan: CGFloat = 2
        let width = min(panel.frame.width, pillContentSize.width + slack * 2)
        let height = min(panel.frame.height, pillContentSize.height + slack)
        let rect = NSRect(
            x: panel.frame.midX - width / 2,
            y: panel.frame.maxY - height,
            width: width,
            height: height + topOverscan
        )
        return rect.contains(NSEvent.mouseLocation)
    }

    deinit {
        resizeWorkItem?.cancel()
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
