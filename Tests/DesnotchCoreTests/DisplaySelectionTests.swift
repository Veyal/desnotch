import XCTest
@testable import DesnotchCore

@MainActor
final class DisplaySelectionTests: XCTestCase {
    private func screen(
        _ id: String,
        name: String = "Display",
        notch: CGFloat = 0,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
    ) -> ScreenSnapshot {
        ScreenSnapshot(
            identifier: id,
            name: name,
            frame: frame,
            visibleFrame: frame,
            backingScaleFactor: 2,
            safeAreaTop: notch,
            auxiliaryTopLeft: notch > 0 ? CGRect(x: 0, y: 944, width: 656, height: 38) : nil,
            auxiliaryTopRight: notch > 0 ? CGRect(x: 856, y: 944, width: 656, height: 38) : nil
        )
    }

    // MARK: Which display hosts the pill

    func testNoScreensYieldsNoChoice() {
        XCTAssertNil(DisplaySelection.preferredIndex(in: [], identifier: nil))
        XCTAssertNil(DisplaySelection.preferredIndex(in: [], identifier: "abc"))
    }

    func testAutomaticPrefersTheNotchDisplay() {
        let screens = [screen("external"), screen("builtin", notch: 38)]
        XCTAssertEqual(DisplaySelection.preferredIndex(in: screens, identifier: nil), 1)
    }

    func testAutomaticFallsBackToTheFirstDisplayNotTheFocusedOne() {
        // Without a notch anywhere the first (primary) display wins, regardless of order
        // beyond that: the rule must not depend on keyboard focus (`NSScreen.main`).
        let screens = [screen("primary"), screen("secondary")]
        XCTAssertEqual(DisplaySelection.preferredIndex(in: screens, identifier: nil), 0)
    }

    func testExplicitChoiceWinsOverNotch() {
        let screens = [screen("external"), screen("builtin", notch: 38)]
        XCTAssertEqual(DisplaySelection.preferredIndex(in: screens, identifier: "external"), 0)
    }

    func testDisconnectedChoiceFallsBackToAutomatic() {
        let screens = [screen("external"), screen("builtin", notch: 38)]
        XCTAssertEqual(DisplaySelection.preferredIndex(in: screens, identifier: "gone"), 1)
    }

    // MARK: Picker rows

    func testChoicesStartWithAutomaticAndListEveryDisplay() {
        let rows = DisplayChoice.choices(
            for: [screen("a", name: "Studio Display"), screen("b", name: "Built-in", notch: 38)],
            selected: SettingsStore.automaticPillDisplay
        )
        XCTAssertEqual(rows.map(\.id), [SettingsStore.automaticPillDisplay, "a", "b"])
        XCTAssertEqual(rows.map(\.title), ["Automatic", "Studio Display", "Built-in - notch"])
    }

    func testChoicesNumberIdenticalMonitorNames() {
        let rows = DisplayChoice.choices(
            for: [screen("a", name: "DELL U2723QE"), screen("b", name: "DELL U2723QE")],
            selected: SettingsStore.automaticPillDisplay
        )
        XCTAssertEqual(rows.map(\.title), ["Automatic", "DELL U2723QE (1)", "DELL U2723QE (2)"])
    }

    func testChoicesKeepAMissingSelectionSelectable() {
        let rows = DisplayChoice.choices(for: [screen("a", name: "Built-in")], selected: "unplugged")
        XCTAssertEqual(rows.last?.id, "unplugged")
        XCTAssertEqual(rows.count, 3)
    }

    func testChoicesDoNotAddAPlaceholderForAnAttachedSelection() {
        let rows = DisplayChoice.choices(for: [screen("a", name: "Built-in")], selected: "a")
        XCTAssertEqual(rows.map(\.id), [SettingsStore.automaticPillDisplay, "a"])
    }

    // MARK: Notch size rule

    func testNotchSizeIsNilWithoutASafeAreaInset() {
        XCTAssertNil(screen("a").notchSize)
    }

    func testNotchSizeComesFromTheGapBetweenTheAuxiliaryAreas() {
        XCTAssertEqual(screen("a", notch: 38).notchSize, CGSize(width: 200, height: 38))
    }

    func testNotchSizeFallsBackWhenAuxiliaryAreasAreMissing() {
        XCTAssertEqual(
            NotchGeometry.notchSize(
                safeAreaTop: 32, screenWidth: 1512, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
            ),
            CGSize(width: 200, height: 32)
        )
    }

    // MARK: Diagnostics

    func testDiagnosticsReportListsEveryDisplayAndMarksThePillDisplay() {
        let screens = [screen("ext-uuid", name: "Studio Display"), screen("built-uuid", name: "Built-in", notch: 38)]
        let report = DisplayDiagnostics.report(
            screens: screens,
            chosenIndex: 1,
            setting: "automatic",
            panelFrame: CGRect(x: 516, y: 600, width: 480, height: 382),
            pinnedOpen: true
        )
        XCTAssertTrue(report.hasPrefix("desnotch display diagnostics\n"))
        XCTAssertTrue(report.contains("Display setting: automatic"))
        XCTAssertTrue(report.contains("Pill display: 2 of 2 (Built-in)"))
        XCTAssertTrue(report.contains("Panel frame: x=516 y=600 w=480 h=382"))
        XCTAssertTrue(report.contains("Pinned open: yes"))
        XCTAssertTrue(report.contains("Display 1: Studio Display\n"))
        XCTAssertTrue(report.contains("Display 2: Built-in [pill]"))
        XCTAssertTrue(report.contains("  id: built-uuid"))
        XCTAssertTrue(report.contains("  safeAreaInsets.top: 38"))
        XCTAssertTrue(report.contains("  auxiliaryTopLeftArea: x=0 y=944 w=656 h=38"))
        XCTAssertTrue(report.contains("  notch: 200 x 38"))
        XCTAssertTrue(report.contains("  notch: none"))
    }

    func testDiagnosticsReportHandlesNoDisplays() {
        let report = DisplayDiagnostics.report(
            screens: [], chosenIndex: nil, setting: "automatic", panelFrame: nil, pinnedOpen: false
        )
        XCTAssertTrue(report.contains("Pill display: none"))
        XCTAssertTrue(report.contains("Panel frame: none"))
        XCTAssertTrue(report.contains("Displays: 0"))
    }

    func testDiagnosticsFormatsFractionalAndNonFiniteNumbers() {
        XCTAssertEqual(DisplayDiagnostics.number(1.5), "1.5")
        XCTAssertEqual(DisplayDiagnostics.number(2), "2")
        XCTAssertEqual(DisplayDiagnostics.number(.infinity), "?")
    }
}
