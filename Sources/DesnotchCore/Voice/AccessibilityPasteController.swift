import AppKit
import ApplicationServices

public protocol AccessibilityPasting { var isTrusted: Bool { get }; func requestTrust() -> Bool; func paste(_ text: String) -> Bool }

public final class AccessibilityPasteController: AccessibilityPasting {
    public init() {}
    public var isTrusted: Bool { AXIsProcessTrusted() }
    public func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    public static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    /// Replaces the clipboard only for the paste operation, then restores its prior contents.
    @discardableResult public func paste(_ text: String) -> Bool {
        guard isTrusted, !text.isEmpty else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        guard let down, let up else { return false }
        let pasteboard = NSPasteboard.general
        let old = pasteboard.pasteboardItems?.map { item in
            (item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let temporaryChangeCount = pasteboard.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Give slower apps time to service the synthetic Cmd-V before the
        // clipboard is swapped back, or they paste the previous contents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // If the user copied something during the brief paste window, their new
            // clipboard wins; never overwrite it with our saved snapshot.
            guard pasteboard.changeCount == temporaryChangeCount else { return }
            pasteboard.clearContents()
            for entries in old { let item = NSPasteboardItem(); for (type, data) in entries { item.setData(data, forType: type) }; pasteboard.writeObjects([item]) }
        }
        return true
    }
}
