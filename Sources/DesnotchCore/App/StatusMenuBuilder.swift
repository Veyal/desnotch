import AppKit

/// Owns the menu bar status item and builds its menu. The menu is the target of every
/// item it creates (see `StatusMenuBuilder+Actions.swift` for the handlers), and it is
/// also the `NSMenuDelegate` that rebuilds it on every open.
///
/// No dock icon by default (accessory activation policy). Because the borderless,
/// non-activating panel can never become the key window, the app menu's Cmd+Q is
/// unreachable from the keyboard for most users - so this status item provides a reliable
/// Quit and a launch-at-login toggle.
@MainActor
final class StatusMenuBuilder: NSObject, NSMenuDelegate {
    let composition: AppComposition
    let windows: WindowCoordinator
    private(set) var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    init(composition: AppComposition, windows: WindowCoordinator) {
        self.composition = composition
        self.windows = windows
        super.init()
    }

    /// Creates the status item and its (initially built) menu.
    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: "music.note",
            accessibilityDescription: "desnotch"
        )
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        statusMenu = menu
        rebuildMenu()
    }

    /// Rebuild the dynamic mirror right before the menu shows.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    /// Newer release found: badge the status icon and let the next menu open pick up
    /// the update item via the full rebuild.
    func showUpdateMenuItem(version: String) {
        rebuildMenu()
        // A visible badge, not a subtle glyph swap: orange dot beside the status icon.
        if let button = statusItem?.button {
            statusItem?.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeft
            button.attributedTitle = NSAttributedString(
                string: "●",
                attributes: [
                    .foregroundColor: NSColor.systemOrange,
                    .font: NSFont.systemFont(ofSize: 7),
                    .baselineOffset: 4
                ]
            )
            button.toolTip = "desnotch update available"
        }
    }

    /// The status menu is rebuilt on every open. It doubles as the keyboard/VoiceOver
    /// mirror of the pill's actions, because the pill's own panel is non-activating, never key and
    /// hover-driven (VoiceOver reaches it only through the cursor when pinned open). Rebuilding also keeps the checkbox
    /// states honest when settings change through the Settings window.
    private func rebuildMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        let privacy = SettingsStore.shared.privacyModeEnabled

        // Keyboard/VoiceOver route to the hover-driven pill: hold it open on demand.
        let showItem = NSMenuItem(
            title: "Show Notch",
            action: #selector(menuToggleShowNotch(_:)),
            keyEquivalent: ""
        )
        showItem.target = self
        showItem.state = windows.notchWindowController?.isPinnedOpen == true ? .on : .off
        if let hotKey = composition.globalHotKey, hotKey.status == .active {
            showItem.keyEquivalent = hotKey.binding.keyLabel.lowercased()
            showItem.keyEquivalentModifierMask = hotKey.binding.menuModifierMask
        }
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())

        if let version = composition.updateChecker?.availableVersion {
            let item = NSMenuItem(
                title: "Update Available (\(version))…",
                action: #selector(openReleasesPage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        if let info = composition.nowPlayingController.info, info.hasContent {
            // Header (action-less items auto-disable; they read as section labels).
            menu.addItem(NSMenuItem(
                title: privacy ? "Now Playing" : String((info.title ?? "Now Playing").prefix(40)),
                action: nil, keyEquivalent: ""
            ))
            let toggle = NSMenuItem(
                title: info.isPlaying ? "Pause" : "Play",
                action: #selector(menuTogglePlayPause(_:)), keyEquivalent: ""
            )
            toggle.target = self
            menu.addItem(toggle)
            let next = NSMenuItem(
                title: "Next Track", action: #selector(menuNextTrack(_:)), keyEquivalent: ""
            )
            next.target = self
            menu.addItem(next)
            let previous = NSMenuItem(
                title: "Previous Track", action: #selector(menuPreviousTrack(_:)), keyEquivalent: ""
            )
            previous.target = self
            menu.addItem(previous)
            menu.addItem(NSMenuItem.separator())
        }

        let timerItem = NSMenuItem(title: "Focus Timer", action: nil, keyEquivalent: "")
        timerItem.submenu = makeFocusTimerSubmenu()
        menu.addItem(timerItem)
        menu.addItem(NSMenuItem.separator())

        let sessions = composition.agentActivityController.sessions
        if !sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "Agents", action: nil, keyEquivalent: ""))
            for session in sessions.prefix(6) {
                let name = privacy ? session.projectLabel : (session.taskTitle ?? session.projectLabel)
                let item = NSMenuItem(
                    title: "\(String(name.prefix(40))) — \(Self.menuStateLabel(session.state)) · \(Self.menuFreshness(session.lastActivity))",
                    action: #selector(menuJumpToAgent(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.projectPath
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        if SettingsStore.shared.calendarEnabled,
           let event = composition.calendarController.nextEvent,
           let joinURL = event.joinURL {
            let name = privacy ? "Meeting" : String(event.title.prefix(40))
            let item = NSMenuItem(
                title: "Join \(name)",
                action: #selector(menuJoinMeeting(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = joinURL
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        if SettingsStore.shared.remindersEnabled {
            let reminders = composition.remindersController
            let remindersItem = NSMenuItem(title: "Reminders", action: nil, keyEquivalent: "")
            let remindersMenu = NSMenu()

            if let reminder = reminders.nextReminder {
                let title = privacy ? "Reminder" : String(reminder.title.prefix(48))
                remindersMenu.addItem(NSMenuItem(
                    title: "\(title) — \(RemindersController.dueLabel(reminder))",
                    action: nil,
                    keyEquivalent: ""
                ))
                let complete = NSMenuItem(
                    title: "Mark Complete",
                    action: #selector(menuCompleteReminder(_:)),
                    keyEquivalent: ""
                )
                complete.target = self
                complete.representedObject = reminder.id
                remindersMenu.addItem(complete)
                remindersMenu.addItem(NSMenuItem.separator())
            } else if reminders.accessState == .denied {
                let permission = NSMenuItem(
                    title: "Reminders Access Needed…",
                    action: #selector(openRemindersPrivacy(_:)),
                    keyEquivalent: ""
                )
                permission.target = self
                remindersMenu.addItem(permission)
                remindersMenu.addItem(NSMenuItem.separator())
            }

            let add = NSMenuItem(
                title: "Add Reminder…",
                action: #selector(openReminderCapture(_:)),
                keyEquivalent: ""
            )
            add.target = self
            add.isEnabled = reminders.accessState == .granted
            remindersMenu.addItem(add)
            remindersItem.submenu = remindersMenu
            menu.addItem(remindersItem)
            menu.addItem(NSMenuItem.separator())
        }

        let trayItems = composition.trayController.items
        if !trayItems.isEmpty {
            let submenu = NSMenu()
            for url in trayItems {
                let name = privacy
                    ? (url.pathExtension.isEmpty ? "file" : "file.\(url.pathExtension)")
                    : url.lastPathComponent
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.submenu = makeTrayItemSubmenu(url: url)
                submenu.addItem(item)
            }
            let trayItem = NSMenuItem(title: "Tray", action: nil, keyEquivalent: "")
            trayItem.submenu = submenu
            menu.addItem(trayItem)
            menu.addItem(NSMenuItem.separator())
        }

        let clipboardEntries = composition.clipboardController.entries
        if SettingsStore.shared.clipboardHistoryEnabled, !clipboardEntries.isEmpty {
            let clipboardItem = NSMenuItem(title: "Clipboard", action: nil, keyEquivalent: "")
            clipboardItem.submenu = Self.makeClipboardSubmenu(
                entries: clipboardEntries,
                privacy: privacy,
                target: self
            )
            menu.addItem(clipboardItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Accessibility mirror for the notification row (the panel is never key, so
        // the menu is the keyboard path): jump to the source app, or mute it. App name only -
        // banner content stays out of the menu (it outlives the 60s pill row).
        if SettingsStore.shared.notificationMirrorEnabled,
           let banner = composition.notificationMirror.latest {
            let openItem = NSMenuItem(
                title: "Open \(banner.appName) notification",
                action: #selector(menuOpenNotificationSource(_:)),
                keyEquivalent: ""
            )
            openItem.target = self
            openItem.representedObject = banner.appName
            menu.addItem(openItem)
            let muteItem = NSMenuItem(
                title: "Mute notifications from \(banner.appName)",
                action: #selector(menuMuteNotificationApp(_:)),
                keyEquivalent: ""
            )
            muteItem.target = self
            muteItem.representedObject = banner.appName
            menu.addItem(muteItem)
            menu.addItem(NSMenuItem.separator())
        }

        let hot = composition.processMonitorController.hotProcesses
        if SettingsStore.shared.processMonitorEnabled, !hot.isEmpty {
            menu.addItem(NSMenuItem(title: "High CPU", action: nil, keyEquivalent: ""))
            for process in hot.prefix(5) {
                menu.addItem(NSMenuItem(
                    title: StatusMenuText.hotProcess(process),
                    action: nil,
                    keyEquivalent: ""
                ))
            }
            menu.addItem(NSMenuItem.separator())
        }

        if SettingsStore.shared.batteryEnabled, let state = composition.batteryController.state {
            menu.addItem(NSMenuItem(
                title: StatusMenuText.battery(state),
                action: nil,
                keyEquivalent: ""
            ))
            menu.addItem(NSMenuItem.separator())
        }

        let privacyItem = NSMenuItem(
            title: "Privacy Mode",
            action: #selector(togglePrivacyMode(_:)),
            keyEquivalent: ""
        )
        privacyItem.target = self
        privacyItem.state = privacy ? .on : .off
        menu.addItem(privacyItem)

        let displayAwakeItem = NSMenuItem(
            title: "Keep Display Awake",
            action: #selector(toggleDisplayAwake(_:)),
            keyEquivalent: ""
        )
        displayAwakeItem.target = self
        displayAwakeItem.state = composition.displayAwakeController.isDisplayAwake ? .on : .off
        menu.addItem(displayAwakeItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diagnosticsItem = NSMenuItem(
            title: "Copy Display Diagnostics",
            action: #selector(menuCopyDisplayDiagnostics(_:)),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        let onboardingItem = NSMenuItem(
            title: "Getting Started…",
            action: #selector(openGettingStarted(_:)),
            keyEquivalent: ""
        )
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = Self.menuState(for: LaunchAtLogin.state)
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit desnotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    /// `target` receives the per-entry Copy/Remove/Clear actions (the builder in production).
    static func makeClipboardSubmenu(entries: [ClipboardEntry], privacy: Bool, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        for (index, entry) in entries.enumerated() {
            let entryItem = NSMenuItem(
                title: privacy ? "Clipboard item \(index + 1)" : entry.preview,
                action: nil,
                keyEquivalent: ""
            )
            let actions = NSMenu()
            let copy = NSMenuItem(
                title: "Copy",
                action: #selector(StatusMenuBuilder.menuCopyClipboardEntry(_:)),
                keyEquivalent: ""
            )
            copy.target = target
            copy.representedObject = entry.id.uuidString
            actions.addItem(copy)

            let remove = NSMenuItem(
                title: "Remove from Clipboard History",
                action: #selector(StatusMenuBuilder.menuRemoveClipboardEntry(_:)),
                keyEquivalent: ""
            )
            remove.target = target
            remove.representedObject = entry.id.uuidString
            actions.addItem(remove)
            entryItem.submenu = actions
            menu.addItem(entryItem)
        }
        menu.addItem(NSMenuItem.separator())
        let clear = NSMenuItem(
            title: "Clear Clipboard History",
            action: #selector(StatusMenuBuilder.menuClearClipboardHistory(_:)),
            keyEquivalent: ""
        )
        clear.target = target
        menu.addItem(clear)
        return menu
    }

    private func makeTrayItemSubmenu(url: URL) -> NSMenu {
        let menu = NSMenu()
        let actions: [(String, Selector)] = [
            ("Open", #selector(menuOpenTrayItem(_:))),
            ("Reveal in Finder", #selector(menuRevealTrayItem(_:))),
            ("Copy File", #selector(menuCopyTrayItem(_:))),
            ("Share…", #selector(menuShareTrayItem(_:)))
        ]
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let remove = NSMenuItem(
            title: "Remove from Tray",
            action: #selector(menuRemoveTrayItem(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        remove.representedObject = url
        menu.addItem(remove)
        return menu
    }

    private func makeFocusTimerSubmenu() -> NSMenu {
        let menu = NSMenu()
        let timer = composition.focusTimerController
        switch timer.state {
        case .running, .paused:
            let suffix = timer.state == .paused ? " (Paused)" : ""
            menu.addItem(NSMenuItem(
                title: "\(TimeFormatting.clock(ceil(timer.remaining))) remaining\(suffix)",
                action: nil,
                keyEquivalent: ""
            ))
            let toggle = NSMenuItem(
                title: timer.state == .paused ? "Resume" : "Pause",
                action: #selector(menuToggleFocusTimer(_:)),
                keyEquivalent: ""
            )
            toggle.target = self
            menu.addItem(toggle)
            let cancel = NSMenuItem(
                title: "Cancel Timer",
                action: #selector(menuCancelFocusTimer(_:)),
                keyEquivalent: ""
            )
            cancel.target = self
            menu.addItem(cancel)
            menu.addItem(NSMenuItem.separator())
        case .completed:
            menu.addItem(NSMenuItem(
                title: "Focus complete",
                action: nil,
                keyEquivalent: ""
            ))
            let dismiss = NSMenuItem(
                title: "Dismiss",
                action: #selector(menuCancelFocusTimer(_:)),
                keyEquivalent: ""
            )
            dismiss.target = self
            menu.addItem(dismiss)
            menu.addItem(NSMenuItem.separator())
        case .idle:
            break
        }

        for minutes in [5, 15, 25, 50] {
            let item = NSMenuItem(
                title: "Start \(minutes)-Minute Timer",
                action: #selector(menuStartFocusTimer(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: minutes * 60)
            menu.addItem(item)
        }
        return menu
    }

    private static func menuStateLabel(_ state: AgentActivityState) -> String {
        state.presentationLabel
    }

    private static func menuFreshness(_ date: Date) -> String {
        AgentActivityPresentation.freshness(for: date)
    }

    /// A login item awaiting approval shows as mixed: registered, but not yet launching.
    static func menuState(for state: LaunchAtLogin.State) -> NSControl.StateValue {
        switch state {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        case .disabled, .unavailable: return .off
        }
    }
}
