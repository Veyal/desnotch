import Foundation

/// How the pill behaves when the pointer isn't over it.
public enum PillVisibilityMode: String {
    /// Minimized by default; hover expands, leaving collapses after `hoverCollapseDelay`.
    case hoverAuto
    /// Never minimizes - the expanded pill is always on screen.
    case alwaysOn
}

/// Which indicator the minimized wing shows for now-playing media.
public enum MusicIndicatorStyle: String, CaseIterable {
    /// Animated equalizer bars while playing, static note while paused (default).
    case equalizer
    /// Always the static music note.
    case note
    /// The current track's album artwork; falls back to equalizer/note behavior when
    /// a track has no artwork, and is suppressed entirely by privacy mode (artwork
    /// identifies the track on a permanently visible, screen-shared surface).
    case albumArt
}

/// User-toggleable feature switches and pill-behavior knobs, UserDefaults-backed.
/// The pill view gates its sections on these; pollers (process monitor, calendar,
/// agent scanner) also check them so disabled features stop doing background work.
/// `notifyAgentNeedsYou` shares its key with `AgentAttentionNotifier.isEnabled`.
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

    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Feature switches

    @Published public var nowPlayingEnabled: Bool { didSet { set("nowPlayingEnabled", nowPlayingEnabled) } }
    @Published public var agentActivityEnabled: Bool { didSet { set("agentActivityEnabled", agentActivityEnabled) } }
    @Published public var calendarEnabled: Bool { didSet { set("calendarEnabled", calendarEnabled) } }
    @Published public var processMonitorEnabled: Bool { didSet { set("processMonitorEnabled", processMonitorEnabled) } }
    @Published public var trayEnabled: Bool { didSet { set("trayEnabled", trayEnabled) } }
    @Published public var volumeScrollEnabled: Bool { didSet { set("volumeScrollEnabled", volumeScrollEnabled) } }
    @Published public var timelineSeekEnabled: Bool { didSet { set("timelineSeekEnabled", timelineSeekEnabled) } }
    @Published public var batteryEnabled: Bool { didSet { set("batteryEnabled", batteryEnabled) } }
    @Published public var micCameraIndicatorEnabled: Bool { didSet { set("micCameraIndicatorEnabled", micCameraIndicatorEnabled) } }
    /// Blanks sensitive text (agent task titles, calendar event titles) for screen
    /// sharing/recording. Defaults OFF, unlike the feature toggles.
    @Published public var privacyModeEnabled: Bool { didSet { set("privacyModeEnabled", privacyModeEnabled) } }
    @Published public var notifyAgentNeedsYou: Bool { didSet { set(AgentAttentionNotifier.defaultsKey, notifyAgentNeedsYou) } }
    /// Mirror notification banners into the pill. OFF by default (it additionally
    /// needs the Accessibility permission - two explicit opt-ins, deliberately).
    @Published public var notificationMirrorEnabled: Bool { didSet { set("notificationMirrorEnabled", notificationMirrorEnabled) } }
    /// Lowercased display names of apps whose banners are muted in the pill. App
    /// *names* are harmless metadata - notification content is never persisted.
    @Published public private(set) var mutedNotificationApps: [String] {
        didSet { set("mutedNotificationApps", mutedNotificationApps) }
    }

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

    // MARK: Pill behavior & sizing

    @Published public var pillMode: PillVisibilityMode { didSet { set("pillMode", pillMode.rawValue) } }
    @Published public var musicIndicatorStyle: MusicIndicatorStyle {
        didSet { set("musicIndicatorStyle", musicIndicatorStyle.rawValue) }
    }

    @Published public var hoverCollapseDelay: Double {
        didSet { clampAndSet(\.hoverCollapseDelay, "hoverCollapseDelay", Self.hoverCollapseDelayRange) }
    }
    @Published public var minimizedWidth: Double {
        didSet { clampAndSet(\.minimizedWidth, "minimizedWidth", Self.minimizedWidthRange) }
    }
    @Published public var minimizedHeight: Double {
        didSet { clampAndSet(\.minimizedHeight, "minimizedHeight", Self.minimizedHeightRange) }
    }
    @Published public var expandedWidth: Double {
        didSet { clampAndSet(\.expandedWidth, "expandedWidth", Self.expandedWidthRange) }
    }

    private let defaults: UserDefaults

    /// Internal (not private) so tests can build a store against an isolated suite.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        nowPlayingEnabled = Self.bool(defaults, "nowPlayingEnabled")
        agentActivityEnabled = Self.bool(defaults, "agentActivityEnabled")
        calendarEnabled = Self.bool(defaults, "calendarEnabled")
        processMonitorEnabled = Self.bool(defaults, "processMonitorEnabled")
        trayEnabled = Self.bool(defaults, "trayEnabled")
        volumeScrollEnabled = Self.bool(defaults, "volumeScrollEnabled")
        timelineSeekEnabled = Self.bool(defaults, "timelineSeekEnabled")
        batteryEnabled = Self.bool(defaults, "batteryEnabled")
        micCameraIndicatorEnabled = Self.bool(defaults, "micCameraIndicatorEnabled")
        privacyModeEnabled = defaults.object(forKey: "privacyModeEnabled") as? Bool ?? false
        notifyAgentNeedsYou = Self.bool(defaults, AgentAttentionNotifier.defaultsKey)
        notificationMirrorEnabled = defaults.object(forKey: "notificationMirrorEnabled") as? Bool ?? false
        mutedNotificationApps = defaults.stringArray(forKey: "mutedNotificationApps") ?? []

        pillMode = (defaults.string(forKey: "pillMode")).flatMap(PillVisibilityMode.init(rawValue:)) ?? .hoverAuto
        musicIndicatorStyle = (defaults.string(forKey: "musicIndicatorStyle"))
            .flatMap(MusicIndicatorStyle.init(rawValue:)) ?? .equalizer
        hoverCollapseDelay = Self.double(defaults, "hoverCollapseDelay", Self.defaultHoverCollapseDelay, Self.hoverCollapseDelayRange)
        minimizedWidth = Self.double(defaults, "minimizedWidth", Self.defaultMinimizedWidth, Self.minimizedWidthRange)
        minimizedHeight = Self.double(defaults, "minimizedHeight", Self.defaultMinimizedHeight, Self.minimizedHeightRange)
        expandedWidth = Self.double(defaults, "expandedWidth", Self.defaultExpandedWidth, Self.expandedWidthRange)
    }

    // MARK: - Plumbing

    private static func bool(_ defaults: UserDefaults, _ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    private static func double(
        _ defaults: UserDefaults, _ key: String, _ fallback: Double, _ range: ClosedRange<Double>
    ) -> Double {
        guard let stored = defaults.object(forKey: key) as? Double else { return fallback }
        return clamp(stored, to: range)
    }

    private func set(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    /// Re-assigns out-of-range writes to the clamped value (one bounded re-entry),
    /// then persists. Keeps sliders, defaults edits, and programmatic writes all honest.
    private func clampAndSet(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, Double>,
        _ key: String,
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
