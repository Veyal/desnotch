import AppKit
import CoreGraphics

/// A value copy of what the pill needs to know about one display. `NSScreen` cannot be built
/// in tests, so display choice, the Settings picker list, and the diagnostics report all work
/// on snapshots.
public struct ScreenSnapshot: Equatable {
    public var identifier: String
    public var name: String
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var backingScaleFactor: CGFloat
    public var safeAreaTop: CGFloat
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?

    public init(
        identifier: String,
        name: String,
        frame: CGRect,
        visibleFrame: CGRect,
        backingScaleFactor: CGFloat = 1,
        safeAreaTop: CGFloat = 0,
        auxiliaryTopLeft: CGRect? = nil,
        auxiliaryTopRight: CGRect? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScaleFactor = backingScaleFactor
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }

    public var hasNotch: Bool { safeAreaTop > 0 }

    /// The cutout size, derived exactly as `NotchGeometry.notchSize(for:)` does.
    public var notchSize: CGSize? {
        NotchGeometry.notchSize(
            safeAreaTop: safeAreaTop,
            screenWidth: frame.width,
            auxiliaryLeftWidth: auxiliaryTopLeft?.width,
            auxiliaryRightWidth: auxiliaryTopRight?.width
        )
    }

    public init(screen: NSScreen, index: Int) {
        self.init(
            identifier: NotchGeometry.displayIdentifier(for: screen) ?? "unknown-\(index)",
            name: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScaleFactor: screen.backingScaleFactor,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
    }

    /// Snapshots of every attached screen, in `NSScreen.screens` order (primary first).
    public static func current() -> [ScreenSnapshot] {
        NSScreen.screens.enumerated().map { ScreenSnapshot(screen: $1, index: $0) }
    }
}

/// One row of the Settings display picker.
public struct DisplayChoice: Equatable, Identifiable {
    public let id: String
    public let title: String

    /// Builds the picker rows: "Automatic", every attached display, and - so a saved choice
    /// whose monitor is unplugged still shows as selected instead of leaving the picker blank -
    /// a placeholder for the missing one. Identical monitor names are numbered.
    @MainActor
    public static func choices(for screens: [ScreenSnapshot], selected: String) -> [DisplayChoice] {
        var rows = [DisplayChoice(id: SettingsStore.automaticPillDisplay, title: "Automatic")]
        let nameCounts = Dictionary(screens.map { ($0.name, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        for screen in screens {
            var title = screen.name.isEmpty ? "Display" : screen.name
            if (nameCounts[screen.name] ?? 0) > 1 {
                seen[screen.name, default: 0] += 1
                title += " (\(seen[screen.name] ?? 1))"
            }
            if screen.hasNotch { title += " - notch" }
            rows.append(DisplayChoice(id: screen.identifier, title: title))
        }
        if selected != SettingsStore.automaticPillDisplay,
           !screens.contains(where: { $0.identifier == selected }) {
            rows.append(DisplayChoice(id: selected, title: "Disconnected display (using Automatic)"))
        }
        return rows
    }
}

/// Which display hosts the pill. Pure, so the rules are testable without hardware.
public enum DisplaySelection {
    /// The chosen display if it is attached; otherwise the first display with a physical
    /// notch; otherwise the first display, which macOS documents as the primary one (the one
    /// with the menu bar). `NSScreen.main` is deliberately not used: it follows keyboard focus,
    /// so the pill would jump between monitors as the user clicks around.
    public static func preferredIndex(in screens: [ScreenSnapshot], identifier: String?) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let identifier, let match = screens.firstIndex(where: { $0.identifier == identifier }) {
            return match
        }
        return screens.firstIndex(where: \.hasNotch) ?? 0
    }
}

/// Plain-text report of the display setup, for bug reports about notch fit on hardware that
/// the developer does not own. Contains display names, frames, and display UUIDs only - no
/// content from any feature.
public enum DisplayDiagnostics {
    public static func report(
        screens: [ScreenSnapshot],
        chosenIndex: Int?,
        setting: String,
        panelFrame: CGRect?,
        pinnedOpen: Bool
    ) -> String {
        var lines = ["desnotch display diagnostics"]
        lines.append("Display setting: \(setting)")
        if let chosenIndex, screens.indices.contains(chosenIndex) {
            lines.append("Pill display: \(chosenIndex + 1) of \(screens.count) (\(screens[chosenIndex].name))")
        } else {
            lines.append("Pill display: none")
        }
        lines.append("Panel frame: \(panelFrame.map(format) ?? "none")")
        lines.append("Pinned open: \(pinnedOpen ? "yes" : "no")")
        lines.append("Displays: \(screens.count)")
        for (index, screen) in screens.enumerated() {
            lines.append("")
            lines.append("Display \(index + 1): \(screen.name)\(index == chosenIndex ? " [pill]" : "")")
            lines.append("  id: \(screen.identifier)")
            lines.append("  frame: \(format(screen.frame))")
            lines.append("  visibleFrame: \(format(screen.visibleFrame))")
            lines.append("  scale: \(number(screen.backingScaleFactor))")
            lines.append("  safeAreaInsets.top: \(number(screen.safeAreaTop))")
            lines.append("  auxiliaryTopLeftArea: \(screen.auxiliaryTopLeft.map(format) ?? "none")")
            lines.append("  auxiliaryTopRightArea: \(screen.auxiliaryTopRight.map(format) ?? "none")")
            if let notch = screen.notchSize {
                lines.append("  notch: \(number(notch.width)) x \(number(notch.height))")
            } else {
                lines.append("  notch: none")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func number(_ value: CGFloat) -> String {
        guard value.isFinite else { return "?" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }

    static func format(_ rect: CGRect) -> String {
        "x=\(number(rect.minX)) y=\(number(rect.minY)) w=\(number(rect.width)) h=\(number(rect.height))"
    }
}
