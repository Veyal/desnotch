import SwiftUI

/// Preference key used to report the pill's natural (laid-out) content size up to the
/// `NSPanel` owner so the panel can be resized to fit content + shadow room instead of
/// staying a fixed 300x44 that clips the expanded pill.
struct PillContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}
