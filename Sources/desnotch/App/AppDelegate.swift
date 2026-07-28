import AppKit

/// No dock icon, no menu bar item, no settings UI: this app is exactly the notch pill
/// and nothing else, per MVP scope.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var nowPlayingController: NowPlayingController?
    private var windowController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let nowPlayingController = NowPlayingController()
        self.nowPlayingController = nowPlayingController
        windowController = NotchWindowController(controller: nowPlayingController)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
