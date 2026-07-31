import AppKit
import ServiceManagement
import SwiftUI

/// No dock icon by default (accessory activation policy). Because the borderless,
/// non-activating panel can never become the key window, the app menu's Cmd+Q is
/// unreachable from the keyboard for most users - so a menu bar status item provides
/// a reliable Quit and a launch-at-login toggle, and `main.swift` handles
/// SIGTERM/SIGINT so `pkill` cleans up the perl adapter subprocess instead of orphaning it.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentation: NotchPillPresentation?
    private var nowPlayingController: NowPlayingController?
    private var agentActivityController: AgentActivityController?
    private var calendarController: CalendarController?
    private var processMonitorController: ProcessMonitorController?
    private var trayController: TrayController?
    private var batteryController: BatteryController?
    private var mediaUseMonitor: MediaUseMonitor?
    private var notificationMirror: NotificationMirrorController?
    private var updateChecker: UpdateChecker?
    private var windowController: NotchWindowController?
    private var settingsWindow: NSWindow?
    private var statusMenu: NSMenu?
    private var statusItem: NSStatusItem?
    private var retryObserver: NSObjectProtocol?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another desnotch is already running, bow out.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        if running.contains(where: { $0 != NSRunningApplication.current }) {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusItem()

        // Ask for notification permission now, not at the first needs-you event - a
        // lazy request drops the very notification that triggered it.
        AgentAttentionNotifier.shared.requestAuthorizationAtLaunch()

        let presentation = NotchPillPresentation()
        self.presentation = presentation
        let nowPlayingController = NowPlayingController(presentation: presentation)
        let agentActivityController = AgentActivityController(presentation: presentation)
        let calendarController = MainActor.assumeIsolated { CalendarController() }
        let processMonitorController = MainActor.assumeIsolated { ProcessMonitorController() }
        let trayController = MainActor.assumeIsolated { TrayController() }
        let batteryController = MainActor.assumeIsolated { BatteryController(presentation: presentation) }
        let mediaUseMonitor = MainActor.assumeIsolated { MediaUseMonitor() }
        let notificationMirror = MainActor.assumeIsolated {
            NotificationMirrorController(presentation: presentation, settings: .shared)
        }
        self.nowPlayingController = nowPlayingController
        self.agentActivityController = agentActivityController
        self.calendarController = calendarController
        self.processMonitorController = processMonitorController
        self.trayController = trayController
        self.batteryController = batteryController
        self.mediaUseMonitor = mediaUseMonitor
        self.notificationMirror = notificationMirror

        MainActor.assumeIsolated {
            let checker = UpdateChecker()
            checker.onUpdateAvailable = { [weak self] version in
                self?.showUpdateMenuItem(version: version)
            }
            self.updateChecker = checker
        }

        if let windowController = NotchWindowController(
            controller: nowPlayingController,
            agentActivity: agentActivityController,
            calendar: calendarController,
            processMonitor: processMonitorController,
            tray: trayController,
            battery: batteryController,
            mediaUse: mediaUseMonitor,
            notificationMirror: notificationMirror,
            presentation: presentation
        ) {
            self.windowController = windowController
        } else {
            // No display attached at launch: retry once screens appear.
            retryObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self,
                      self.windowController == nil,
                      let presentation = self.presentation,
                      let npc = self.nowPlayingController,
                      let aac = self.agentActivityController,
                      let cal = self.calendarController,
                      let pmc = self.processMonitorController,
                      let trayC = self.trayController,
                      let bat = self.batteryController,
                      let muse = self.mediaUseMonitor,
                      let mirror = self.notificationMirror,
                      let wc = NotchWindowController(
                          controller: npc,
                          agentActivity: aac,
                          calendar: cal,
                          processMonitor: pmc,
                          tray: trayC,
                          battery: bat,
                          mediaUse: muse,
                          notificationMirror: mirror,
                          presentation: presentation
                      )
                else { return }
                self.windowController = wc
                if let obs = self.retryObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.retryObserver = nil
                }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        MediaRemoteBridge.shared.stopStreaming()
    }

    private func configureStatusItem() {
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

    /// The status menu is rebuilt on every open. It doubles as the keyboard/VoiceOver
    /// mirror of the pill: media transport, jump-to-agent, and tray items are all
    /// reachable here, because the pill's own panel is non-activating and hover-driven -
    /// assistive tech cannot focus it. Rebuilding also keeps the checkbox states honest
    /// when settings change through the Settings window.
    private func rebuildMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        MainActor.assumeIsolated {
            let privacy = SettingsStore.shared.privacyModeEnabled

            if let version = updateChecker?.availableVersion {
                let item = NSMenuItem(
                    title: "Update Available (\(version))…",
                    action: #selector(openReleasesPage(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
                menu.addItem(NSMenuItem.separator())
            }

            if let info = nowPlayingController?.info, info.hasContent {
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

            if let sessions = agentActivityController?.sessions, !sessions.isEmpty {
                menu.addItem(NSMenuItem(title: "Agents", action: nil, keyEquivalent: ""))
                for session in sessions.prefix(6) {
                    let name = privacy ? session.projectLabel : (session.taskTitle ?? session.projectLabel)
                    let item = NSMenuItem(
                        title: "\(String(name.prefix(40))) — \(Self.menuStateLabel(session.state))",
                        action: #selector(menuJumpToAgent(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = session.projectPath
                    menu.addItem(item)
                }
                menu.addItem(NSMenuItem.separator())
            }

            if let trayItems = trayController?.items, !trayItems.isEmpty {
                let submenu = NSMenu()
                for url in trayItems {
                    let name = privacy
                        ? (url.pathExtension.isEmpty ? "file" : "file.\(url.pathExtension)")
                        : url.lastPathComponent
                    let item = NSMenuItem(
                        title: name, action: #selector(menuOpenTrayItem(_:)), keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = url
                    submenu.addItem(item)
                }
                let trayItem = NSMenuItem(title: "Tray", action: nil, keyEquivalent: "")
                trayItem.submenu = submenu
                menu.addItem(trayItem)
                menu.addItem(NSMenuItem.separator())
            }

            // Accessibility mirror for the notification row (the panel is unreachable
            // by assistive tech): jump to the source app, or mute it. App name only -
            // banner content stays out of the menu (it outlives the 60s pill row).
            if MainActor.assumeIsolated({ SettingsStore.shared.notificationMirrorEnabled }),
               let banner = MainActor.assumeIsolated({ notificationMirror?.latest }) {
                let openItem = NSMenuItem(
                    title: "Open \(banner.appName) notification",
                    action: #selector(menuOpenNotificationSource(_:)),
                    keyEquivalent: ""
                )
                openItem.target = self
                menu.addItem(openItem)
                let muteItem = NSMenuItem(
                    title: "Mute notifications from \(banner.appName)",
                    action: #selector(menuMuteNotificationApp(_:)),
                    keyEquivalent: ""
                )
                muteItem.target = self
                menu.addItem(muteItem)
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
        }

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit desnotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    @objc func menuOpenNotificationSource(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { notificationMirror?.activateSource() }
    }

    @objc func menuMuteNotificationApp(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { notificationMirror?.muteLatestApp() }
    }

    private static func menuStateLabel(_ state: AgentActivityState) -> String {
        switch state {
        case .working: return "working"
        case .needsYourTurn: return "needs you"
        case .stalled: return "stalled"
        case .idle: return "idle"
        }
    }

    /// Newer release found: badge the status icon and let the next menu open pick up
    /// the update item via the full rebuild.
    private func showUpdateMenuItem(version: String) {
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

    @objc func menuTogglePlayPause(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { nowPlayingController?.togglePlayPause() }
    }

    @objc func menuNextTrack(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { nowPlayingController?.next() }
    }

    @objc func menuPreviousTrack(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { nowPlayingController?.previous() }
    }

    @objc func menuJumpToAgent(_ sender: NSMenuItem) {
        AppActivation.activateAgentHost(projectPath: sender.representedObject as? String)
    }

    @objc func menuOpenTrayItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openReleasesPage(_ sender: NSMenuItem) {
        if let url = URL(string: "https://github.com/Veyal/desnotch/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func togglePrivacyMode(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            SettingsStore.shared.privacyModeEnabled.toggle()
            sender.state = SettingsStore.shared.privacyModeEnabled ? .on : .off
        }
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc func openSettings(_ sender: NSMenuItem) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "desnotch Settings"
            window.contentView = MainActor.assumeIsolated {
                NSHostingView(rootView: SettingsView(notificationMirror: notificationMirror))
            }
            window.isReleasedWhenClosed = false
            window.setContentSize(window.contentView?.fittingSize ?? .zero)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            sender.state = launchAtLoginEnabled ? .on : .off
        } catch {
            // Non-fatal: login registration can fail for ad-hoc-signed builds; the rest of
            // the app is unaffected.
            NSLog("Launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }

    private static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.desnotch.app"
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuild the dynamic mirror right before the menu shows.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
