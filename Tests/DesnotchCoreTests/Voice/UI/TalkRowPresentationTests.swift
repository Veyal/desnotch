import XCTest
@testable import DesnotchCore

@MainActor
final class TalkRowPresentationTests: XCTestCase {
    private let ready = VoicePermissionStatus(microphone: .authorized, speech: .authorized)

    private func resolve(
        enabled: Bool = true,
        handler: Bool = true,
        state: VoiceState = .idle,
        permissions: VoicePermissionStatus? = nil,
        hotkey: VoiceHotkeyChoice = .optionCommandV,
        status: PushToTalkStatus = .active
    ) -> TalkRowPresentation {
        TalkRowPresentation.resolve(
            voiceEnabled: enabled, hasHandler: handler, state: state,
            permissions: permissions ?? ready, hotkey: hotkey, hotkeyStatus: status
        )
    }

    func testHiddenWhenVoiceIsDisabled() {
        XCTAssertEqual(resolve(enabled: false), .hidden)
        XCTAssertFalse(resolve(enabled: false).isVisible)
    }

    func testHiddenWhenNothingHandlesTheTap() {
        XCTAssertEqual(resolve(handler: false), .hidden)
    }

    func testVisibleWhenEnabledAndIdleWithTheConfiguredShortcut() {
        let row = resolve()
        XCTAssertEqual(row, .talk(shortcut: "⌥⌘V"))
        XCTAssertEqual(row.title, "Talk")
        XCTAssertEqual(row.caption, "⌥⌘V")
        XCTAssertEqual(row.accessibilityHint, "Start voice command")
        XCTAssertEqual(resolve(hotkey: .shiftOptionCommandV).caption, "⌥⇧⌘V")
        XCTAssertEqual(resolve(hotkey: .optionCommandJ).caption, "⌥⌘J")
    }

    func testShortcutCaptionIsDroppedWhileTheKeyIsNotRegistered() {
        let row = resolve(status: .unavailable)
        XCTAssertEqual(row, .talk(shortcut: nil))
        XCTAssertNil(row.caption)
    }

    func testHiddenWhileTheVoiceSectionIsShown() {
        for state in VoiceState.allCases where state != .idle {
            XCTAssertEqual(resolve(state: state), .hidden, "\(state)")
        }
    }

    func testPermissionVariantWhenAccessWasNeverAsked() {
        let notAsked = VoicePermissionStatus(microphone: .notDetermined, speech: .authorized)
        let row = resolve(permissions: notAsked)
        XCTAssertEqual(row, .allowAccess)
        XCTAssertEqual(row.title, "Allow voice access")
        XCTAssertNil(row.caption)
        XCTAssertEqual(resolve(permissions: VoicePermissionStatus(microphone: .authorized, speech: .notDetermined)), .allowAccess)
    }

    func testUnknownAndDeniedPermissionsStillOfferTalk() {
        XCTAssertEqual(resolve(permissions: .unknown), .talk(shortcut: "⌥⌘V"))
        let denied = VoicePermissionStatus(microphone: .denied, speech: .authorized)
        XCTAssertEqual(resolve(permissions: denied), .talk(shortcut: "⌥⌘V"))
    }

    func testTapCallsToggleTalkOrRequestPermissions() {
        let model = VoiceSessionModel()
        var toggles = 0
        var requests = 0
        model.actions.toggleTalk = { toggles += 1 }
        model.actions.requestPermissions = { requests += 1 }
        TalkRowPresentation.talk(shortcut: "⌥⌘V").perform(on: model)
        XCTAssertEqual([toggles, requests], [1, 0])
        TalkRowPresentation.allowAccess.perform(on: model)
        XCTAssertEqual([toggles, requests], [1, 1])
        TalkRowPresentation.hidden.perform(on: model)
        XCTAssertEqual([toggles, requests], [1, 1])
    }
}
