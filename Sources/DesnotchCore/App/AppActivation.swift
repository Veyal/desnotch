import AppKit

/// Click-to-jump targets, shared by the pill's tap gestures and the status-menu mirror
/// (the menu is the keyboard/VoiceOver path to the same actions - the pill itself lives
/// in a non-activating panel that assistive tech cannot focus).
enum AppActivation {
    /// Terminals/editors that host agent CLIs, in preference order. The session log
    /// doesn't record which app runs it, so activate the first of these that's running;
    /// with none running, reveal the project folder instead.
    static let agentHostBundleIDs = [
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp",
        "com.apple.Terminal",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode"
    ]

    static func activateMediaApp(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            activate(app)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func activateAgentHost(projectPath: String?) {
        for bundleID in agentHostBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                activate(app)
                return
            }
        }
        if let projectPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: projectPath, isDirectory: true))
        }
    }

    static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
