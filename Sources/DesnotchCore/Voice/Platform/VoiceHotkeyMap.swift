import Carbon.HIToolbox
import Foundation

enum VoiceHotkeyMap {
    static func binding(for choice: VoiceHotkeyChoice) -> HotKeyBinding {
        switch choice {
        case .optionCommandV:
            return HotKeyBinding(
                keyCode: UInt32(kVK_ANSI_V),
                carbonModifiers: UInt32(cmdKey | optionKey),
                keyLabel: "V"
            )
        case .shiftOptionCommandV:
            return HotKeyBinding(
                keyCode: UInt32(kVK_ANSI_V),
                carbonModifiers: UInt32(cmdKey | optionKey | shiftKey),
                keyLabel: "V"
            )
        case .optionCommandJ:
            return HotKeyBinding(
                keyCode: UInt32(kVK_ANSI_J),
                carbonModifiers: UInt32(cmdKey | optionKey),
                keyLabel: "J"
            )
        }
    }
}
