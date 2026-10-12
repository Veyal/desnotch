import AppKit
import SwiftUI

/// Owns the app's windows: the notch panel (via `NotchWindowController`, whose hover
/// handling is deliberately untouched here) and the three ordinary windows - Settings,
/// Getting Started and Add Reminder. Each ordinary window is created lazily and dropped
/// when closed.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let composition: AppComposition
    private(set) var notchWindowController: NotchWindowController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var reminderCaptureWindow: NSWindow?
    private var screenRetryObserver: NSObjectProtocol?

    init(composition: AppComposition) {
        self.composition = composition
        super.init()
    }

    // MARK: - Notch panel

    /// Creates the notch panel. With no display attached at launch, retries once screens appear.
    func installNotchWindow() {
        if let controller = makeNotchWindowController() {
            notchWindowController = controller
            return
        }
        screenRetryObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue (`queue: .main`), which is the main actor's executor.
            MainActor.assumeIsolated {
                guard let self,
                      self.notchWindowController == nil,
                      let controller = self.makeNotchWindowController()
                else { return }
                self.notchWindowController = controller
                if let observer = self.screenRetryObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.screenRetryObserver = nil
                }
            }
        }
    }

    private func makeNotchWindowController() -> NotchWindowController? {
        composition.makeNotchWindowController(onAddReminder: { [weak self] in
            self?.openReminderCapture()
        })
    }

    // MARK: - Settings

    func openSettings() {
        if settingsWindow == nil {
            // Resizable vertically: the pane scrolls, and sizing it to the content's
            // full fitting height (what this used to do) grew the window taller than
            // the screen and left the bottom rows unreachable.
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "desnotch Settings"
            window.contentView = NSHostingView(rootView: SettingsView(
                notificationMirror: composition.notificationMirror,
                globalHotKey: composition.globalHotKey,
                onShowOnboarding: { [weak self] in self?.showOnboarding() },
                voice: composition.voiceModel
            ))
            window.isReleasedWhenClosed = false

            let width = SettingsView.contentWidth
            let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
            // Comfortably tall by default, but never taller than the screen it opens on.
            let height = min(620, available * 0.85)
            window.setContentSize(NSSize(width: width, height: height))
            // Width is fixed (the pane is a fixed-width column); height is the user's.
            window.contentMinSize = NSSize(width: width, height: 240)
            window.contentMaxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to desnotch"
            window.contentView = NSHostingView(rootView: OnboardingView(
                onOpenSettings: { [weak self] in
                    self?.finishOnboarding()
                    self?.openSettings()
                },
                onDone: { [weak self] in self?.finishOnboarding() }
            ))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 360, height: 560))
            window.center()
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shown once on first launch, after the status item and panel exist.
    func showOnboardingIfFirstRun() {
        guard !SettingsStore.shared.hasSeenOnboarding else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.showOnboarding() }
        }
    }

    private func finishOnboarding() {
        SettingsStore.shared.hasSeenOnboarding = true
        onboardingWindow?.close()
    }

    // MARK: - Reminder capture

    func openReminderCapture() {
        let reminders = composition.remindersController
        let access = reminders.accessState
        guard access == .granted else {
            if access == .denied { Self.openRemindersPrivacySettings() }
            return
        }
        if reminderCaptureWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Add Reminder"
            window.contentView = NSHostingView(rootView: ReminderCaptureView(
                onCancel: { [weak self] in self?.reminderCaptureWindow?.close() },
                onSave: { [weak self] title, dueDate, isAllDay in
                    guard let self else { return false }
                    let saved = self.composition.remindersController.add(
                        title: title,
                        dueDate: dueDate,
                        isAllDay: isAllDay
                    )
                    if saved {
                        self.composition.presentation.flashOpen(announcement: PillAnnouncements.reminderAdded, kind: .reminder)
                        self.reminderCaptureWindow?.close()
                    } else {
                        AccessibilityAnnouncer.announce(PillAnnouncements.reminderFailed)
                        NSSound.beep()
                    }
                    return saved
                }
            ))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 360, height: 235))
            window.center()
            reminderCaptureWindow = window
        }
        reminderCaptureWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func openRemindersPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            SettingsStore.shared.hasSeenOnboarding = true
            onboardingWindow = nil
        } else if window === reminderCaptureWindow {
            reminderCaptureWindow = nil
        }
    }
}
