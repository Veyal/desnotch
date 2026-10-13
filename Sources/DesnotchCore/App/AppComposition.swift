import AppKit

/// Owns every long-lived controller and the wiring between them. `AppDelegate` builds one
/// at launch and hands it to the window coordinator and the status menu, so neither has to
/// know how a controller is constructed - only that it exists.
@MainActor
final class AppComposition {
    let presentation: NotchPillPresentation
    let nowPlayingController: NowPlayingController
    let focusTimerController: FocusTimerController
    let agentActivityController: AgentActivityController
    let calendarController: CalendarController
    let remindersController: RemindersController
    let processMonitorController: ProcessMonitorController
    let displayAwakeController: DisplayAwakeController
    let clipboardController: ClipboardController
    let trayController: TrayController
    let batteryController: BatteryController
    let mediaUseMonitor: MediaUseMonitor
    let notificationMirror: NotificationMirrorController
    /// Presentation state for voice control. Always exists (it is inert data); the voice
    /// coordinator that drives it is wired by WP-HERMES and stays off unless `voiceEnabled`.
    let voiceModel = VoiceSessionModel()

    /// Nil in smoke-test mode. Drives `voiceModel`; registering keys or audio happens
    /// only after voice is enabled.
    private(set) var voiceCoordinator: VoiceCoordinator?
    /// Nil in smoke-test mode. Constructing it spawns nothing; `stopOwnedResources` terminates it.
    private var hermesBackend: HermesAgentBackend?
    /// Nil in smoke-test mode (never polls GitHub there).
    private(set) var updateChecker: UpdateChecker?
    /// Nil in smoke-test mode (must not take a key combination from the developer's apps).
    private(set) var globalHotKey: GlobalHotKeyController?

    /// Smoke runs skip permission prompts and the optional launch-time services.
    let smokeTestMode: Bool

    init(smokeTestMode: Bool) {
        self.smokeTestMode = smokeTestMode
        let presentation = NotchPillPresentation()
        self.presentation = presentation
        nowPlayingController = NowPlayingController(presentation: presentation)
        let focusTimerController = FocusTimerController()
        focusTimerController.onCompletion = { _ in
            presentation.flashOpen(kind: .timerComplete)
            AccessibilityAnnouncer.announce(PillAnnouncements.timerCompleted, priority: .high)
            if NSSound(named: NSSound.Name("Glass"))?.play() != true {
                NSSound.beep()
            }
        }
        self.focusTimerController = focusTimerController
        agentActivityController = AgentActivityController(presentation: presentation)
        calendarController = CalendarController(permissionRequestsEnabled: !smokeTestMode)
        remindersController = RemindersController(permissionRequestsEnabled: !smokeTestMode)
        processMonitorController = ProcessMonitorController()
        displayAwakeController = DisplayAwakeController()
        clipboardController = ClipboardController()
        trayController = TrayController()
        batteryController = BatteryController(presentation: presentation)
        mediaUseMonitor = MediaUseMonitor()
        notificationMirror = NotificationMirrorController(presentation: presentation, settings: .shared)
        if !smokeTestMode {
            let backend = HermesAgentBackend()
            hermesBackend = backend
            let systemVoice = AppleSpeechSynthesizer()
            voiceCoordinator = VoiceCoordinator(
                model: voiceModel,
                settings: SettingsStore.shared,
                clock: SystemVoiceClock(),
                recognizer: AppleSpeechRecognizer(),
                synthesizer: systemVoice,
                executor: SystemLocalExecutor(
                    nowPlaying: nowPlayingController,
                    focusTimer: focusTimerController
                ),
                backend: backend,
                terminateAgentNow: { [backend] in backend.terminateNow() },
                audit: FileAuditLogger(
                    directory: FileAuditLogger.defaultDirectory(),
                    writer: DiskFileWriter(),
                    clock: SystemVoiceClock()
                ),
                makeKeys: { CarbonPushToTalk(choice: $0) },
                lock: ScreenLockMonitor(),
                ducker: VolumeDucker(),
                permissions: SystemVoicePermissions(),
                cues: VoiceCuePlayer(),
                timers: RunLoopTimerScheduler(),
                dailyTurns: DailyTurnCounter(defaults: .standard),
                isPrivacyMode: { SettingsStore.shared.privacyModeEnabled },
                // Built always, used only for the functions the user switched to a provider.
                // Constructing it opens nothing and sends nothing.
                ai: VoiceAIProviders.live(fallbackSynthesizer: systemVoice),
                debugTypingEnabled: ProcessInfo.processInfo.environment["DESNOTCH_VOICE_DEBUG"] == "1"
            )
            voiceCoordinator?.start()
        }
    }

    /// Daily release poll; `onUpdateAvailable` runs on the main actor. No-op in smoke mode.
    func installUpdateChecker(onUpdateAvailable: @escaping (String) -> Void) {
        guard !smokeTestMode else { return }
        let checker = UpdateChecker()
        checker.onUpdateAvailable = onUpdateAvailable
        updateChecker = checker
    }

    /// Global show-notch shortcut. No-op in smoke mode.
    func installGlobalHotKey(onTrigger: @escaping () -> Void) {
        guard !smokeTestMode else { return }
        globalHotKey = GlobalHotKeyController(onTrigger: onTrigger)
    }

    /// Builds the panel controller, or nil when no display is attached yet.
    func makeNotchWindowController(onAddReminder: @escaping () -> Void) -> NotchWindowController? {
        NotchWindowController(
            controller: nowPlayingController,
            focusTimer: focusTimerController,
            agentActivity: agentActivityController,
            calendar: calendarController,
            reminders: remindersController,
            onAddReminder: onAddReminder,
            processMonitor: processMonitorController,
            clipboard: clipboardController,
            tray: trayController,
            battery: batteryController,
            mediaUse: mediaUseMonitor,
            notificationMirror: notificationMirror,
            voice: voiceModel,
            presentation: presentation
        )
    }

    /// Releases the resources that must not outlive the app (hot key registration and the
    /// display-awake assertion). The MediaRemote adapter is stopped by `AppDelegate`.
    func stopOwnedResources() {
        globalHotKey?.stop()
        displayAwakeController.stop()
        voiceCoordinator?.stop()
        hermesBackend?.terminateNow()
    }
}
