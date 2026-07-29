import AppKit
import SwiftUI

/// Owns the borderless, transparent, always-on-top panel the pill lives in.
final class NotchWindowController {
    private let panel: NSPanel
    private let controller: NowPlayingController
    private let agentActivity: AgentActivityController

    private static let expandedSize = CGSize(width: 300, height: 44)

    init?(controller: NowPlayingController, agentActivity: AgentActivityController) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        self.controller = controller
        self.agentActivity = agentActivity

        let placement = NotchGeometry.placement(for: screen, expandedSize: Self.expandedSize)

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
        panel.ignoresMouseEvents = false

        let hosting = NSHostingView(
            rootView: NotchPillView(
                controller: controller, agentActivity: agentActivity, hasPhysicalNotch: placement.hasPhysicalNotch
            )
        )
        hosting.frame = NSRect(origin: .zero, size: placement.frame.size)
        panel.contentView = hosting

        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.repositionForCurrentScreen()
        }
    }

    private func repositionForCurrentScreen() {
        guard let screen = NSScreen.main else { return }
        let placement = NotchGeometry.placement(for: screen, expandedSize: Self.expandedSize)
        panel.setFrame(placement.frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: placement.frame.size)
    }
}
