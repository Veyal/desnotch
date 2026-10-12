import Carbon.HIToolbox
import XCTest
@testable import DesnotchCore

final class VoiceHotkeyMapTests: XCTestCase {
    func testDisplayStringsMatchExpectedLiterals() {
        let b1 = VoiceHotkeyMap.binding(for: .optionCommandV)
        let b2 = VoiceHotkeyMap.binding(for: .shiftOptionCommandV)
        let b3 = VoiceHotkeyMap.binding(for: .optionCommandJ)

        XCTAssertEqual(b1.displayString, "⌥⌘V")
        XCTAssertEqual(b2.displayString, "⌥⇧⌘V")
        XCTAssertEqual(b3.displayString, "⌥⌘J")
    }

    func testBindingsDoNotMatchDefaultShowNotch() {
        let choices: [VoiceHotkeyChoice] = [.optionCommandV, .shiftOptionCommandV, .optionCommandJ]
        for choice in choices {
            let binding = VoiceHotkeyMap.binding(for: choice)
            XCTAssertNotEqual(binding, HotKeyBinding.default)
        }
    }

    func testBindingsDoNotUseControlKey() {
        let choices: [VoiceHotkeyChoice] = [.optionCommandV, .shiftOptionCommandV, .optionCommandJ]
        for choice in choices {
            let binding = VoiceHotkeyMap.binding(for: choice)
            XCTAssertEqual(binding.carbonModifiers & UInt32(controlKey), 0)
        }
    }

    func testBindingsArePairwiseDistinct() {
        let b1 = VoiceHotkeyMap.binding(for: .optionCommandV)
        let b2 = VoiceHotkeyMap.binding(for: .shiftOptionCommandV)
        let b3 = VoiceHotkeyMap.binding(for: .optionCommandJ)

        XCTAssertNotEqual(b1, b2)
        XCTAssertNotEqual(b1, b3)
        XCTAssertNotEqual(b2, b3)
    }
}
