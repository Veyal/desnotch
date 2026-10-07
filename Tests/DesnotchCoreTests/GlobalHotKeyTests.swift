import Carbon.HIToolbox
import XCTest
@testable import DesnotchCore

private final class FakeHotKeyRegistrar: HotKeyRegistering {
    var succeeds = true
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var registered: HotKeyBinding?
    private var action: (() -> Void)?

    func register(_ binding: HotKeyBinding, action: @escaping () -> Void) -> Bool {
        registerCount += 1
        guard succeeds else { return false }
        registered = binding
        self.action = action
        return true
    }

    func unregister() {
        unregisterCount += 1
        registered = nil
        action = nil
    }

    func press() { action?() }
}

final class GlobalHotKeyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "desnotch.tests.hotkey.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultBindingIsOptionCommandN() {
        let binding = HotKeyBinding.default
        XCTAssertEqual(binding.keyCode, UInt32(kVK_ANSI_N))
        XCTAssertEqual(binding.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(binding.displayString, "⌥⌘N")
        XCTAssertEqual(binding.menuModifierMask, [.option, .command])
    }

    @MainActor
    func testStaysOffWhileTheSettingIsOff() {
        let settings = SettingsStore(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let controller = GlobalHotKeyController(
            settings: settings, binding: .default, registrar: registrar, onTrigger: {}
        )
        XCTAssertEqual(controller.status, .off)
        XCTAssertNil(registrar.registered)
    }

    @MainActor
    func testRegistersOnlyWhileEnabled() {
        let settings = SettingsStore(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let controller = GlobalHotKeyController(
            settings: settings, binding: .default, registrar: registrar, onTrigger: {}
        )

        settings.globalHotkeyEnabled = true
        XCTAssertEqual(controller.status, .active)
        XCTAssertEqual(registrar.registered, .default)

        settings.globalHotkeyEnabled = false
        XCTAssertEqual(controller.status, .off)
        XCTAssertNil(registrar.registered)
    }

    @MainActor
    func testEnabledAtLaunchRegistersImmediately() {
        defaults.set(true, forKey: "globalHotkeyEnabled")
        let settings = SettingsStore(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let controller = GlobalHotKeyController(
            settings: settings, binding: .default, registrar: registrar, onTrigger: {}
        )
        XCTAssertEqual(controller.status, .active)
        XCTAssertEqual(registrar.registerCount, 1)
    }

    @MainActor
    func testRefusedRegistrationIsReportedAsUnavailable() {
        let settings = SettingsStore(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        registrar.succeeds = false
        let controller = GlobalHotKeyController(
            settings: settings, binding: .default, registrar: registrar, onTrigger: {}
        )
        settings.globalHotkeyEnabled = true
        XCTAssertEqual(controller.status, .unavailable)
    }

    @MainActor
    func testPressingTheShortcutTriggersTheAction() {
        let settings = SettingsStore(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        var triggers = 0
        let controller = GlobalHotKeyController(
            settings: settings, binding: .default, registrar: registrar, onTrigger: { triggers += 1 }
        )
        settings.globalHotkeyEnabled = true
        registrar.press()
        XCTAssertEqual(triggers, 1)
        withExtendedLifetime(controller) {}
    }

    @MainActor
    func testStopReleasesTheShortcutAndIgnoresLaterSettingChanges() {
        let settings = SettingsStore(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        let controller = GlobalHotKeyController(
            settings: settings, binding: .default, registrar: registrar, onTrigger: {}
        )
        settings.globalHotkeyEnabled = true
        controller.stop()
        XCTAssertEqual(controller.status, .off)
        XCTAssertNil(registrar.registered)

        settings.globalHotkeyEnabled = false
        settings.globalHotkeyEnabled = true
        XCTAssertNil(registrar.registered)
    }
}
