import XCTest
@testable import DesnotchCore

/// Uses an isolated UserDefaults suite, like `SettingsStoreTests`.
final class VoiceAISettingsTests: XCTestCase {
    private let suiteName = "desnotch.tests.voice-ai-settings"
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

    @MainActor
    func testDefaultsKeepEverythingOnDevice() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.voiceEnabled)
        XCTAssertFalse(store.voiceHermesLane)
        XCTAssertFalse(store.voiceTTSEnabled)
        XCTAssertEqual(store.voiceSpeechProvider, .onDevice)
        XCTAssertEqual(store.voiceAnswersProvider, .hermes)
        XCTAssertEqual(store.voiceReplyProvider, .system)
        XCTAssertEqual(store.voiceAIBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(store.voiceAISTTModel, "gpt-4o-mini-transcribe")
        XCTAssertEqual(store.voiceAIChatModel, "gpt-4o-mini")
        XCTAssertEqual(store.voiceAITTSModel, "gpt-4o-mini-tts")
        XCTAssertEqual(store.voiceAITTSVoice, "alloy")
        XCTAssertEqual(store.voiceAILanguage, "")
        XCTAssertEqual(store.voiceAnthropicBaseURL, "https://api.anthropic.com")
        XCTAssertEqual(store.voiceAnthropicModel, "claude-haiku-4-5")
    }

    @MainActor
    func testValuesAreNormalizedOnWriteAndPersist() {
        let store = SettingsStore(defaults: defaults)
        store.voiceAIBaseURL = "  http://localhost:1234/v1/// "
        XCTAssertEqual(store.voiceAIBaseURL, "http://localhost:1234/v1")
        store.voiceAIChatModel = "llama 3.1\n\"x\""
        XCTAssertEqual(store.voiceAIChatModel, "llama3.1x")
        store.voiceAILanguage = "id; DROP"
        XCTAssertEqual(store.voiceAILanguage, "idDROP")
        store.voiceAILanguage = "pt-BR"
        store.voiceAIBaseURL = String(repeating: "a", count: 2_000)
        XCTAssertEqual(store.voiceAIBaseURL.count, VoiceAIDefaults.maxBaseURLLength)
        store.voiceAIBaseURL = ""
        store.voiceSpeechProvider = .openAICompatible
        store.voiceAnswersProvider = .anthropic
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.voiceAILanguage, "pt-BR")
        XCTAssertEqual(reloaded.voiceAIChatModel, "llama3.1x")
        XCTAssertEqual(reloaded.voiceSpeechProvider, .openAICompatible)
        XCTAssertEqual(reloaded.voiceAnswersProvider, .anthropic)
        XCTAssertEqual(VoiceAIConfig(settings: reloaded).baseURL, "https://api.openai.com/v1", "empty means the default")
        XCTAssertEqual(VoiceAIConfig(settings: reloaded).chatProvider, .anthropic)
    }

    @MainActor
    func testUnknownStoredProviderFallsBackToTheDefault() {
        defaults.set("cloudOnly", forKey: SettingsStore.Key.voiceSpeechProvider.rawValue)
        defaults.set("gemini", forKey: SettingsStore.Key.voiceAnswersProvider.rawValue)
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.voiceSpeechProvider, .onDevice)
        XCTAssertEqual(store.voiceAnswersProvider, .hermes)
    }

    @MainActor
    func testKeyAndBaseURLNeverReachDefaultsOrExport() throws {
        let store = SettingsStore(defaults: defaults)
        let keys = AIMemoryKeyStore()
        XCTAssertTrue(keys.saveKey("sk-live-secret-123", for: "private-gateway.example.test:443"))
        store.voiceAIBaseURL = "https://private-gateway.example.test/v1"
        store.voiceAnthropicBaseURL = "https://anthropic-proxy.example.test"
        store.voiceSpeechProvider = .openAICompatible
        let stored = defaults.persistentDomain(forName: suiteName) ?? [:]
        for value in stored.values {
            XCTAssertFalse("\(value)".contains("sk-live-secret-123"))
        }
        let export = String(decoding: try store.exportJSON(), as: UTF8.self)
        XCTAssertFalse(export.contains("sk-live-secret-123"))
        XCTAssertFalse(export.contains("private-gateway"))
        XCTAssertFalse(export.contains("anthropic-proxy"))
        for name in SettingsStore.exportedKeyNames {
            XCTAssertFalse(name.hasPrefix("voice"), name)
        }
    }

    @MainActor
    func testImportCannotSetProviderSettings() throws {
        let store = SettingsStore(defaults: defaults)
        let document: [String: Any] = [
            "app": "desnotch",
            "settings": [
                "voiceAIBaseURL": "https://attacker.example.test/v1",
                "voiceSpeechProvider": "openAICompatible",
                "voiceAnswersProvider": "anthropic"
            ]
        ]
        let report = try store.importJSON(JSONSerialization.data(withJSONObject: document))
        XCTAssertEqual(Set(report.rejected), ["voiceAIBaseURL", "voiceSpeechProvider", "voiceAnswersProvider"])
        XCTAssertEqual(store.voiceAIBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(store.voiceSpeechProvider, .onDevice)
    }

    @MainActor
    func testResetRestoresProviderDefaults() {
        let store = SettingsStore(defaults: defaults)
        store.voiceSpeechProvider = .openAICompatible
        store.voiceAnswersProvider = .openAICompatible
        store.voiceReplyProvider = .openAICompatible
        store.voiceAIBaseURL = "http://localhost:1/v1"
        store.voiceAnthropicModel = "claude-x"
        store.resetToDefaults()
        XCTAssertEqual(store.voiceSpeechProvider, .onDevice)
        XCTAssertEqual(store.voiceAnswersProvider, .hermes)
        XCTAssertEqual(store.voiceReplyProvider, .system)
        XCTAssertEqual(store.voiceAIBaseURL, SettingsStore.defaultVoiceAIBaseURL)
        XCTAssertEqual(store.voiceAnthropicModel, SettingsStore.defaultVoiceAnthropicModel)
    }

    @MainActor
    func testAgentToolsSwitchIsOffByDefaultPersistsResetsAndNeverImports() throws {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.voiceAgentToolsEnabled)
        XCTAssertFalse(VoiceAIConfig(settings: store).agentToolsEnabled)
        XCTAssertFalse(VoiceAIConfig().agentToolsEnabled)
        store.voiceAgentToolsEnabled = true
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.voiceAgentToolsEnabled)
        XCTAssertTrue(VoiceAIConfig(settings: reloaded).agentToolsEnabled)
        reloaded.resetToDefaults()
        XCTAssertFalse(reloaded.voiceAgentToolsEnabled)
        let document: [String: Any] = ["app": "desnotch", "settings": ["voiceAgentToolsEnabled": true]]
        let report = try reloaded.importJSON(JSONSerialization.data(withJSONObject: document))
        XCTAssertEqual(report.rejected, ["voiceAgentToolsEnabled"])
        XCTAssertFalse(reloaded.voiceAgentToolsEnabled)
    }

    func testAgentToolsSwitchShowsOnlyForProviderAnswers() {
        XCTAssertTrue(VoiceAISettingsWords.showsAgentTools(.openAICompatible))
        XCTAssertTrue(VoiceAISettingsWords.showsAgentTools(.anthropic))
        XCTAssertFalse(VoiceAISettingsWords.showsAgentTools(.hermes))
        XCTAssertFalse(VoiceAISettingsWords.showsAgentTools(.off))
        XCTAssertEqual(VoiceAISettingsWords.agentToolsTitle, "Let the agent control this Mac")
    }

    func testAnswersChoiceFoldsTheLaneSwitchAndProvider() {
        XCTAssertEqual(VoiceAnswersChoice.resolve(laneOn: false, provider: .anthropic), .off)
        XCTAssertEqual(VoiceAnswersChoice.resolve(laneOn: true, provider: .hermes), .hermes)
        XCTAssertEqual(VoiceAnswersChoice.resolve(laneOn: true, provider: .openAICompatible), .openAICompatible)
        XCTAssertEqual(VoiceAnswersChoice.resolve(laneOn: true, provider: .anthropic), .anthropic)
        XCTAssertTrue(VoiceAnswersChoice.off.stored(keeping: .anthropic) == (false, .anthropic))
        XCTAssertTrue(VoiceAnswersChoice.openAICompatible.stored(keeping: .hermes) == (true, .openAICompatible))
        XCTAssertTrue(VoiceAnswersChoice.anthropic.stored(keeping: .hermes) == (true, .anthropic))
    }

    func testSettingsWordsNeverEchoSecrets() {
        XCTAssertNil(VoiceAISettingsWords.endpointNote(""))
        XCTAssertNil(VoiceAISettingsWords.endpointNote("https://api.openai.com/v1"))
        XCTAssertEqual(VoiceAISettingsWords.endpointNote("http://10.0.0.2/v1"), VoiceAISettingsWords.endpointInvalidNote)
        XCTAssertEqual(VoiceAISettingsWords.keyStatus(bound: "api.openai.com:443", current: "api.openai.com:443"), "Key saved for api.openai.com")
        XCTAssertEqual(
            VoiceAISettingsWords.keyStatus(bound: "api.openai.com:443", current: "api.groq.com:443"),
            "Key saved for api.openai.com — re-enter for this host"
        )
        XCTAssertEqual(VoiceAISettingsWords.keyStatus(bound: nil, current: "localhost:1234"), "No key saved")
        XCTAssertEqual(VoiceAISettingsWords.keyStatus(bound: "localhost:1234", current: nil), "Fix the base URL to save a key")
        XCTAssertEqual(VoiceAISettingsWords.hostLabel("localhost:1234"), "localhost:1234")
        XCTAssertTrue(VoiceAISettingsWords.anthropicNote.contains("no speech API"))
        XCTAssertEqual(VoiceAISettingsWords.answersLabel(.anthropic), "Claude (Anthropic)")
    }

    func testKeychainServicesAreSeparate() {
        XCTAssertEqual(KeychainVoiceAIKeyStore.service, "com.desnotch.app.voice-ai")
        XCTAssertEqual(KeychainVoiceAIKeyStore.anthropicService, "com.desnotch.app.voice-ai.anthropic")
        XCTAssertEqual(KeychainVoiceAIKeyStore().service, KeychainVoiceAIKeyStore.service)
    }

    func testCloudBadgeNamesTheProviderOrSaysCloud() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let speech = VoiceSectionPresentation(
            VoiceSectionSnapshot(state: .transcribing, usesCloud: true), privacyMode: false, now: now
        )
        XCTAssertTrue(speech.showsCloudBadge)
        XCTAssertEqual(speech.cloudBadgeLabel, "Cloud")
        XCTAssertTrue(speech.accessibilityLabel.contains("uses the cloud AI provider"))
        let claude = VoiceSectionPresentation(
            VoiceSectionSnapshot(state: .thinking, lane: .hermes, usesCloud: true, agentName: "Claude"),
            privacyMode: false, now: now
        )
        XCTAssertEqual(claude.cloudBadgeLabel, "Claude")
        XCTAssertTrue(claude.accessibilityLabel.contains("sent to the Claude cloud agent"))
        let local = VoiceSectionPresentation(VoiceSectionSnapshot(state: .acting, lane: .local), privacyMode: false, now: now)
        XCTAssertFalse(local.showsCloudBadge)
    }

    @MainActor
    func testModelCloudFlagAndAgentNameDriveBadgeAndSummary() {
        let model = VoiceSessionModel()
        XCTAssertFalse(model.usesCloud)
        model.setCloudActivity(true)
        XCTAssertTrue(model.usesCloud)
        model.setAgentName(VoiceSessionModel.providerAgentName)
        XCTAssertEqual(VoiceSessionModel.summary(of: .remote(utterance: "x"), agentName: model.agentName), "Send to AI provider (cloud)")
        XCTAssertEqual(VoiceSessionModel.summary(of: .remote(utterance: "x")), "Send to Hermes (cloud)")
    }
}
