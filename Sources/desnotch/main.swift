import AppKit
import DesnotchCore

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
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let shutdown = {
    MediaRemoteBridge.shared.stopStreaming()
    exit(0)
}
termSource.setEventHandler(handler: shutdown)
intSource.setEventHandler(handler: shutdown)
termSource.resume()
intSource.resume()

let delegate = AppDelegate()
app.delegate = delegate
app.run()
