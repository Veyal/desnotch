import SwiftUI

/// Preference key used to report the pill's natural (laid-out) content size up to the
/// `NSPanel` owner so the panel can be resized to fit content + shadow room instead of
/// staying a fixed 300x44 that clips the expanded pill.
struct PillContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PillContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
