import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Minimal app menu so Cmd+Q quits the app. There is no dock icon or menu bar item
// (accessory activation policy), so this is the one bit of "settings UI" the spec
// allows: just enough to quit.
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

let delegate = AppDelegate()
app.delegate = delegate
app.run()
