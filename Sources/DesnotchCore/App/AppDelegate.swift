import AppKit

/// Thin application delegate: single-instance guard and launch/terminate sequencing. The
/// controller graph lives in `AppComposition`, the notch panel and ordinary windows in
/// `WindowCoordinator`, and the status item and its menu in `StatusMenuBuilder`.
///
/// No dock icon by default (accessory activation policy); `main.swift` handles
/// SIGTERM/SIGINT so `pkill` cleans up the perl adapter subprocess instead of orphaning it.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var composition: AppComposition?
    private var windows: WindowCoordinator?
    private var statusMenu: StatusMenuBuilder?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let smokeTestMode = ProcessInfo.processInfo.environment["DESNOTCH_SMOKE_TEST"] == "1"
        // Single-instance guard: if another desnotch is already running, bow out.
        // This applies in smoke-test mode too, so the smoke script can never race a
        // live install's adapter stream, status item, or SIGTERM assertions.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        if running.contains(where: { $0 != NSRunningApplication.current }) {
            NSApp.terminate(nil)
            return
        }

        // Ask for notification permission now, not at the first needs-you event - a
        // lazy request drops the very notification that triggered it.
        if !smokeTestMode {
            AgentAttentionNotifier.shared.requestAuthorizationAtLaunch()
        }

        let composition = AppComposition(smokeTestMode: smokeTestMode)
        let windows = WindowCoordinator(composition: composition)
        let statusMenu = StatusMenuBuilder(composition: composition, windows: windows)
        self.composition = composition
        self.windows = windows
        self.statusMenu = statusMenu

        statusMenu.install()
        composition.installUpdateChecker { [weak statusMenu] version in
            statusMenu?.showUpdateMenuItem(version: version)
        }
        windows.installNotchWindow()
        // Smoke runs must not take a key combination away from the developer's other apps.
        composition.installGlobalHotKey { [weak windows] in
            windows?.notchWindowController?.togglePinnedOpen()
        }

        if !smokeTestMode {
            windows.showOnboardingIfFirstRun()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stopOwnedProcesses()
    }

    /// Shared by normal AppKit termination and the signal sources in `main.swift`.
    public func stopOwnedProcesses() {
        // A duplicate launch terminates before the composition exists. Touching `shared` there
        // would lazily build the bridge, whose init spawns the perl adapter, only to stop it.
        guard let composition else { return }
        composition.stopOwnedResources()
        MediaRemoteBridge.shared.stopStreaming()
    }

    private static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.desnotch.app"
}
