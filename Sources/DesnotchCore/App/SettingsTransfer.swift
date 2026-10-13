import Foundation

/// Settings export / import / reset.
///
/// The exported file is a plain JSON document of *preferences only*: booleans, clamped numbers,
/// and enum choices. It deliberately contains nothing sensitive or machine-specific - no muted app
/// names, no file paths, no display identifier, no onboarding state, and nothing from the
/// transcripts/calendar/reminders/clipboard features. Imports are validated against the same
/// allowlist (key name + value type); anything else is ignored and reported, never stored.
extension SettingsStore {
    /// Schema marker written to (and checked on) exported files.
    public static let exportAppName = "desnotch"
    /// Imports larger than this are refused before parsing; real exports are well under 2 KB.
    public static let maxImportBytes = 64 * 1024

    public struct ImportReport: Equatable {
        /// Keys that were valid and applied (numbers are applied clamped to their range).
        public let applied: [String]
        /// Keys that were unknown or carried a value of the wrong type.
        public let rejected: [String]
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case tooLarge
        case notSettingsFile
        case newerSchema(Int)

        public var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "That file is too large to be a desnotch settings export."
            case .notSettingsFile:
                return "That file is not a desnotch settings export."
            case .newerSchema:
                return "That export comes from a newer version of desnotch. Update the app and try again."
            }
        }
    }

    /// One exportable preference: where it lives, how to read it as JSON, how to validate and
    /// apply an untrusted value, and how to restore its default.
    struct Field {
        let key: Key
        let read: (SettingsStore) -> Any
        /// Returns false (and changes nothing) when `value` has the wrong type.
        let apply: (SettingsStore, Any) -> Bool
        let reset: (SettingsStore) -> Void
    }

    private static func isJSONBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func boolField(
        _ key: Key, _ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>
    ) -> Field {
        Field(
            key: key,
            read: { $0[keyPath: keyPath] },
            apply: { store, value in
                guard let number = value as? NSNumber, isJSONBoolean(number) else { return false }
                store[keyPath: keyPath] = number.boolValue
                return true
            },
            reset: { $0[keyPath: keyPath] = key.boolDefault }
        )
    }

    private static func doubleField(
        _ key: Key,
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, Double>,
        default fallback: Double,
        range: ClosedRange<Double>
    ) -> Field {
        Field(
            key: key,
            read: { $0[keyPath: keyPath] },
            apply: { store, value in
                guard let number = value as? NSNumber, !isJSONBoolean(number),
                      number.doubleValue.isFinite else { return false }
                store[keyPath: keyPath] = clamp(number.doubleValue, to: range)
                return true
            },
            reset: { $0[keyPath: keyPath] = fallback }
        )
    }

    private static func choiceField<T: RawRepresentable & CaseIterable>(
        _ key: Key,
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, T>,
        default fallback: T
    ) -> Field where T.RawValue == String {
        Field(
            key: key,
            read: { $0[keyPath: keyPath].rawValue },
            apply: { store, value in
                guard let raw = value as? String, let choice = T(rawValue: raw) else { return false }
                store[keyPath: keyPath] = choice
                return true
            },
            reset: { $0[keyPath: keyPath] = fallback }
        )
    }

    /// The export/import allowlist. A preference not listed here is never exported or imported.
    static let transferFields: [Field] = [
        boolField(.nowPlayingEnabled, \.nowPlayingEnabled),
        boolField(.agentActivityEnabled, \.agentActivityEnabled),
        boolField(.calendarEnabled, \.calendarEnabled),
        boolField(.remindersEnabled, \.remindersEnabled),
        boolField(.processMonitorEnabled, \.processMonitorEnabled),
        boolField(.trayEnabled, \.trayEnabled),
        boolField(.clipboardHistoryEnabled, \.clipboardHistoryEnabled),
        boolField(.volumeScrollEnabled, \.volumeScrollEnabled),
        boolField(.timelineSeekEnabled, \.timelineSeekEnabled),
        boolField(.batteryEnabled, \.batteryEnabled),
        boolField(.micCameraIndicatorEnabled, \.micCameraIndicatorEnabled),
        boolField(.privacyModeEnabled, \.privacyModeEnabled),
        boolField(.notifyAgentNeedsYou, \.notifyAgentNeedsYou),
        boolField(.notifyStuckProcess, \.notifyStuckProcess),
        boolField(.agentTaskTitlesEnabled, \.agentTaskTitlesEnabled),
        boolField(.notificationMirrorEnabled, \.notificationMirrorEnabled),
        boolField(.dismissSystemBanners, \.dismissSystemBanners),
        boolField(.checkForUpdates, \.checkForUpdates),
        boolField(.globalHotkeyEnabled, \.globalHotkeyEnabled),
        choiceField(.pillMode, \.pillMode, default: defaultPillMode),
        choiceField(.musicIndicatorStyle, \.musicIndicatorStyle, default: defaultMusicIndicatorStyle),
        choiceField(.animationStyle, \.animationStyle, default: defaultAnimationStyle),
        doubleField(.hoverCollapseDelay, \.hoverCollapseDelay,
                    default: defaultHoverCollapseDelay, range: hoverCollapseDelayRange),
        doubleField(.minimizedWidth, \.minimizedWidth,
                    default: defaultMinimizedWidth, range: minimizedWidthRange),
        doubleField(.minimizedHeight, \.minimizedHeight,
                    default: defaultMinimizedHeight, range: minimizedHeightRange),
        doubleField(.expandedWidth, \.expandedWidth,
                    default: defaultExpandedWidth, range: expandedWidthRange)
    ]

    /// Names of every exportable preference (for tests and documentation).
    public static var exportedKeyNames: [String] {
        transferFields.map(\.key.rawValue)
    }

    /// Serializes the exportable preferences as pretty-printed, key-sorted JSON.
    public func exportJSON() throws -> Data {
        var values: [String: Any] = [:]
        for field in Self.transferFields {
            values[field.key.rawValue] = field.read(self)
        }
        let root: [String: Any] = [
            "app": Self.exportAppName,
            "schemaVersion": Self.currentSchemaVersion,
            "settings": values
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Applies a previously exported document. Valid entries are applied (through the normal
    /// published properties, so the UI and pollers react exactly as if the user had toggled
    /// them); unknown keys and wrongly typed values are skipped and reported.
    @discardableResult
    public func importJSON(_ data: Data) throws -> ImportReport {
        guard data.count <= Self.maxImportBytes else { throw ImportError.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let settings = root["settings"] as? [String: Any] else {
            throw ImportError.notSettingsFile
        }
        if let app = root["app"], (app as? String) != Self.exportAppName {
            throw ImportError.notSettingsFile
        }
        if let version = root["schemaVersion"] {
            guard let number = version as? NSNumber, !Self.isJSONBoolean(number),
                  number.intValue >= 0, Double(number.intValue) == number.doubleValue else {
                throw ImportError.notSettingsFile
            }
            if number.intValue > Self.currentSchemaVersion {
                throw ImportError.newerSchema(number.intValue)
            }
        }

        let fieldsByName = Dictionary(uniqueKeysWithValues: Self.transferFields.map { ($0.key.rawValue, $0) })
        var applied: [String] = []
        var rejected: [String] = []
        for name in settings.keys.sorted() {
            if let field = fieldsByName[name], let value = settings[name], field.apply(self, value) {
                applied.append(name)
            } else {
                rejected.append(name)
            }
        }
        return ImportReport(applied: applied, rejected: rejected)
    }

    /// Restores every preference to its default, including the muted-notification-app list and
    /// the chosen pill display. Keeps `hasSeenOnboarding` (a reset must not replay the guide)
    /// and the schema version; Launch at login lives with macOS, not here.
    public func resetToDefaults() {
        for field in Self.transferFields {
            field.reset(self)
        }
        pillDisplay = Self.automaticPillDisplay
        if !mutedNotificationApps.isEmpty { clearMutedNotificationApps() }
        // Voice settings are never exported or imported (permission-triggering opt-ins), but a
        // reset must still switch them back off.
        voiceEnabled = false
        voiceLocale = Self.defaultVoiceLocale
        voiceHermesLane = false
        voiceTTSEnabled = false
        voiceDuckMedia = true
        voiceHotkey = Self.defaultVoiceHotkey
        voiceSpeechProvider = .onDevice
        voiceAnswersProvider = .hermes
        voiceReplyProvider = .system
        voiceAIBaseURL = Self.defaultVoiceAIBaseURL
        voiceAISTTModel = Self.defaultVoiceAISTTModel
        voiceAIChatModel = Self.defaultVoiceAIChatModel
        voiceAITTSModel = Self.defaultVoiceAITTSModel
        voiceAITTSVoice = Self.defaultVoiceAITTSVoice
        voiceAILanguage = ""
        voiceAnthropicBaseURL = Self.defaultVoiceAnthropicBaseURL
        voiceAnthropicModel = Self.defaultVoiceAnthropicModel
        voiceAgentToolsEnabled = false
    }
}
