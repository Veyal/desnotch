import Foundation

/// How the pill behaves when the pointer isn't over it.
public enum PillVisibilityMode: String, CaseIterable {
    /// Minimized by default; hover expands, leaving collapses after `hoverCollapseDelay`.
    case hoverAuto
    /// Never minimizes - the expanded pill is always on screen.
    case alwaysOn
}

/// How much motion the pill uses. Governs the shared curves, arrival transitions,
/// and whether continuously looping motion is permitted at all.
public enum AnimationStyle: String, CaseIterable {
    /// Restrained spring on meaningful events, short opacity crossfades (default).
    case subtle
    /// Looser, bouncier spring with a little more travel and scale on arrivals.
    case dynamic
    /// Near-instant opacity only; matches what Reduce Motion forces system-wide.
    case minimal
}

/// Which indicator the minimized wing shows for now-playing media.
public enum MusicIndicatorStyle: String, CaseIterable {
    /// Animated equalizer bars while playing, static note while paused.
    case equalizer
    /// Always the static music note (default).
    case note
    /// The current track's album artwork; falls back to equalizer/note behavior when
    /// a track has no artwork, and is suppressed entirely by privacy mode (artwork
    /// identifies the track on a permanently visible, screen-shared surface).
    case albumArt
}

/// Which key combination is push-to-talk for voice control. Every choice is Option-Command based:
/// Control+Option is avoided on purpose (it is VoiceOver's modifier). The Carbon key codes live
/// with `CarbonPushToTalk` (Voice/Platform); this enum is only the stored choice.
public enum VoiceHotkeyChoice: String, CaseIterable {
    case optionCommandV
    case shiftOptionCommandV
    case optionCommandJ
}

/// Who turns speech into text. On-device is the default; the OpenAI-compatible provider is an
/// explicit opt-in that sends the captured audio to the configured endpoint.
public enum VoiceSpeechProvider: String, CaseIterable {
    case onDevice
    case openAICompatible
}

/// Who answers requests that are not built-in commands, once the agent lane
/// (`voiceHermesLane`) is on. Hermes is the default so the existing lane is unchanged.
/// Anthropic answers only: it has no speech API, so speech-to-text and spoken replies stay
/// on-device/macOS or OpenAI-compatible.
public enum VoiceAnswersProvider: String, CaseIterable {
    case hermes
    case openAICompatible
    case anthropic
}

/// Which voice speaks replies when "Speak replies" is on. The macOS voice is the default.
public enum VoiceReplyProvider: String, CaseIterable {
    case system
    case openAICompatible
}

