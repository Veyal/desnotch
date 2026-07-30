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

        let presentation = NotchPillPresentation()
        self.presentation = presentation
        let nowPlayingController = NowPlayingController(presentation: presentation)
        let agentActivityController = AgentActivityController(presentation: presentation)
        let calendarController = MainActor.assumeIsolated { CalendarController() }
        let processMonitorController = MainActor.assumeIsolated { ProcessMonitorController() }
        let trayController = MainActor.assumeIsolated { TrayController() }
        let batteryController = MainActor.assumeIsolated { BatteryController(presentation: presentation) }
        let mediaUseMonitor = MainActor.assumeIsolated { MediaUseMonitor() }
        self.nowPlayingController = nowPlayingController
        self.agentActivityController = agentActivityController
        self.calendarController = calendarController
        self.processMonitorController = processMonitorController
        self.trayController = trayController
        self.batteryController = batteryController
        self.mediaUseMonitor = mediaUseMonitor

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
                      let wc = NotchWindowController(
                          controller: npc,
                          agentActivity: aac,
                          calendar: cal,
                          processMonitor: pmc,
                          tray: trayC,
                          battery: bat,
                          mediaUse: muse,
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

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        let privacyItem = NSMenuItem(
            title: "Privacy Mode",
            action: #selector(togglePrivacyMode(_:)),
            keyEquivalent: ""
        )
        privacyItem.target = self
        privacyItem.state = MainActor.assumeIsolated { SettingsStore.shared.privacyModeEnabled } ? .on : .off
        menu.addItem(privacyItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit desnotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
        statusItem?.menu = menu
        statusMenu = menu
    }

    /// Inserted at the top of the status menu when a newer GitHub release exists.
    private func showUpdateMenuItem(version: String) {
        guard let menu = statusMenu else { return }
        guard !menu.items.contains(where: { $0.tag == Self.updateItemTag }) else {
            menu.items.first { $0.tag == Self.updateItemTag }?.title = "Update Available (\(version))…"
            return
        }
        let item = NSMenuItem(
            title: "Update Available (\(version))…",
            action: #selector(openReleasesPage(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = Self.updateItemTag
        menu.insertItem(item, at: 0)
        menu.insertItem(NSMenuItem.separator(), at: 1)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "music.note.list",
            accessibilityDescription: "desnotch (update available)"
        )
    }

    private static let updateItemTag = 0xDE5

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
            window.contentView = MainActor.assumeIsolated { NSHostingView(rootView: SettingsView()) }
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
