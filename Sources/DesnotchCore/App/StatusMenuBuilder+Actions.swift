import AppKit

/// Status menu action handlers. Every selector here is wired as an item's target/action by
/// `StatusMenuBuilder`; keep the method names in sync with its `#selector` references.
extension StatusMenuBuilder {
    @objc func menuToggleShowNotch(_ sender: NSMenuItem) {
        windows.notchWindowController?.togglePinnedOpen()
    }

    @objc func menuCopyDisplayDiagnostics(_ sender: NSMenuItem) {
        guard let report = windows.notchWindowController?.displayDiagnostics() else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        AccessibilityAnnouncer.announce("Display diagnostics copied")
    }

    @objc func menuTogglePlayPause(_ sender: NSMenuItem) {
        composition.nowPlayingController.togglePlayPause()
    }

    @objc func menuNextTrack(_ sender: NSMenuItem) {
        composition.nowPlayingController.next()
    }

    @objc func menuPreviousTrack(_ sender: NSMenuItem) {
        composition.nowPlayingController.previous()
    }

    @objc func menuStartFocusTimer(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        if composition.focusTimerController.start(duration: seconds) {
            composition.presentation.flashOpen(announcement: PillAnnouncements.timerStarted, kind: .timerStarted)
        }
    }

    @objc func menuToggleFocusTimer(_ sender: NSMenuItem) {
        let timer = composition.focusTimerController
        switch timer.state {
        case .running: timer.pause()
        case .paused: timer.resume()
        default: break
        }
    }

    @objc func menuCancelFocusTimer(_ sender: NSMenuItem) {
        composition.focusTimerController.cancel()
    }

    @objc func menuJumpToAgent(_ sender: NSMenuItem) {
        AppActivation.activateAgentHost(projectPath: sender.representedObject as? String)
    }

    @objc func menuOpenTrayItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = composition.trayController.open(url)
    }

    @objc func menuRevealTrayItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = composition.trayController.revealInFinder(url)
    }

    @objc func menuCopyTrayItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = composition.trayController.copyToPasteboard([url])
    }

    @objc func menuShareTrayItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              composition.trayController.items.contains(url),
              FileManager.default.fileExists(atPath: url.path),
              let anchor = statusItem?.button
        else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc func menuRemoveTrayItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        composition.trayController.remove(url)
    }

    @objc func menuJoinMeeting(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func menuCompleteReminder(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        if composition.remindersController.complete(identifier) {
            composition.presentation.flashOpen(announcement: PillAnnouncements.reminderCompleted, kind: .reminder)
        } else {
            AccessibilityAnnouncer.announce(PillAnnouncements.reminderFailed)
            NSSound.beep()
        }
    }

    @objc func menuOpenNotificationSource(_ sender: NSMenuItem) {
        guard let appName = sender.representedObject as? String else { return }
        composition.notificationMirror.activateSource(appName: appName)
    }

    @objc func menuMuteNotificationApp(_ sender: NSMenuItem) {
        guard let appName = sender.representedObject as? String else { return }
        composition.notificationMirror.muteApp(appName)
    }

    @objc func menuCopyClipboardEntry(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        composition.clipboardController.copy(id)
    }

    @objc func menuRemoveClipboardEntry(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        composition.clipboardController.remove(id)
    }

    @objc func menuClearClipboardHistory(_ sender: NSMenuItem) {
        composition.clipboardController.clear()
    }

    @objc func openReleasesPage(_ sender: NSMenuItem) {
        if let url = URL(string: "https://github.com/Veyal/desnotch/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openRemindersPrivacy(_ sender: Any?) {
        WindowCoordinator.openRemindersPrivacySettings()
    }

    @objc func togglePrivacyMode(_ sender: NSMenuItem) {
        SettingsStore.shared.privacyModeEnabled.toggle()
        sender.state = SettingsStore.shared.privacyModeEnabled ? .on : .off
    }

    @objc func toggleDisplayAwake(_ sender: NSMenuItem) {
        let awake = composition.displayAwakeController
        awake.toggle()
        sender.state = awake.isDisplayAwake ? .on : .off
    }

    @objc func openSettings(_ sender: Any?) {
        windows.openSettings()
    }

    @objc func openGettingStarted(_ sender: Any?) {
        windows.showOnboarding()
    }

    @objc func openReminderCapture(_ sender: Any?) {
        windows.openReminderCapture()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            let state = try LaunchAtLogin.toggle()
            sender.state = Self.menuState(for: state)
            if state == .requiresApproval { LaunchAtLogin.openLoginItemsSettings() }
        } catch {
            // Non-fatal: login registration can fail for ad-hoc-signed builds; the rest of
            // the app is unaffected.
            NSLog("Launch-at-login toggle failed: \(error.localizedDescription)")
            sender.state = Self.menuState(for: LaunchAtLogin.state)
        }
    }
}