/// User-toggleable feature switches and pill-behavior knobs, UserDefaults-backed.
/// The pill view gates its sections on these; pollers (process monitor, calendar,
/// agent scanner) also check them so disabled features stop doing background work.
/// Notification toggles (`notifyAgentNeedsYou`, `notifyStuckProcess`) are read by their
/// callers, which gate `AgentAttentionNotifier`; the notifier itself holds no settings.
///
/// Numeric knobs are clamped to their published ranges on read AND on write, so a
/// stale/hand-edited defaults value can never produce a degenerate layout.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore(defaults: .standard)

    // MARK: Bounds (public so the UI and tests share one source of truth)

    /// Collapse grace after the pointer leaves the pill.
    public static let hoverCollapseDelayRange: ClosedRange<Double> = 0.1...5.0
    public static let defaultHoverCollapseDelay = 0.4

    /// Minimized (fake-notch) cutout size on notch-less screens. On a real notch the
    /// hardware dictates the minimized size, so these only affect notch-less displays.
    public static let minimizedWidthRange: ClosedRange<Double> = 120...400
    public static let defaultMinimizedWidth = 200.0
    public static let minimizedHeightRange: ClosedRange<Double> = 24...44
    public static let defaultMinimizedHeight = 30.0

    /// Preferred expanded pill width (the shape still never shrinks below cutout+wings).
    public static let expandedWidthRange: ClosedRange<Double> = 260...480
    public static let defaultExpandedWidth = 300.0

    /// Recognition locales voice control offers (the on-device recognizer is single-locale).
    public static let supportedVoiceLocales = ["en-US", "id-ID"]
    public static let defaultVoiceLocale = "en-US"
    public static let defaultVoiceHotkey = VoiceHotkeyChoice.optionCommandV

    /// Opt-in OpenAI-compatible AI provider. The API key is never stored here: it lives in the
    /// Keychain (`VoiceAIKeychain`). An empty stored text field means "use the default".
    public static let defaultVoiceAIBaseURL = VoiceAIDefaults.baseURL
    public static let defaultVoiceAISTTModel = VoiceAIDefaults.sttModel
    public static let defaultVoiceAIChatModel = VoiceAIDefaults.chatModel
    public static let defaultVoiceAITTSModel = VoiceAIDefaults.ttsModel
    public static let defaultVoiceAITTSVoice = VoiceAIDefaults.ttsVoice
    public static let defaultVoiceAnthropicBaseURL = VoiceAIDefaults.anthropicBaseURL
    public static let defaultVoiceAnthropicModel = VoiceAIDefaults.anthropicModel

    nonisolated public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Value stored in `pillDisplay` when the pill follows the system's choice of screen.
    public static let automaticPillDisplay = "automatic"
    public static let defaultPillMode = PillVisibilityMode.hoverAuto
    /// Default is the STATIC note, not the equalizer: an always-visible pill must not run a
    /// perpetual animation for ordinary activity. Equalizer stays one click away in Settings.
    public static let defaultMusicIndicatorStyle = MusicIndicatorStyle.note
    public static let defaultAnimationStyle = AnimationStyle.subtle

    // MARK: Stored keys & schema

    /// Every UserDefaults key this store owns. Raw values are the on-disk names and must
    /// never change (renaming a case would silently drop users' saved preferences).
    enum Key: String, CaseIterable {
        case schemaVersion
        case nowPlayingEnabled, agentActivityEnabled, calendarEnabled, remindersEnabled
        case processMonitorEnabled, trayEnabled, clipboardHistoryEnabled, volumeScrollEnabled
        case timelineSeekEnabled, batteryEnabled, micCameraIndicatorEnabled, privacyModeEnabled
        case notifyAgentNeedsYou, notifyStuckProcess, agentTaskTitlesEnabled
        case notificationMirrorEnabled, dismissSystemBanners, mutedNotificationApps
        case hasSeenOnboarding, checkForUpdates, globalHotkeyEnabled
        case pillMode, musicIndicatorStyle, animationStyle, pillDisplay
        case hoverCollapseDelay, minimizedWidth, minimizedHeight, expandedWidth
        case voiceEnabled, voiceLocale, voiceHermesLane, voiceTTSEnabled, voiceDuckMedia, voiceHotkey
        case voiceSpeechProvider, voiceAnswersProvider, voiceReplyProvider
        case voiceAIBaseURL, voiceAISTTModel, voiceAIChatModel, voiceAITTSModel, voiceAITTSVoice, voiceAILanguage
        case voiceAnthropicBaseURL, voiceAnthropicModel

        /// Value used when nothing is stored (only meaningful for boolean keys). Feature
        /// toggles default ON; permission-triggering or privacy-sensitive opt-ins default OFF.
        var boolDefault: Bool {
            switch self {
            case .remindersEnabled, .clipboardHistoryEnabled, .privacyModeEnabled,
                 .agentTaskTitlesEnabled, .notificationMirrorEnabled, .dismissSystemBanners,
                 .hasSeenOnboarding, .globalHotkeyEnabled,
                 .voiceEnabled, .voiceHermesLane, .voiceTTSEnabled:
                return false
            default:
                return true
            }
        }
    }

    /// Bump when a stored value's meaning changes, and add the step to `migrations`.
    /// Version 0 means "written before versioning existed".
    public static let currentSchemaVersion = 1

    /// Ordered, idempotent upgrade steps. Each runs once, on a store whose stored
    /// `schemaVersion` is below `version`, before any property is read.
    private static let migrations: [(version: Int, apply: (UserDefaults) -> Void)] = [
        (1, migrateStuckProcessToggle)
    ]

    /// v1: until the notification split, `notifyAgentNeedsYou` also gated stuck-process
    /// alerts. Copy its stored value once so a user who had them off does not suddenly get them.
    private static func migrateStuckProcessToggle(_ defaults: UserDefaults) {
        guard defaults.object(forKey: Key.notifyStuckProcess.rawValue) == nil,
              let legacy = defaults.object(forKey: Key.notifyAgentNeedsYou.rawValue) as? Bool
        else { return }
        defaults.set(legacy, forKey: Key.notifyStuckProcess.rawValue)
    }

    /// Runs pending migrations and stamps the current version. A store written by a newer
    /// build (version above ours) is left untouched rather than downgraded.
    static func migrate(_ defaults: UserDefaults) {
        let stored = defaults.object(forKey: Key.schemaVersion.rawValue) as? Int ?? 0
        guard stored < currentSchemaVersion else { return }
        for step in migrations where step.version > stored {
            step.apply(defaults)
        }
        defaults.set(currentSchemaVersion, forKey: Key.schemaVersion.rawValue)
    }

    // MARK: Feature switches

    @Published public var nowPlayingEnabled: Bool { didSet { set(.nowPlayingEnabled, nowPlayingEnabled) } }
    @Published public var agentActivityEnabled: Bool { didSet { set(.agentActivityEnabled, agentActivityEnabled) } }
    @Published public var calendarEnabled: Bool { didSet { set(.calendarEnabled, calendarEnabled) } }
    /// Shows the next actionable reminder. Explicitly opt-in because enabling it can
    /// trigger a separate Reminders permission prompt.
    @Published public var remindersEnabled: Bool { didSet { set(.remindersEnabled, remindersEnabled) } }
    @Published public var processMonitorEnabled: Bool { didSet { set(.processMonitorEnabled, processMonitorEnabled) } }
    @Published public var trayEnabled: Bool { didSet { set(.trayEnabled, trayEnabled) } }
    /// Recent plain-text clipboard entries, held in memory only. Explicitly opt-in.
    @Published public var clipboardHistoryEnabled: Bool { didSet { set(.clipboardHistoryEnabled, clipboardHistoryEnabled) } }
    @Published public var volumeScrollEnabled: Bool { didSet { set(.volumeScrollEnabled, volumeScrollEnabled) } }
    @Published public var timelineSeekEnabled: Bool { didSet { set(.timelineSeekEnabled, timelineSeekEnabled) } }
    @Published public var batteryEnabled: Bool { didSet { set(.batteryEnabled, batteryEnabled) } }
    @Published public var micCameraIndicatorEnabled: Bool { didSet { set(.micCameraIndicatorEnabled, micCameraIndicatorEnabled) } }
    /// Blanks sensitive media, agent, calendar, reminder, clipboard, tray, and notification text
    /// for screen sharing/recording. Defaults OFF, unlike the feature toggles.
    @Published public var privacyModeEnabled: Bool { didSet { set(.privacyModeEnabled, privacyModeEnabled) } }
    @Published public var notifyAgentNeedsYou: Bool { didSet { set(.notifyAgentNeedsYou, notifyAgentNeedsYou) } }
    /// Notify when the stuck-process detector newly flags a process. Split out of
    /// `notifyAgentNeedsYou`, which used to gate both; see the migration in `init`.
    @Published public var notifyStuckProcess: Bool { didSet { set(.notifyStuckProcess, notifyStuckProcess) } }
    /// Show a hint of each agent session's first prompt (hard-truncated) in the pill and status
    /// menu instead of just the project name. OFF by default: the pill is permanently on
    /// screen and prompts can contain sensitive text.
    @Published public var agentTaskTitlesEnabled: Bool { didSet { set(.agentTaskTitlesEnabled, agentTaskTitlesEnabled) } }
    /// Mirror notification banners into the pill. OFF by default (it additionally
    /// needs the Accessibility permission - two explicit opt-ins, deliberately).
    @Published public var notificationMirrorEnabled: Bool { didSet { set(.notificationMirrorEnabled, notificationMirrorEnabled) } }
    /// After mirroring a banner into the pill, close the system banner so the notch is
    /// the only place it shows. OFF by default. There is no API to suppress banners
    /// *before* they appear (and Focus/DND would blind the mirror entirely), so this
    /// dismisses them just after - expect a brief flash. The notification itself is
    /// untouched and stays in Notification Center.
    @Published public var dismissSystemBanners: Bool { didSet { set(.dismissSystemBanners, dismissSystemBanners) } }
    /// Lowercased display names of apps whose banners are muted in the pill. App
    /// *names* are harmless metadata - notification content is never persisted.
    @Published public private(set) var mutedNotificationApps: [String] {
        didSet { set(.mutedNotificationApps, mutedNotificationApps) }
    }

    /// Check GitHub once a day for a newer release (a single anonymous request). ON by default;
    /// off means `UpdateChecker` makes no network request at all.
    @Published public var checkForUpdates: Bool { didSet { set(.checkForUpdates, checkForUpdates) } }

    /// Register the global show-notch shortcut (`HotKeyBinding.default`). OFF by default: a
    /// global shortcut takes the key combination away from every other app.
    @Published public var globalHotkeyEnabled: Bool { didSet { set(.globalHotkeyEnabled, globalHotkeyEnabled) } }

    // MARK: Voice control (all OFF by default; never exported or imported, see SettingsTransfer)

    /// Master switch for voice control. OFF by default: enabling it requests Microphone and
    /// Speech Recognition access. Voice is inert in smoke-test mode regardless of this value.
    @Published public var voiceEnabled: Bool { didSet { set(.voiceEnabled, voiceEnabled) } }
    /// Recognition locale, one of `supportedVoiceLocales`; anything else normalizes to the default.
    @Published public var voiceLocale: String {
        didSet {
            let normalized = Self.normalizedVoiceLocale(voiceLocale)
            if normalized != voiceLocale { voiceLocale = normalized }
            set(.voiceLocale, normalized)
        }
    }
    /// Allow utterances that are not local commands to go to the Hermes agent (cloud-routed).
    /// OFF by default; additionally gated by the profile preflight at runtime.
    @Published public var voiceHermesLane: Bool { didSet { set(.voiceHermesLane, voiceHermesLane) } }
    /// Speak replies aloud. OFF by default; always silent in privacy mode.
    @Published public var voiceTTSEnabled: Bool { didSet { set(.voiceTTSEnabled, voiceTTSEnabled) } }
    /// Lower other audio while the mic is open.
    @Published public var voiceDuckMedia: Bool { didSet { set(.voiceDuckMedia, voiceDuckMedia) } }
    @Published public var voiceHotkey: VoiceHotkeyChoice { didSet { set(.voiceHotkey, voiceHotkey.rawValue) } }
    /// Speech-to-text engine. On-device by default.
    @Published public var voiceSpeechProvider: VoiceSpeechProvider {
        didSet { set(.voiceSpeechProvider, voiceSpeechProvider.rawValue) }
    }
    /// Backend of the agent lane when `voiceHermesLane` is on. Hermes by default.
    @Published public var voiceAnswersProvider: VoiceAnswersProvider {
        didSet { set(.voiceAnswersProvider, voiceAnswersProvider.rawValue) }
    }
    /// Voice of spoken replies. The macOS voice by default.
    @Published public var voiceReplyProvider: VoiceReplyProvider {
        didSet { set(.voiceReplyProvider, voiceReplyProvider.rawValue) }
    }
    /// Base URL of the OpenAI-compatible provider (e.g. `https://api.openai.com/v1`). Machine
    /// and account specific, so it is never exported. Validated (https, or http to this Mac)
    /// where it is used, not here, so typing in Settings is never rewritten mid-edit.
    @Published public var voiceAIBaseURL: String {
        didSet { normalizeAndSet(\.voiceAIBaseURL, .voiceAIBaseURL, Self.normalizedVoiceAIBaseURL) }
    }
    @Published public var voiceAISTTModel: String {
        didSet { normalizeAndSet(\.voiceAISTTModel, .voiceAISTTModel, Self.normalizedVoiceAIModel) }
    }
    @Published public var voiceAIChatModel: String {
        didSet { normalizeAndSet(\.voiceAIChatModel, .voiceAIChatModel, Self.normalizedVoiceAIModel) }
    }
    @Published public var voiceAITTSModel: String {
        didSet { normalizeAndSet(\.voiceAITTSModel, .voiceAITTSModel, Self.normalizedVoiceAIModel) }
    }
    @Published public var voiceAITTSVoice: String {
        didSet { normalizeAndSet(\.voiceAITTSVoice, .voiceAITTSVoice, Self.normalizedVoiceAIModel) }
    }
    /// Base URL of the Anthropic Messages API (requests go to `<base>/v1/messages`). Never exported.
    @Published public var voiceAnthropicBaseURL: String {
        didSet { normalizeAndSet(\.voiceAnthropicBaseURL, .voiceAnthropicBaseURL, Self.normalizedVoiceAIBaseURL) }
    }
    @Published public var voiceAnthropicModel: String {
        didSet { normalizeAndSet(\.voiceAnthropicModel, .voiceAnthropicModel, Self.normalizedVoiceAIModel) }
    }
    /// ISO-639-1 hint for cloud speech-to-text ("en", "id"). Empty = auto-detect, which is
    /// what mixed Indonesian/English speech needs.
    @Published public var voiceAILanguage: String {
        didSet { normalizeAndSet(\.voiceAILanguage, .voiceAILanguage, Self.normalizedVoiceAILanguage) }
    }

    /// One-time product guide state. The guide is always reopenable from the status menu.
    @Published public var hasSeenOnboarding: Bool { didSet { set(.hasSeenOnboarding, hasSeenOnboarding) } }

    public func setNotificationApp(_ appName: String, muted: Bool) {
        let key = appName.lowercased()
        var list = mutedNotificationApps
        if muted {
            guard !list.contains(key) else { return }
            list.append(key)
        } else {
            list.removeAll { $0 == key }
        }
        mutedNotificationApps = list
    }

    func clearMutedNotificationApps() {
        mutedNotificationApps = []
    }

    // MARK: Pill behavior & sizing

    @Published public var pillMode: PillVisibilityMode { didSet { set(.pillMode, pillMode.rawValue) } }
    @Published public var musicIndicatorStyle: MusicIndicatorStyle {
        didSet { set(.musicIndicatorStyle, musicIndicatorStyle.rawValue) }
    }
    @Published public var animationStyle: AnimationStyle {
        didSet { set(.animationStyle, animationStyle.rawValue) }
    }

    /// Which display hosts the pill: `automaticPillDisplay` or an opaque display identifier
    /// chosen in Settings. Machine-specific, so it is deliberately not exported. A stored
    /// identifier whose display is gone is the consumer's problem to fall back from.
    @Published public var pillDisplay: String {
        didSet {
            // Assigning inside the property's own observer does not re-enter it.
            let normalized = Self.normalizedPillDisplay(pillDisplay)
            if normalized != pillDisplay { pillDisplay = normalized }
            set(.pillDisplay, normalized)
        }
    }

    /// The chosen display identifier, or nil while the pill follows the system's screen.
    public var pillDisplayIdentifier: String? {
        pillDisplay == Self.automaticPillDisplay ? nil : pillDisplay
    }

    @Published public var hoverCollapseDelay: Double {
        didSet { clampAndSet(\.hoverCollapseDelay, .hoverCollapseDelay, Self.hoverCollapseDelayRange) }
    }
    @Published public var minimizedWidth: Double {
        didSet { clampAndSet(\.minimizedWidth, .minimizedWidth, Self.minimizedWidthRange) }
    }
    @Published public var minimizedHeight: Double {
        didSet { clampAndSet(\.minimizedHeight, .minimizedHeight, Self.minimizedHeightRange) }
    }
    @Published public var expandedWidth: Double {
        didSet { clampAndSet(\.expandedWidth, .expandedWidth, Self.expandedWidthRange) }
    }

    private let defaults: UserDefaults

    /// Internal (not private) so tests can build a store against an isolated suite.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        Self.migrate(defaults)
        nowPlayingEnabled = Self.bool(defaults, .nowPlayingEnabled)
        agentActivityEnabled = Self.bool(defaults, .agentActivityEnabled)
        calendarEnabled = Self.bool(defaults, .calendarEnabled)
        remindersEnabled = Self.bool(defaults, .remindersEnabled)
        processMonitorEnabled = Self.bool(defaults, .processMonitorEnabled)
        trayEnabled = Self.bool(defaults, .trayEnabled)
        clipboardHistoryEnabled = Self.bool(defaults, .clipboardHistoryEnabled)
        volumeScrollEnabled = Self.bool(defaults, .volumeScrollEnabled)
        timelineSeekEnabled = Self.bool(defaults, .timelineSeekEnabled)
        batteryEnabled = Self.bool(defaults, .batteryEnabled)
        micCameraIndicatorEnabled = Self.bool(defaults, .micCameraIndicatorEnabled)
        privacyModeEnabled = Self.bool(defaults, .privacyModeEnabled)
        notifyAgentNeedsYou = Self.bool(defaults, .notifyAgentNeedsYou)
        notifyStuckProcess = Self.bool(defaults, .notifyStuckProcess)
        agentTaskTitlesEnabled = Self.bool(defaults, .agentTaskTitlesEnabled)
        notificationMirrorEnabled = Self.bool(defaults, .notificationMirrorEnabled)
        dismissSystemBanners = Self.bool(defaults, .dismissSystemBanners)
        mutedNotificationApps = defaults.stringArray(forKey: Key.mutedNotificationApps.rawValue) ?? []
        hasSeenOnboarding = Self.bool(defaults, .hasSeenOnboarding)
        checkForUpdates = Self.bool(defaults, .checkForUpdates)
        globalHotkeyEnabled = Self.bool(defaults, .globalHotkeyEnabled)
        voiceEnabled = Self.bool(defaults, .voiceEnabled)
        voiceLocale = Self.normalizedVoiceLocale(Self.string(defaults, .voiceLocale))
        voiceHermesLane = Self.bool(defaults, .voiceHermesLane)
        voiceTTSEnabled = Self.bool(defaults, .voiceTTSEnabled)
        voiceDuckMedia = Self.bool(defaults, .voiceDuckMedia)
        voiceHotkey = Self.string(defaults, .voiceHotkey)
            .flatMap(VoiceHotkeyChoice.init(rawValue:)) ?? Self.defaultVoiceHotkey
        voiceSpeechProvider = Self.string(defaults, .voiceSpeechProvider)
            .flatMap(VoiceSpeechProvider.init(rawValue:)) ?? .onDevice
        voiceAnswersProvider = Self.string(defaults, .voiceAnswersProvider)
            .flatMap(VoiceAnswersProvider.init(rawValue:)) ?? .hermes
        voiceReplyProvider = Self.string(defaults, .voiceReplyProvider)
            .flatMap(VoiceReplyProvider.init(rawValue:)) ?? .system
        voiceAIBaseURL = Self.normalizedVoiceAIBaseURL(Self.string(defaults, .voiceAIBaseURL) ?? Self.defaultVoiceAIBaseURL)
        voiceAISTTModel = Self.normalizedVoiceAIModel(Self.string(defaults, .voiceAISTTModel) ?? Self.defaultVoiceAISTTModel)
        voiceAIChatModel = Self.normalizedVoiceAIModel(Self.string(defaults, .voiceAIChatModel) ?? Self.defaultVoiceAIChatModel)
        voiceAITTSModel = Self.normalizedVoiceAIModel(Self.string(defaults, .voiceAITTSModel) ?? Self.defaultVoiceAITTSModel)
        voiceAITTSVoice = Self.normalizedVoiceAIModel(Self.string(defaults, .voiceAITTSVoice) ?? Self.defaultVoiceAITTSVoice)
        voiceAILanguage = Self.normalizedVoiceAILanguage(Self.string(defaults, .voiceAILanguage) ?? "")
        voiceAnthropicBaseURL = Self.normalizedVoiceAIBaseURL(
            Self.string(defaults, .voiceAnthropicBaseURL) ?? Self.defaultVoiceAnthropicBaseURL
        )
        voiceAnthropicModel = Self.normalizedVoiceAIModel(
            Self.string(defaults, .voiceAnthropicModel) ?? Self.defaultVoiceAnthropicModel
        )

        pillMode = Self.string(defaults, .pillMode).flatMap(PillVisibilityMode.init(rawValue:)) ?? Self.defaultPillMode
        musicIndicatorStyle = Self.string(defaults, .musicIndicatorStyle)
            .flatMap(MusicIndicatorStyle.init(rawValue:)) ?? Self.defaultMusicIndicatorStyle
        animationStyle = Self.string(defaults, .animationStyle)
            .flatMap(AnimationStyle.init(rawValue:)) ?? Self.defaultAnimationStyle
        pillDisplay = Self.normalizedPillDisplay(Self.string(defaults, .pillDisplay))
        hoverCollapseDelay = Self.double(defaults, .hoverCollapseDelay, Self.defaultHoverCollapseDelay, Self.hoverCollapseDelayRange)
        minimizedWidth = Self.double(defaults, .minimizedWidth, Self.defaultMinimizedWidth, Self.minimizedWidthRange)
        minimizedHeight = Self.double(defaults, .minimizedHeight, Self.defaultMinimizedHeight, Self.minimizedHeightRange)
        expandedWidth = Self.double(defaults, .expandedWidth, Self.defaultExpandedWidth, Self.expandedWidthRange)
    }

    // MARK: - Plumbing

    private static func bool(_ defaults: UserDefaults, _ key: Key) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? key.boolDefault
    }

    private static func string(_ defaults: UserDefaults, _ key: Key) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    private static func double(
        _ defaults: UserDefaults, _ key: Key, _ fallback: Double, _ range: ClosedRange<Double>
    ) -> Double {
        guard let stored = defaults.object(forKey: key.rawValue) as? Double else { return fallback }
        return clamp(stored, to: range)
    }

    /// Blank or whitespace-only identifiers mean "automatic"; overlong ones are truncated so a
    /// hand-edited value cannot bloat the defaults domain.
    private static func normalizedPillDisplay(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return automaticPillDisplay }
        return String(trimmed.prefix(maxPillDisplayLength))
    }

    private static let maxPillDisplayLength = 128

    /// Unsupported or missing locales fall back to the default rather than reaching the recognizer.
    static func normalizedVoiceLocale(_ raw: String?) -> String {
        guard let raw, supportedVoiceLocales.contains(raw) else { return defaultVoiceLocale }
        return raw
    }

    /// Trims, drops trailing slashes and caps the length. Never substitutes the default (an empty
    /// field means "default" at use time), so clearing the field to retype it is not undone.
    nonisolated static func normalizedVoiceAIBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = String(value.prefix(VoiceAIDefaults.maxBaseURLLength))
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Model and voice identifiers: letters, digits and `._:/@+-` only, capped. Anything else
    /// (spaces, quotes, control characters) is dropped as it is typed.
    nonisolated static func normalizedVoiceAIModel(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/@+-"))
        let kept = raw.unicodeScalars.filter { $0.isASCII && allowed.contains($0) }
        return String(String.UnicodeScalarView(kept).prefix(VoiceAIDefaults.maxModelLength))
    }

    /// Language hint: ASCII letters and `-` only, capped (e.g. "id", "en", "pt-BR").
    nonisolated static func normalizedVoiceAILanguage(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.letters.contains($0) || $0 == "-")
        }
        return String(String.UnicodeScalarView(kept).prefix(VoiceAIDefaults.maxLanguageLength))
    }

    /// Re-assigns a write that normalization changed (one bounded re-entry), then persists.
    private func normalizeAndSet(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, String>,
        _ key: Key,
        _ normalize: (String) -> String
    ) {
        let value = self[keyPath: keyPath]
        let normalized = normalize(value)
        if normalized != value {
            self[keyPath: keyPath] = normalized
            return
        }
        set(key, value)
    }

    private func set(_ key: Key, _ value: Any) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// Re-assigns out-of-range writes to the clamped value (one bounded re-entry),
    /// then persists. Keeps sliders, defaults edits, and programmatic writes all honest.
    private func clampAndSet(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, Double>,
        _ key: Key,
        _ range: ClosedRange<Double>
    ) {
        let value = self[keyPath: keyPath]
        let clamped = Self.clamp(value, to: range)
        if clamped != value {
            self[keyPath: keyPath] = clamped
            return
        }
        set(key, value)
    }

}
