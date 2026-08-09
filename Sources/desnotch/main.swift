import AppKit
import DesnotchCore

// Non-prompting diagnostics for packaged-app smoke tests. This exits before
// NSApplication setup and the single-instance guard, so it can inspect this
// bundle's own TCC identity without disturbing an installed desnotch process.
if ProcessInfo.processInfo.environment["DESNOTCH_PERMISSION_PROBE"] == "1" {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(PermissionSnapshot.current())
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("permission probe failed\n".utf8))
        exit(EXIT_FAILURE)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Minimal app menu so Cmd+Q quits the app (works whenever a desnotch window/status
// item has focus). The status bar item also offers Quit, since the borderless panel
// can't become key.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(
    withTitle: "Quit desnotch",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
)
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

// Handle SIGTERM/SIGINT so `pkill desnotch` / Ctrl-C in a terminal run cleans up the
// long-lived perl adapter subprocess instead of orphaning it
// (`applicationWillTerminate` does not run on signals). Ignore the signal first, then
// let a dispatch source observe it.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let delegate = AppDelegate()
app.delegate = delegate
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let shutdown = {
    delegate.stopOwnedProcesses()
    exit(0)
}
termSource.setEventHandler(handler: shutdown)
intSource.setEventHandler(handler: shutdown)
termSource.resume()
intSource.resume()
app.run()
