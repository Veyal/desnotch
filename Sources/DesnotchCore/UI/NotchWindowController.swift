import AppKit
import Combine
import SwiftUI

/// Owns the borderless, transparent, always-on-top panel the pill lives in.
///
/// The panel is resized to fit the pill's reported content size (plus shadow room) so
/// the expanded pill is never clipped. Mouse events are let through entirely when there
/// is nothing to show, so an empty panel never eats menu-bar clicks.
public final class NotchWindowController {
    private let panel: NSPanel
    private let controller: NowPlayingController
    private let agentActivity: AgentActivityController
    private let calendar: CalendarController
    private let processMonitor: ProcessMonitorController
    private let presentation: NotchPillPresentation

    private var currentScreen: NSScreen
    private var hasPhysicalNotch: Bool
    private var notchSize: CGSize?
    private var cancellables = Set<AnyCancellable>()
    private var scrollMonitor: Any?
    private var mouseMoveMonitors: [Any] = []

    /// Whether anything is currently shown (drives interactivity together with the cursor).
    private var hasContent = false
    /// The pill's current visual size as reported by SwiftUI (tracks the collapse/expand
    /// animation), used to compute the only region of the panel that should take events.
    private var pillContentSize: CGSize = .zero

    public init?(
        controller: NowPlayingController,
        agentActivity: AgentActivityController,
        calendar: CalendarController,
        processMonitor: ProcessMonitorController,
        presentation: NotchPillPresentation
    ) {
        guard let screen = NotchGeometry.preferredScreen() else { return nil }
        self.controller = controller
        self.agentActivity = agentActivity
        self.calendar = calendar
        self.processMonitor = processMonitor
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
        MainActor.assumeIsolated {
            Publishers.CombineLatest4(
                controller.$info.map { $0?.hasContent == true },
                agentActivity.$summary.map { $0.hasActivity },
                calendar.$nextEvent.map { CalendarController.isImminent($0) },
                processMonitor.$hotProcesses.map { !$0.isEmpty }
            )
            .map { $0 || $1 || $2 || $3 }
            .receive(on: RunLoop.main)
            .sink { [weak self] hasContent in
                self?.hasContent = hasContent
                self?.updateInteractivity()
            }
            .store(in: &cancellables)
        }

        // The panel is much wider than the visible pill (stable size for clean animation),
        // and an event-accepting window swallows clicks meant for the menu bar underneath -
        // per-view hitTest can't give them back. So the *window* only accepts events while
        // the cursor is actually over the pill's current visual rect, tracked via
        // mouse-moved monitors (global = cursor over other apps; local = over us).
        let moveHandler: (NSEvent) -> Void = { [weak self] _ in
            self?.updateInteractivity()
        }
        mouseMoveMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { moveHandler($0) },
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { moveHandler($0); return $0 }
        ].compactMap { $0 }

        // Scroll over the notch adjusts system volume (with a brief readout in the pill).
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let scale: Float = event.hasPreciseScrollingDeltas ? 0.002 : 0.02
            let delta = Float(event.scrollingDeltaY) * scale
            guard delta != 0 else { return event }
            if let level = SystemVolume.adjust(by: delta) {
                MainActor.assumeIsolated { self.presentation.flashVolume(level) }
            }
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
            agentActivity: agentActivity,
            calendar: calendar,
            processMonitor: processMonitor,
            presentation: presentation,
            hasPhysicalNotch: hasPhysicalNotch,
            notchSize: notchSize,
            onSizeChange: { [weak self] size in
                self?.pillContentSize = size
                self?.resize(toContent: size)
                self?.updateInteractivity()
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = hosting
    }

    private func resize(toContent contentSize: CGSize) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        // Floor to a size that fits the expanded pill, then grow-only. Keeping the panel a
        // stable size across collapse/expand means only the SwiftUI content animates (a clean
        // top-anchored scale) instead of the panel recentering mid-spring (the horizontal
        // "slide"). The panel only grows if content exceeds the floor; it never shrinks.
        let floored = CGSize(
            width: max(contentSize.width, NotchGeometry.contentFloor.width),
            height: max(contentSize.height, NotchGeometry.contentFloor.height)
        )
        let windowSize = NotchGeometry.windowSize(forContent: floored)
        let current = panel.frame.size
        guard windowSize.width > current.width || windowSize.height > current.height else { return }
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
        // Re-anchor to the new screen geometry at the current/last known size.
        resize(toContent: lastContentSize())
    }

    /// The panel takes mouse events only while something is shown AND the cursor is inside
    /// the pill's current visual rect (top-centered in the panel); everywhere else the
    /// window is click-through so menu-bar items beside/under the transparent margins work.
    private func updateInteractivity() {
        let shouldAccept = hasContent && cursorInsidePill()
        if panel.ignoresMouseEvents == shouldAccept {
            panel.ignoresMouseEvents = !shouldAccept
        }
        // Once the window is click-through it stops receiving mouse events, so SwiftUI's
        // .onHover may never see the exit - end the hover from here (grace-period applies).
        if !shouldAccept {
            MainActor.assumeIsolated {
                if presentation.isHovering {
                    presentation.setHovering(false)
                }
            }
        }
    }

    private func cursorInsidePill() -> Bool {
        guard pillContentSize.width > 0, pillContentSize.height > 0 else { return false }
        let slack: CGFloat = 4
        let width = min(panel.frame.width, pillContentSize.width + slack * 2)
        let height = min(panel.frame.height, pillContentSize.height + slack)
        let rect = NSRect(
            x: panel.frame.midX - width / 2,
            y: panel.frame.maxY - height,
            width: width,
            height: height
        )
        return rect.contains(NSEvent.mouseLocation)
    }

    deinit {
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
