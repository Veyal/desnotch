import AppKit

/// No dock icon, no menu bar item, no settings UI: this app is exactly the notch pill
/// and nothing else, per MVP scope.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var nowPlayingController: NowPlayingController?
    private var agentActivityController: AgentActivityController?
    private var windowController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let nowPlayingController = NowPlayingController()
        let agentActivityController = AgentActivityController()
        self.nowPlayingController = nowPlayingController
        self.agentActivityController = agentActivityController
        windowController = NotchWindowController(controller: nowPlayingController, agentActivity: agentActivityController)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
