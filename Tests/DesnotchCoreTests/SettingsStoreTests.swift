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
        XCTAssertEqual(store.transcriptionBaseURL, SettingsStore.defaultTranscriptionBaseURL)
        XCTAssertEqual(store.transcriptionModel, SpeechTranscriptionClient.defaultModel)
        XCTAssertEqual(store.agentBackend, .codexCLI)
        XCTAssertEqual(store.agentWorkingDirectory, NSHomeDirectory())
        XCTAssertFalse(store.agentAutoRunReadOnly)
        XCTAssertEqual(store.agentCommandTimeout, SettingsStore.defaultAgentCommandTimeout)
        XCTAssertEqual(store.agentOutputLimitKB, SettingsStore.defaultAgentOutputLimitKB)
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
        store.transcriptionBaseURL = "https://speech.example/v1"
        store.transcriptionModel = "custom-transcribe"
        store.agentWorkingDirectory = "/tmp"
        store.agentAutoRunReadOnly = true
        store.agentCommandTimeout = 45
        store.agentOutputLimitKB = 64

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.pillMode, .alwaysOn)
        XCTAssertEqual(reloaded.hoverCollapseDelay, 1.5)
        XCTAssertEqual(reloaded.minimizedWidth, 240)
        XCTAssertEqual(reloaded.minimizedHeight, 34)
        XCTAssertEqual(reloaded.expandedWidth, 360)
        XCTAssertFalse(reloaded.trayEnabled)
        XCTAssertEqual(reloaded.transcriptionBaseURL, "https://speech.example/v1")
        XCTAssertEqual(reloaded.transcriptionModel, "custom-transcribe")
        XCTAssertEqual(reloaded.agentWorkingDirectory, "/tmp")
        XCTAssertTrue(reloaded.agentAutoRunReadOnly)
        XCTAssertEqual(reloaded.agentCommandTimeout, 45)
        XCTAssertEqual(reloaded.agentOutputLimitKB, 64)
        XCTAssertNil(defaults.string(forKey: "apiKey"))
        XCTAssertNil(defaults.string(forKey: "openAIAPIKey"))
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
        store.agentCommandTimeout = 1
        XCTAssertEqual(store.agentCommandTimeout, SettingsStore.agentCommandTimeoutRange.lowerBound)
        store.agentOutputLimitKB = 10_000
        XCTAssertEqual(store.agentOutputLimitKB, SettingsStore.agentOutputLimitKBRange.upperBound)
        store.transcriptionBaseURL = String(repeating: "x", count: 600)
        XCTAssertEqual(store.transcriptionBaseURL.count, 512)
        store.transcriptionModel = "   "
        XCTAssertEqual(store.transcriptionModel, SettingsStore.defaultTranscriptionModel)

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
}
