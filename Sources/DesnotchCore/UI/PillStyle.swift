import SwiftUI

/// The pill's type scale: system font only (the pill is a menu-bar utility, so legibility
/// beats personality), digits always monospaced where they change. Nothing is smaller than
/// 10pt; copy a person reads is 11pt or larger. Roles, not sizes, are what views ask for.
enum PillTextStyle: CaseIterable {
    /// Expanded timer countdown.
    case display
    /// Row titles: track, agent, event, reminder, file, app name.
    case title
    /// Secondary row line, clipboard preview, button text, battery.
    case body
    /// `body` with emphasis (labels beside a value).
    case bodyStrong
    /// Metadata, chips, time labels, captions.
    case caption
    /// Emphasised caption (chip text, section headers).
    case captionStrong
    /// Wing agent count.
    case wingCount
    /// Wing timer label.
    case wingTimer

    var size: CGFloat {
        switch self {
        case .display: return 15
        case .title: return 12
        case .body, .bodyStrong: return 11
        case .caption, .captionStrong, .wingTimer: return 10
        case .wingCount: return 12
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display, .title, .bodyStrong, .captionStrong, .wingTimer: return .semibold
        case .body, .caption: return .medium
        case .wingCount: return .bold
        }
    }

    /// Whether the role shows changing numbers (kept fixed-width so rows never jitter).
    var monospacedDigits: Bool {
        switch self {
        case .display, .wingTimer: return true
        default: return false
        }
    }

    var font: Font {
        let base = Font.system(size: size, weight: weight)
        return monospacedDigits ? base.monospacedDigit() : base
    }

    /// Floor for every role in the compact pill.
    static let minimumSize: CGFloat = 10
}

/// 8pt grid with 4pt half-steps, and the row heights built on it.
enum PillSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum PillRowHeight {
    /// Compact single-line row (battery).
    static let compact: CGFloat = 24
    /// Standard two-line row (agent, calendar, reminder).
    static let standard: CGFloat = 32
    /// Rows with a 32pt leading element (notification, focus timer).
    static let tall: CGFloat = 40
    /// Privacy row.
    static let slim: CGFloat = 28
    /// Single-line list rows (clipboard, tray, high-CPU processes): one shared height so the
    /// vertical rhythm does not change where one list meets the next.
    static let listRow: CGFloat = 24
}

/// The shared leading column of the stacked rows: every row's glyph/icon is centred in a
/// `slot`-wide cell and its title starts `gap` later, so titles share one left edge down the
/// stack. (The now-playing row keeps its larger 40pt artwork and is the one deliberate
/// exception.) Width caps for a row's title subtract `slot + gap`, never a literal glyph size.
enum PillRowLeading {
    static let slot: CGFloat = 32
    static let gap: CGFloat = PillSpace.s
    /// Distance from the content edge to the title column.
    static var titleInset: CGFloat { slot + gap }
}

enum PillRadius {
    static let chip: CGFloat = 6
    static let control: CGFloat = 8
    static let row: CGFloat = 10
    static let section: CGFloat = 12
}

/// How many rows each list section shows before collapsing the rest into a caption. Bounding
/// them keeps the expanded stack well inside the panel's fixed 720pt floor, so a long list can
/// never force an AppKit resize while the pill animates.
enum PillLimits {
    static let agentRows = 4
    static let processRows = 3
    static let trayRows = 4
    static let clipboardRows = 3

    /// How many of `total` items are hidden behind a "+N more" caption.
    static func hiddenCount(total: Int, shown limit: Int) -> Int {
        max(0, total - max(0, limit))
    }
}

/// Stable per-row identities for `ForEach`, so reorders animate as moves instead of
/// replacing rows. Keys that collide get a deterministic `#n` suffix (a duplicate id would
/// make SwiftUI drop or merge rows).
enum PillRowIdentity {
    static func unique(_ keys: [String]) -> [String] {
        var used = Set<String>()
        return keys.map { key in
            var candidate = key
            var attempt = 1
            while used.contains(candidate) {
                attempt += 1
                candidate = "\(key)#\(attempt)"
            }
            used.insert(candidate)
            return candidate
        }
    }
}

/// Finds the row that just landed in a list, so it can get a one-shot highlight.
enum PillLanding {
    /// The first element of `new` that was not in `old`; nil when nothing was added (a
    /// removal or reorder must not highlight anything), or when `old` is nil (first read).
    static func added<Element: Hashable>(old: [Element]?, new: [Element]) -> Element? {
        guard let old else { return nil }
        let known = Set(old)
        return new.first { !known.contains($0) }
    }
}

/// Translucent-white surfaces on the black shell (row highlights, spotlight, press fills),
/// with their accessibility fallbacks in one place: an opaque gray under Reduce
/// Transparency (identical on black, but no alpha blending), a little stronger under
/// Increase Contrast so the edge of a pressed row stays visible.
enum PillSurface {
    /// Extra white added under Increase Contrast.
    static let increasedContrastBoost = 0.04

    /// The white level (0...1) of a highlight whose normal alpha is `base`.
    static func highlightLevel(base: Double, increasedContrast: Bool) -> Double {
        min(max(base + (increasedContrast ? increasedContrastBoost : 0), 0), 1)
    }

    static func highlight(base: Double, reduceTransparency: Bool, increasedContrast: Bool) -> Color {
        let level = highlightLevel(base: base, increasedContrast: increasedContrast)
        return reduceTransparency ? PillPalette.opaqueWhite(level) : Color.white.opacity(level)
    }
}

/// The keyboard-focus ring every pill button draws while it holds focus (the system ring is
/// lost with a custom style on black). One definition so rows, icons and transport agree.
enum PillFocusRing {
    static let opacity = 0.9
    /// 1.5pt, 2pt under Increase Contrast.
    static func lineWidth(increasedContrast: Bool) -> CGFloat { increasedContrast ? 2 : 1.5 }
}

extension View {
    /// Draws the focus ring around `shape` (optionally bled outward) only while `isFocused`.
    /// Focus changes are never animated: a ring that fades in lags the keyboard.
    func pillFocusRing<S: InsettableShape>(
        _ shape: S, isFocused: Bool, increasedContrast: Bool,
        horizontalBleed: CGFloat = 0, verticalBleed: CGFloat = 0
    ) -> some View {
        overlay(
            shape
                .strokeBorder(
                    Color.white.opacity(PillFocusRing.opacity),
                    lineWidth: PillFocusRing.lineWidth(increasedContrast: increasedContrast)
                )
                .padding(.horizontal, horizontalBleed)
                .padding(.vertical, verticalBleed)
                .opacity(isFocused ? 1 : 0)
                .transaction { $0.animation = nil }
                .allowsHitTesting(false)
        )
    }
}
