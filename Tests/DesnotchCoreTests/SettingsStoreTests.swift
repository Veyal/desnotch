import XCTest
@testable import DesnotchCore

/// Settings persistence, clamping, and pill sizing rules. Uses an isolated
/// UserDefaults suite so tests never touch (or get polluted by) real app settings.
final class SettingsStoreTests: XCTestCase {
    private let suiteName = "desnotch.tests.settings"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Defaults

    @MainActor
    func testFreshStoreUsesDocumentedDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.pillMode, .hoverAuto)
        XCTAssertEqual(store.hoverCollapseDelay, SettingsStore.defaultHoverCollapseDelay)
        XCTAssertEqual(store.minimizedWidth, SettingsStore.defaultMinimizedWidth)
        XCTAssertEqual(store.minimizedHeight, SettingsStore.defaultMinimizedHeight)
        XCTAssertEqual(store.expandedWidth, SettingsStore.defaultExpandedWidth)
        XCTAssertTrue(store.trayEnabled)
        XCTAssertTrue(store.nowPlayingEnabled)
        XCTAssertFalse(store.clipboardHistoryEnabled)
        XCTAssertFalse(store.remindersEnabled)
        XCTAssertFalse(store.hasSeenOnboarding)
        XCTAssertFalse(store.agentTaskTitlesEnabled, "prompt-derived titles are opt-in")
        XCTAssertTrue(store.notifyAgentNeedsYou)
        XCTAssertTrue(store.notifyStuckProcess)
        XCTAssertTrue(store.checkForUpdates, "update checks default ON")
        XCTAssertFalse(store.globalHotkeyEnabled, "a global shortcut is opt-in")
        XCTAssertEqual(store.pillDisplay, SettingsStore.automaticPillDisplay)
        XCTAssertNil(store.pillDisplayIdentifier)
    }

    @MainActor
    func testStuckProcessToggleInheritsLegacyAgentNotificationValueOnce() {
        // Before the split, notifyAgentNeedsYou gated both alert kinds.
        defaults.set(false, forKey: "notifyAgentNeedsYou")
        let migrated = SettingsStore(defaults: defaults)
        XCTAssertFalse(migrated.notifyAgentNeedsYou)
        XCTAssertFalse(migrated.notifyStuckProcess)

        // Once the new key is stored, it is independent.
        migrated.notifyStuckProcess = true
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.notifyAgentNeedsYou)
        XCTAssertTrue(reloaded.notifyStuckProcess)
    }

    // MARK: Persistence

    @MainActor
    func testValuesPersistAcrossStoreInstances() {
        let store = SettingsStore(defaults: defaults)
        store.pillMode = .alwaysOn
        store.hoverCollapseDelay = 1.5
        store.minimizedWidth = 240
        store.minimizedHeight = 34
        store.expandedWidth = 360
        store.trayEnabled = false
        store.clipboardHistoryEnabled = true
        store.remindersEnabled = true
        store.hasSeenOnboarding = true
        store.agentTaskTitlesEnabled = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.pillMode, .alwaysOn)
        XCTAssertEqual(reloaded.hoverCollapseDelay, 1.5)
        XCTAssertEqual(reloaded.minimizedWidth, 240)
        XCTAssertEqual(reloaded.minimizedHeight, 34)
        XCTAssertEqual(reloaded.expandedWidth, 360)
        XCTAssertFalse(reloaded.trayEnabled)
        XCTAssertTrue(reloaded.clipboardHistoryEnabled)
        XCTAssertTrue(reloaded.remindersEnabled)
        XCTAssertTrue(reloaded.hasSeenOnboarding)
        XCTAssertTrue(reloaded.agentTaskTitlesEnabled)
    }

    @MainActor
    func testUnknownStoredModeFallsBackToHoverAuto() {
        defaults.set("definitely-not-a-mode", forKey: "pillMode")
        XCTAssertEqual(SettingsStore(defaults: defaults).pillMode, .hoverAuto)
    }

    // MARK: Clamping

    func testClampHelper() {
        XCTAssertEqual(SettingsStore.clamp(0, to: 0.1...5), 0.1)
        XCTAssertEqual(SettingsStore.clamp(99, to: 0.1...5), 5)
        XCTAssertEqual(SettingsStore.clamp(2.5, to: 0.1...5), 2.5)
    }

    @MainActor
    func testOutOfRangeWritesAreClampedAndPersistedClamped() {
        let store = SettingsStore(defaults: defaults)
        store.hoverCollapseDelay = 60
        XCTAssertEqual(store.hoverCollapseDelay, SettingsStore.hoverCollapseDelayRange.upperBound)
        store.minimizedWidth = 1
        XCTAssertEqual(store.minimizedWidth, SettingsStore.minimizedWidthRange.lowerBound)
        store.expandedWidth = 10_000
        XCTAssertEqual(store.expandedWidth, SettingsStore.expandedWidthRange.upperBound)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hoverCollapseDelay, SettingsStore.hoverCollapseDelayRange.upperBound)
        XCTAssertEqual(reloaded.minimizedWidth, SettingsStore.minimizedWidthRange.lowerBound)
        XCTAssertEqual(reloaded.expandedWidth, SettingsStore.expandedWidthRange.upperBound)
    }

    @MainActor
    func testHandEditedDefaultsAreClampedOnLoad() {
        defaults.set(0.0, forKey: "hoverCollapseDelay")
        defaults.set(9999.0, forKey: "minimizedWidth")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.hoverCollapseDelay, SettingsStore.hoverCollapseDelayRange.lowerBound)
        XCTAssertEqual(store.minimizedWidth, SettingsStore.minimizedWidthRange.upperBound)
    }

    // MARK: Expanded sizing rule

    func testExpandedWidthNeverNarrowerThanCutoutPlusWings() {
        // Preferred width wins when it covers the cutout...
        XCTAssertEqual(
            NotchGeometry.expandedPillWidth(preferred: 300, cutoutWidth: 200, wingWidth: 44), 300
        )
        // ...but a wide cutout (or a small preferred width) forces full hardware coverage.
        XCTAssertEqual(
            NotchGeometry.expandedPillWidth(preferred: 260, cutoutWidth: 240, wingWidth: 44), 328
        )
    }

    // MARK: Keys & schema migration

    func testStoredKeyNamesAreStable() {
        // Raw values are the on-disk names; changing one silently drops saved preferences.
        let expected: Set<String> = [
            "schemaVersion", "nowPlayingEnabled", "agentActivityEnabled", "calendarEnabled",
            "remindersEnabled", "processMonitorEnabled", "trayEnabled", "clipboardHistoryEnabled",
            "volumeScrollEnabled", "timelineSeekEnabled", "batteryEnabled",
            "micCameraIndicatorEnabled", "privacyModeEnabled", "notifyAgentNeedsYou",
            "notifyStuckProcess", "agentTaskTitlesEnabled", "notificationMirrorEnabled",
            "dismissSystemBanners", "mutedNotificationApps", "hasSeenOnboarding", "checkForUpdates",
            "globalHotkeyEnabled",
            "pillMode", "musicIndicatorStyle", "animationStyle", "pillDisplay",
            "hoverCollapseDelay", "minimizedWidth", "minimizedHeight", "expandedWidth",
            "voiceEnabled", "voiceLocale", "voiceHermesLane", "voiceTTSEnabled", "voiceDuckMedia",
            "voiceHotkey", "voiceSpeechProvider", "voiceAnswersProvider", "voiceReplyProvider",
            "voiceAIBaseURL", "voiceAISTTModel", "voiceAIChatModel", "voiceAITTSModel", "voiceAITTSVoice",
            "voiceAILanguage", "voiceAnthropicBaseURL", "voiceAnthropicModel", "voiceAgentToolsEnabled"
        ]
        XCTAssertEqual(Set(SettingsStore.Key.allCases.map(\.rawValue)), expected)
    }

    @MainActor
    func testFreshStoreStampsCurrentSchemaVersion() {
        _ = SettingsStore(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), SettingsStore.currentSchemaVersion)
    }

    @MainActor
    func testMigrationFreezesLegacyStuckProcessValueAndIsIdempotent() {
        defaults.set(false, forKey: "notifyAgentNeedsYou")
        let first = SettingsStore(defaults: defaults)
        XCTAssertFalse(first.notifyStuckProcess)
        XCTAssertEqual(defaults.object(forKey: "notifyStuckProcess") as? Bool, false)

        // A later change to the agent toggle must not leak into the now-independent key.
        first.notifyAgentNeedsYou = true
        let second = SettingsStore(defaults: defaults)
        XCTAssertTrue(second.notifyAgentNeedsYou)
        XCTAssertFalse(second.notifyStuckProcess)
    }

    @MainActor
    func testMigrationLeavesExplicitStuckProcessValueAlone() {
        defaults.set(false, forKey: "notifyAgentNeedsYou")
        defaults.set(true, forKey: "notifyStuckProcess")
        XCTAssertTrue(SettingsStore(defaults: defaults).notifyStuckProcess)
    }

    @MainActor
    func testMigrationPreservesExistingStoredValues() {
        defaults.set(false, forKey: "trayEnabled")
        defaults.set("alwaysOn", forKey: "pillMode")
        defaults.set(333.0, forKey: "expandedWidth")
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.trayEnabled)
        XCTAssertEqual(store.pillMode, .alwaysOn)
        XCTAssertEqual(store.expandedWidth, 333)
    }

    @MainActor
    func testMigrationCopiesAnEnabledLegacyAgentToggle() {
        defaults.set(true, forKey: "notifyAgentNeedsYou")
        _ = SettingsStore(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: "notifyStuckProcess") as? Bool, true)
    }

    @MainActor
    func testMigrationWithoutALegacyValueLeavesTheKeyUnsetAndStampsTheVersion() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "notifyStuckProcess"))
        XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), SettingsStore.currentSchemaVersion)
        XCTAssertTrue(store.notifyStuckProcess, "documented default")
    }

    @MainActor
    func testExplicitVersionZeroAndGarbageVersionBothMigrate() {
        defaults.set(0, forKey: "schemaVersion")
        defaults.set(false, forKey: "notifyAgentNeedsYou")
        SettingsStore.migrate(defaults)
        XCTAssertEqual(defaults.object(forKey: "notifyStuckProcess") as? Bool, false)
        XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), SettingsStore.currentSchemaVersion)

        // A non-integer stored version is treated as "never versioned", not as "newer".
        defaults.removeObject(forKey: "notifyStuckProcess")
        defaults.set("garbage", forKey: "schemaVersion")
        SettingsStore.migrate(defaults)
        XCTAssertEqual(defaults.object(forKey: "notifyStuckProcess") as? Bool, false)
        XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), SettingsStore.currentSchemaVersion)
    }

    @MainActor
    func testMigrationDoesNotRerunOnceTheCurrentVersionIsStamped() {
        defaults.set(false, forKey: "notifyAgentNeedsYou")
        SettingsStore.migrate(defaults)
        XCTAssertEqual(defaults.object(forKey: "notifyStuckProcess") as? Bool, false)

        // The two toggles are independent from here on; a second pass must not re-sync them.
        defaults.set(true, forKey: "notifyStuckProcess")
        defaults.set(false, forKey: "notifyAgentNeedsYou")
        SettingsStore.migrate(defaults)
        XCTAssertEqual(defaults.object(forKey: "notifyStuckProcess") as? Bool, true)

        defaults.removeObject(forKey: "notifyStuckProcess")
        SettingsStore.migrate(defaults)
        XCTAssertNil(defaults.object(forKey: "notifyStuckProcess"), "stamped stores are skipped entirely")
    }

    @MainActor
    func testNewerSchemaVersionIsNotDowngraded() {
        defaults.set(SettingsStore.currentSchemaVersion + 5, forKey: "schemaVersion")
        defaults.set(false, forKey: "notifyAgentNeedsYou")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), SettingsStore.currentSchemaVersion + 5)
        // Migrations did not run, so the stuck-process key is still unset and falls to its default.
        XCTAssertNil(defaults.object(forKey: "notifyStuckProcess"))
        XCTAssertTrue(store.notifyStuckProcess)
    }

    // MARK: New settings

    @MainActor
    func testCheckForUpdatesPersists() {
        let store = SettingsStore(defaults: defaults)
        store.checkForUpdates = false
        XCTAssertFalse(SettingsStore(defaults: defaults).checkForUpdates)
    }

    @MainActor
    func testPillDisplayPersistsAndNormalizesBlankToAutomatic() {
        let store = SettingsStore(defaults: defaults)
        store.pillDisplay = "display-ABC-123"
        XCTAssertEqual(store.pillDisplayIdentifier, "display-ABC-123")
        XCTAssertEqual(SettingsStore(defaults: defaults).pillDisplay, "display-ABC-123")

        store.pillDisplay = "   "
        XCTAssertEqual(store.pillDisplay, SettingsStore.automaticPillDisplay)
        XCTAssertNil(store.pillDisplayIdentifier)
        XCTAssertEqual(SettingsStore(defaults: defaults).pillDisplay, SettingsStore.automaticPillDisplay)
    }

    // MARK: Export / import / reset

    private func decodedSettings(_ data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["settings"] as? [String: Any])
    }

    @MainActor
    func testExportContainsOnlyAllowlistedPreferences() throws {
        let store = SettingsStore(defaults: defaults)
        store.setNotificationApp("Signal", muted: true)
        store.pillDisplay = "some-display"
        store.hasSeenOnboarding = true

        let data = try store.exportJSON()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["app"] as? String, "desnotch")
        XCTAssertEqual(root["schemaVersion"] as? Int, SettingsStore.currentSchemaVersion)

        let settings = try decodedSettings(data)
        XCTAssertEqual(Set(settings.keys), Set(SettingsStore.exportedKeyNames))
        for excluded in ["mutedNotificationApps", "pillDisplay", "hasSeenOnboarding", "schemaVersion"] {
            XCTAssertNil(settings[excluded], "\(excluded) must not be exported")
        }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Signal"))
        XCTAssertFalse(text.lowercased().contains("signal"))
        XCTAssertFalse(text.contains("some-display"))
    }

    @MainActor
    func testExportImportRoundTripsIntoAFreshStore() throws {
        let source = SettingsStore(defaults: defaults)
        source.pillMode = .alwaysOn
        source.musicIndicatorStyle = .albumArt
        source.animationStyle = .minimal
        source.hoverCollapseDelay = 2.5
        source.minimizedWidth = 250
        source.minimizedHeight = 36
        source.expandedWidth = 400
        source.trayEnabled = false
        source.privacyModeEnabled = true
        source.checkForUpdates = false
        source.notifyStuckProcess = false
        let data = try source.exportJSON()

        let otherSuite = "desnotch.tests.settings.other"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        otherDefaults.removePersistentDomain(forName: otherSuite)
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }

        let target = SettingsStore(defaults: otherDefaults)
        let report = try target.importJSON(data)
        XCTAssertEqual(report.rejected, [])
        XCTAssertEqual(Set(report.applied), Set(SettingsStore.exportedKeyNames))

        XCTAssertEqual(target.pillMode, .alwaysOn)
        XCTAssertEqual(target.musicIndicatorStyle, .albumArt)
        XCTAssertEqual(target.animationStyle, .minimal)
        XCTAssertEqual(target.hoverCollapseDelay, 2.5)
        XCTAssertEqual(target.minimizedWidth, 250)
        XCTAssertEqual(target.minimizedHeight, 36)
        XCTAssertEqual(target.expandedWidth, 400)
        XCTAssertFalse(target.trayEnabled)
        XCTAssertTrue(target.privacyModeEnabled)
        XCTAssertFalse(target.checkForUpdates)
        XCTAssertFalse(target.notifyStuckProcess)
        // Imported values are persisted, not just held in memory.
        XCTAssertEqual(SettingsStore(defaults: otherDefaults).expandedWidth, 400)
    }

    @MainActor
    func testImportRejectsUnknownKeysAndWrongTypesButAppliesTheRest() throws {
        let store = SettingsStore(defaults: defaults)
        let payload: [String: Any] = [
            "app": "desnotch",
            "schemaVersion": 1,
            "settings": [
                "trayEnabled": false,                // valid
                "nowPlayingEnabled": 1,              // number is not a boolean
                "pillMode": "sideways",              // not an allowed choice
                "expandedWidth": "wide",             // string is not a number
                "hoverCollapseDelay": true,          // boolean is not a number
                "hasSeenOnboarding": true,           // not on the allowlist
                "pillDisplay": "external",           // not on the allowlist
                "mutedNotificationApps": ["slack"],  // not on the allowlist
                "totallyUnknown": 3
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let report = try store.importJSON(data)

        XCTAssertEqual(report.applied, ["trayEnabled"])
        XCTAssertEqual(
            Set(report.rejected),
            ["nowPlayingEnabled", "pillMode", "expandedWidth", "hoverCollapseDelay",
             "hasSeenOnboarding", "pillDisplay", "mutedNotificationApps", "totallyUnknown"]
        )
        XCTAssertFalse(store.trayEnabled)
        XCTAssertTrue(store.nowPlayingEnabled)
        XCTAssertEqual(store.pillMode, .hoverAuto)
        XCTAssertEqual(store.expandedWidth, SettingsStore.defaultExpandedWidth)
        XCTAssertEqual(store.hoverCollapseDelay, SettingsStore.defaultHoverCollapseDelay)
        XCTAssertFalse(store.hasSeenOnboarding)
        XCTAssertEqual(store.pillDisplay, SettingsStore.automaticPillDisplay)
        XCTAssertTrue(store.mutedNotificationApps.isEmpty)
    }

    @MainActor
    func testImportClampsOutOfRangeNumbers() throws {
        let store = SettingsStore(defaults: defaults)
        let payload: [String: Any] = ["settings": ["expandedWidth": 99_999, "hoverCollapseDelay": -4]]
        let report = try store.importJSON(JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(Set(report.applied), ["expandedWidth", "hoverCollapseDelay"])
        XCTAssertEqual(store.expandedWidth, SettingsStore.expandedWidthRange.upperBound)
        XCTAssertEqual(store.hoverCollapseDelay, SettingsStore.hoverCollapseDelayRange.lowerBound)
    }

    @MainActor
    func testImportRejectsMalformedDocuments() throws {
        let store = SettingsStore(defaults: defaults)
        XCTAssertThrowsError(try store.importJSON(Data("not json".utf8))) {
            XCTAssertEqual($0 as? SettingsStore.ImportError, .notSettingsFile)
        }
        XCTAssertThrowsError(try store.importJSON(Data("[1,2,3]".utf8))) {
            XCTAssertEqual($0 as? SettingsStore.ImportError, .notSettingsFile)
        }
        XCTAssertThrowsError(try store.importJSON(Data("{\"trayEnabled\":false}".utf8))) {
            XCTAssertEqual($0 as? SettingsStore.ImportError, .notSettingsFile)
        }
        XCTAssertThrowsError(try store.importJSON(Data("{\"app\":\"other\",\"settings\":{}}".utf8))) {
            XCTAssertEqual($0 as? SettingsStore.ImportError, .notSettingsFile)
        }
        XCTAssertThrowsError(try store.importJSON(Data("{\"schemaVersion\":\"1\",\"settings\":{}}".utf8))) {
            XCTAssertEqual($0 as? SettingsStore.ImportError, .notSettingsFile)
        }
        let future = SettingsStore.currentSchemaVersion + 1
        XCTAssertThrowsError(try store.importJSON(Data("{\"schemaVersion\":\(future),\"settings\":{\"trayEnabled\":false}}".utf8))) {
            XCTAssertEqual($0 as? SettingsStore.ImportError, .newerSchema(future))
        }
        XCTAssertTrue(store.trayEnabled, "a refused import changes nothing")

        let oversized = Data(repeating: 0x20, count: SettingsStore.maxImportBytes + 1)
        XCTAssertThrowsError(try store.importJSON(oversized)) {
            XCTAssertEqual($0 as? SettingsStore.ImportError, .tooLarge)
        }
    }

    @MainActor
    func testResetToDefaultsMatchesAFreshStoreAndKeepsOnboardingState() throws {
        let store = SettingsStore(defaults: defaults)
        store.pillMode = .alwaysOn
        store.musicIndicatorStyle = .equalizer
        store.animationStyle = .dynamic
        store.hoverCollapseDelay = 3
        store.minimizedWidth = 300
        store.minimizedHeight = 40
        store.expandedWidth = 450
        store.trayEnabled = false
        store.remindersEnabled = true
        store.privacyModeEnabled = true
        store.checkForUpdates = false
        store.pillDisplay = "external"
        store.setNotificationApp("Mail", muted: true)
        store.hasSeenOnboarding = true

        store.resetToDefaults()

        let otherSuite = "desnotch.tests.settings.fresh"
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        freshDefaults.removePersistentDomain(forName: otherSuite)
        defer { freshDefaults.removePersistentDomain(forName: otherSuite) }
        let fresh = SettingsStore(defaults: freshDefaults)

        XCTAssertEqual(try decodedSettings(store.exportJSON()) as NSDictionary,
                       try decodedSettings(fresh.exportJSON()) as NSDictionary)
        XCTAssertEqual(store.pillDisplay, SettingsStore.automaticPillDisplay)
        XCTAssertTrue(store.mutedNotificationApps.isEmpty)
        XCTAssertTrue(store.hasSeenOnboarding, "a reset must not replay the onboarding guide")

        // And it is persisted.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.pillMode, .hoverAuto)
        XCTAssertTrue(reloaded.checkForUpdates)
        XCTAssertTrue(reloaded.mutedNotificationApps.isEmpty)
    }

    // MARK: Injected settings

    @MainActor
    func testCalendarControllerHonorsInjectedSettings() {
        let store = SettingsStore(defaults: defaults)
        store.calendarEnabled = false
        // Disabled in the injected store: no permission request, no event, regardless of the
        // process-wide shared store's state.
        let controller = CalendarController(permissionRequestsEnabled: true, settings: store)
        XCTAssertEqual(controller.accessState, .undetermined)
        XCTAssertNil(controller.nextEvent)
    }

    @MainActor
    func testRemindersControllerHonorsInjectedSettings() {
        let store = SettingsStore(defaults: defaults)
        store.remindersEnabled = false
        let controller = RemindersController(permissionRequestsEnabled: true, settings: store)
        XCTAssertEqual(controller.accessState, .undetermined)
        XCTAssertNil(controller.nextReminder)
    }
}
