import SwiftUI
import XCTest
@testable import DesnotchCore

/// Tokens and pure helpers added by the polish pass: the last hand-written animation
/// literals became motion tokens, accessibility fallbacks became functions.
final class PillPolishTokenTests: XCTestCase {
    func testReduceMotionZeroesThePolishTokens() {
        let motion = NotchAnimation.resolve(style: .dynamic, reduceMotion: true)

        XCTAssertEqual(motion.sweepDuration, 0, "no battery sweep without geometry")
        XCTAssertEqual(motion.trackSwapDelay, 0)
        XCTAssertEqual(motion.trackSwapLineLag, 0)
        XCTAssertEqual(motion.accentCrossfade, .easeInOut(duration: 0.12), "a short fade, never a long dissolve")
        XCTAssertLessThanOrEqual(motion.pressHold, 0.1)
    }

    func testMinimalStyleSharesThePolishTokens() {
        let minimal = NotchAnimation.resolve(style: .minimal, reduceMotion: false)
        let reduced = NotchAnimation.resolve(style: .subtle, reduceMotion: true)
        XCTAssertEqual(minimal.sweepDuration, reduced.sweepDuration)
        XCTAssertEqual(minimal.pressHold, reduced.pressHold)
        XCTAssertEqual(minimal.accentCrossfade, reduced.accentCrossfade)
    }

    func testFluidAndLivelyKeepTheSameHoldsAndSweep() {
        for style in [AnimationStyle.subtle, .dynamic] {
            let motion = NotchAnimation.resolve(style: style, reduceMotion: false)
            XCTAssertEqual(motion.pressHold, 0.10, accuracy: 1e-9)
            XCTAssertEqual(motion.landingHold, 0.12, accuracy: 1e-9)
            XCTAssertEqual(motion.sweepDuration, 0.60, accuracy: 1e-9)
            XCTAssertEqual(motion.trackSwapDelay, 0.06, accuracy: 1e-9)
            XCTAssertEqual(motion.trackSwapLineLag, 0.03, accuracy: 1e-9)
        }
    }

    func testPressHoldFitsInsideTheMicroInteractionBudget() {
        // A one-shot press (pop, transport nudge) holds, then releases: the hold plus the
        // 150ms-ish release spring stays a micro-interaction.
        for style in [AnimationStyle.subtle, .dynamic, .minimal] {
            let motion = NotchAnimation.resolve(style: style, reduceMotion: false)
            XCTAssertGreaterThan(motion.pressHold, 0)
            XCTAssertLessThanOrEqual(motion.pressHold, 0.15)
        }
    }

    func testTrackSwapSecondLineTrailsTheFirst() {
        let motion = NotchAnimation.resolve(style: .subtle, reduceMotion: false)
        XCTAssertGreaterThan(motion.trackSwapLineLag, 0)
        XCTAssertLessThan(motion.trackSwapLineLag, motion.trackSwapDelay)
    }
}

final class PillSurfaceTests: XCTestCase {
    func testHighlightLevelAddsTheBoostOnlyUnderIncreasedContrast() {
        XCTAssertEqual(PillSurface.highlightLevel(base: 0.07, increasedContrast: false), 0.07, accuracy: 1e-9)
        XCTAssertEqual(
            PillSurface.highlightLevel(base: 0.07, increasedContrast: true),
            0.07 + PillSurface.increasedContrastBoost, accuracy: 1e-9
        )
    }

    func testHighlightLevelIsClampedToTheUnitRange() {
        XCTAssertEqual(PillSurface.highlightLevel(base: 0.99, increasedContrast: true), 1)
        XCTAssertEqual(PillSurface.highlightLevel(base: -0.5, increasedContrast: false), 0)
    }

    func testIncreasedContrastIsAlwaysStrongerThanNormal() {
        for base in stride(from: 0.0, through: 0.9, by: 0.1) {
            XCTAssertGreaterThan(
                PillSurface.highlightLevel(base: base, increasedContrast: true),
                PillSurface.highlightLevel(base: base, increasedContrast: false)
            )
        }
    }
}

final class PillFocusRingTests: XCTestCase {
    func testRingIsVisibleAndThickensUnderIncreasedContrast() {
        XCTAssertEqual(PillFocusRing.lineWidth(increasedContrast: false), 1.5)
        XCTAssertEqual(PillFocusRing.lineWidth(increasedContrast: true), 2)
        XCTAssertGreaterThanOrEqual(PillFocusRing.opacity, 0.9, "near-white on black clears 3:1 by a wide margin")
    }
}

final class PillTransitionAccessibilityTests: XCTestCase {
    func testAnythingNotFullyOpaqueIsHiddenFromAccessibility() {
        XCTAssertTrue(PillArrivalModifier.hidesFromAccessibility(opacity: 0))
        XCTAssertTrue(PillArrivalModifier.hidesFromAccessibility(opacity: 0.99))
    }

    func testTheRestStateIsReachable() {
        XCTAssertFalse(PillArrivalModifier.hidesFromAccessibility(opacity: 1))
    }
}

/// Repo rules that are cheap to check mechanically: the pill's hover has one authority (no
/// SwiftUI `.onHover`), and nothing loops forever, so an idle pill runs no animation.
final class PillSourceGuardTests: XCTestCase {
    private func uiSources() -> [(name: String, code: [String])] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Sources/DesnotchCore/UI"
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: candidate.path)) ?? []
                return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
                    guard let text = try? String(contentsOf: candidate.appendingPathComponent(name), encoding: .utf8)
                    else { return nil }
                    // Comments may mention the banned APIs when explaining why they are banned.
                    let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    return (name, code)
                }
            }
            directory.deleteLastPathComponent()
        }
        return []
    }

    func testTheSourceTreeIsFound() {
        XCTAssertGreaterThan(uiSources().count, 10)
    }

    func testNoSwiftUIHoverModifierInThePill() {
        for source in uiSources() {
            for line in source.code where line.contains(".onHover") {
                XCTFail("\(source.name) uses .onHover; hover is owned by NotchWindowController: \(line)")
            }
        }
    }

    func testNotificationDividerIgnoresTheTrayAndPrivacyRows() {
        // A notification-only stack (tray on by default) must render exactly one rule before
        // the privacy row, never a second one for the tray that sits after it.
        guard let view = uiSources().first(where: { $0.name == "NotchPillView.swift" }) else {
            return XCTFail("NotchPillView.swift not found")
        }
        let code = view.code.joined(separator: "\n")
        guard let start = code.range(of: "reveal(.notification)"),
              let end = code.range(of: "revealDivider(.media)", range: start.upperBound..<code.endIndex)
        else { return XCTFail("notification divider block not found") }
        let block = String(code[start.upperBound..<end.lowerBound])
        XCTAssertTrue(block.contains("hasMiddleSection"))
        XCTAssertFalse(block.contains("trayEnabled"))
    }

    func testNothingRepeatsForever() {
        for source in uiSources() {
            for line in source.code where line.contains("repeatForever") {
                XCTFail("\(source.name) loops an animation forever: \(line)")
            }
        }
    }
}
