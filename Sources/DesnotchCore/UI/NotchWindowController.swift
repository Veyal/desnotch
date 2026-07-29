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
    private let presentation: NotchPillPresentation

    private var currentScreen: NSScreen
    private var hasPhysicalNotch: Bool
    private var notchSize: CGSize?
    private var cancellables = Set<AnyCancellable>()

    public init?(controller: NowPlayingController, agentActivity: AgentActivityController, presentation: NotchPillPresentation) {
        guard let screen = NotchGeometry.preferredScreen() else { return nil }
        self.controller = controller
        self.agentActivity = agentActivity
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
            Publishers.CombineLatest(
                controller.$info.map { $0?.hasContent == true },
                agentActivity.$summary.map { $0.hasActivity }
            )
            .map { $0 || $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] hasContent in
                self?.panel.ignoresMouseEvents = !hasContent
            }
            .store(in: &cancellables)
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
            presentation: presentation,
            hasPhysicalNotch: hasPhysicalNotch,
            notchSize: notchSize,
            onSizeChange: { [weak self] size in
                self?.resize(toContent: size)
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
