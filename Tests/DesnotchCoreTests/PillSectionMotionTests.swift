import SwiftUI
import XCTest
@testable import DesnotchCore

/// Tokens, scales and pure helpers behind the section rows and the collapsed wings.
final class PillSectionTokenTests: XCTestCase {
    func testReduceMotionRemovesEverySectionEffect() {
        let motion = NotchAnimation.resolve(style: .dynamic, reduceMotion: true)

        XCTAssertEqual(motion.rowPressScale, 1)
        XCTAssertEqual(motion.chipArrivalScale, 1)
        XCTAssertEqual(motion.popScale, 1)
        XCTAssertEqual(motion.dropWellScale, 1)
        XCTAssertEqual(motion.wingSwapScaleIn, 1)
        XCTAssertEqual(motion.wingSwapScaleOut, 1)
        XCTAssertEqual(motion.wingSwapBlur, 0)
        XCTAssertEqual(motion.attentionPulseCount, 0, "static tint only, no ripple")
        XCTAssertFalse(motion.allowsRipple)
        XCTAssertEqual(motion.ringPulseScale, 1)
        XCTAssertEqual(motion.landingFlashPeak, 0)
        XCTAssertEqual(motion.strikeDuration, 0)
        XCTAssertEqual(motion.checkDrawDuration, 0)
    }

    func testMinimalStyleMatchesReduceMotionForSections() {
        XCTAssertEqual(
            NotchAnimation.resolve(style: .minimal, reduceMotion: false),
            NotchAnimation.resolve(style: .subtle, reduceMotion: true)
        )
    }

    func testFluidIsSubtlerThanLivelyOnEverySectionAxis() {
        let fluid = NotchAnimation.resolve(style: .subtle, reduceMotion: false)
        let lively = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)

        XCTAssertGreaterThan(fluid.rowPressScale, lively.rowPressScale)
        XCTAssertGreaterThan(fluid.chipArrivalScale, lively.chipArrivalScale)
        XCTAssertLessThan(fluid.popScale, lively.popScale)
        XCTAssertLessThan(fluid.dropWellScale, lively.dropWellScale)
        XCTAssertGreaterThan(fluid.wingSwapScaleIn, lively.wingSwapScaleIn)
        XCTAssertGreaterThan(fluid.wingSwapScaleOut, lively.wingSwapScaleOut)
        XCTAssertLessThan(fluid.wingSwapBlur, lively.wingSwapBlur)
        XCTAssertLessThan(fluid.attentionPulseCount, lively.attentionPulseCount)
        XCTAssertLessThan(fluid.ringPulseScale, lively.ringPulseScale)
    }

    func testAttentionPulsesAreFiniteAndShort() {
        for style in [AnimationStyle.subtle, .dynamic] {
            let motion = NotchAnimation.resolve(style: style, reduceMotion: false)
            XCTAssertTrue(motion.allowsRipple)
            XCTAssertGreaterThan(motion.attentionPulseCount, 0)
            XCTAssertLessThanOrEqual(motion.attentionPulseCount, 3)
            let total = Double(motion.attentionPulseCount) * motion.attentionPulseDuration
                + Double(motion.attentionPulseCount - 1) * motion.attentionPulseGap
            XCTAssertLessThan(total, 3, "the whole attention pulse stays under three seconds")
            XCTAssertGreaterThan(motion.ringPulseScale, 1)
        }
    }

    func testPressedRowsNeverSqueezeInTheDefaultStyle() {
        // Full-width rows highlight on press; only the Lively style adds a hair of squeeze.
        let fluid = NotchAnimation.resolve(style: .subtle, reduceMotion: false)
        let lively = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)
        XCTAssertEqual(fluid.rowPressScale, 1)
        XCTAssertGreaterThanOrEqual(lively.rowPressScale, 0.98)
        XCTAssertGreaterThan(lively.rowPressScale, lively.iconPressScale)
    }

    func testLandingFlashIsSubtleAndFadesSlowly() {
        for style in [AnimationStyle.subtle, .dynamic] {
            let motion = NotchAnimation.resolve(style: style, reduceMotion: false)
            XCTAssertGreaterThan(motion.landingFlashPeak, 0)
            XCTAssertLessThanOrEqual(motion.landingFlashPeak, 0.2)
        }
    }

    func testVoiceIsFirstAndEveryOtherKindShiftsByOne() {
        XCTAssertEqual(PillSectionKind.allCases.count, 13)
        XCTAssertEqual(PillSectionKind.voice.order, 0)
        XCTAssertEqual(PillSectionKind.notification.order, 1)
        XCTAssertEqual(PillSectionKind.media.order, 2)
        XCTAssertEqual(PillSectionKind.timer.order, 3)
        XCTAssertEqual(PillSectionKind.agents.order, 4)
        XCTAssertEqual(PillSectionKind.processes.order, 5)
        XCTAssertEqual(PillSectionKind.calendar.order, 6)
        XCTAssertEqual(PillSectionKind.reminders.order, 7)
        XCTAssertEqual(PillSectionKind.battery.order, 8)
        XCTAssertEqual(PillSectionKind.clipboard.order, 9)
        XCTAssertEqual(PillSectionKind.talk.order, 10)
        XCTAssertEqual(PillSectionKind.privacy.order, 11)
        XCTAssertEqual(PillSectionKind.tray.order, 12)
    }

    func testApproveHoldDurationIsTheSameInEveryTokenSet() {
        XCTAssertEqual(NotchAnimation.Motion.minimal.approveHoldDuration, 0.6)
        XCTAssertEqual(NotchAnimation.Motion.fluid.approveHoldDuration, 0.6)
        XCTAssertEqual(NotchAnimation.Motion.lively.approveHoldDuration, 0.6)
    }
}

final class PillTypeScaleTests: XCTestCase {
    func testNothingIsSmallerThanTenPoints() {
        for style in PillTextStyle.allCases {
            XCTAssertGreaterThanOrEqual(style.size, PillTextStyle.minimumSize, "\(style)")
        }
    }

    func testReadingTextIsElevenPointsOrLarger() {
        XCTAssertGreaterThanOrEqual(PillTextStyle.body.size, 11)
        XCTAssertGreaterThanOrEqual(PillTextStyle.bodyStrong.size, 11)
        XCTAssertGreaterThanOrEqual(PillTextStyle.title.size, 12)
        XCTAssertGreaterThan(PillTextStyle.display.size, PillTextStyle.title.size)
    }

    func testChangingNumbersAreMonospaced() {
        XCTAssertTrue(PillTextStyle.display.monospacedDigits)
        XCTAssertTrue(PillTextStyle.wingTimer.monospacedDigits)
    }

    func testRowHeightsAndSpacingSitOnTheFourPointGrid() {
        let heights: [CGFloat] = [
            PillRowHeight.compact, PillRowHeight.standard, PillRowHeight.tall,
            PillRowHeight.slim, PillRowHeight.listRow
        ]
        for height in heights {
            XCTAssertEqual(height.truncatingRemainder(dividingBy: 4), 0, "\(height)")
            XCTAssertGreaterThanOrEqual(height, 24, "min hit target")
        }
        for space in [PillSpace.xs, PillSpace.s, PillSpace.m, PillSpace.l, PillSpace.xl] {
            XCTAssertEqual(space.truncatingRemainder(dividingBy: 4), 0)
        }
    }

    func testBoundedListsAtTheirCapsFitTheFloorOnTheirOwn() {
        // Header + capped rows + the "+N more" caption, per list. The lists are bounded so a
        // long agent/tray/process list can never be what forces the panel to grow.
        func list(rows: Int, rowHeight: CGFloat) -> CGFloat {
            PillRowHeight.compact + CGFloat(rows) * rowHeight + PillRowHeight.compact
        }
        let total = list(rows: PillLimits.agentRows, rowHeight: PillRowHeight.standard)
            + list(rows: PillLimits.processRows, rowHeight: PillRowHeight.listRow)
            + list(rows: PillLimits.trayRows, rowHeight: PillRowHeight.listRow)
            + list(rows: PillLimits.clipboardRows, rowHeight: PillRowHeight.listRow)
        XCTAssertLessThan(total, NotchGeometry.contentFloor.height)
    }

    func testHiddenCount() {
        XCTAssertEqual(PillLimits.hiddenCount(total: 7, shown: 4), 3)
        XCTAssertEqual(PillLimits.hiddenCount(total: 4, shown: 4), 0)
        XCTAssertEqual(PillLimits.hiddenCount(total: 2, shown: 4), 0)
        XCTAssertEqual(PillLimits.hiddenCount(total: 5, shown: -1), 5)
    }
}

final class PillRowIdentityTests: XCTestCase {
    func testUniqueKeysAreUnchanged() {
        XCTAssertEqual(PillRowIdentity.unique(["a", "b", "c"]), ["a", "b", "c"])
    }

    func testDuplicatesGetDeterministicSuffixesInOrder() {
        XCTAssertEqual(PillRowIdentity.unique(["a", "b", "a", "a"]), ["a", "b", "a#2", "a#3"])
    }

    func testResultIsAlwaysUnique() {
        // A generated suffix can collide with a genuine key; the result must still be unique.
        let keys = ["x", "x", "x#2", "y", "x"]
        let unique = PillRowIdentity.unique(keys)
        XCTAssertEqual(unique.count, keys.count)
        XCTAssertEqual(Set(unique).count, keys.count)
        XCTAssertEqual(unique.first, "x")
    }

    func testEmpty() {
        XCTAssertEqual(PillRowIdentity.unique([]), [])
    }
}

final class PillLandingTests: XCTestCase {
    func testFindsTheNewcomer() {
        XCTAssertEqual(PillLanding.added(old: ["a", "b"], new: ["c", "a", "b"]), "c")
    }

    func testRemovalAndReorderLandNothing() {
        XCTAssertNil(PillLanding.added(old: ["a", "b", "c"], new: ["a", "c"]))
        XCTAssertNil(PillLanding.added(old: ["a", "b"], new: ["b", "a"]))
        XCTAssertNil(PillLanding.added(old: ["a"], new: ["a"]))
    }

    func testFirstReadNeverFlashes() {
        XCTAssertNil(PillLanding.added(old: nil, new: ["a", "b"]))
    }

    func testFirstOfSeveralNewcomersWins() {
        XCTAssertEqual(PillLanding.added(old: ["a"], new: ["x", "y", "a"]), "x")
    }
}

final class PillStatusPaletteTests: XCTestCase {
    private let swatches: [(String, PillPalette.Swatch)] = [
        ("amber", PillPalette.amber), ("cyan", PillPalette.cyan), ("orange", PillPalette.orange),
        ("green", PillPalette.green), ("red", PillPalette.red), ("white", PillPalette.white),
        ("mist", PillPalette.mist)
    ]

    func testEveryStatusColorPassesWCAGAAOnBlack() {
        for (name, swatch) in swatches {
            XCTAssertGreaterThanOrEqual(swatch.contrastOnBlack, 4.5, name)
        }
    }

    func testOpaqueStandInIsTheTintOverBlack() {
        XCTAssertEqual(PillPalette.amber.opaque(alpha: 0.16), PillPalette.Swatch(red: 41, green: 34, blue: 2))
        XCTAssertEqual(PillPalette.white.opaque(alpha: 0.5), PillPalette.Swatch(red: 128, green: 128, blue: 128))
        XCTAssertEqual(PillPalette.green.opaque(alpha: 0), PillPalette.Swatch(red: 0, green: 0, blue: 0))
        XCTAssertEqual(PillPalette.red.opaque(alpha: 1), PillPalette.red)
    }

    func testOpaqueAlphaIsClamped() {
        XCTAssertEqual(PillPalette.cyan.opaque(alpha: 3), PillPalette.cyan)
        XCTAssertEqual(PillPalette.cyan.opaque(alpha: -1), PillPalette.Swatch(red: 0, green: 0, blue: 0))
    }

    func testCaptionTextLiftsUnderIncreasedContrast() {
        XCTAssertNotEqual(
            PillPalette.captionText(increasedContrast: false),
            PillPalette.captionText(increasedContrast: true)
        )
        XCTAssertEqual(PillPalette.captionText(increasedContrast: true), PillPalette.silver)
    }
}

final class PillTimerRingMathTests: XCTestCase {
    func testProgressIsElapsedFractionClamped() {
        XCTAssertEqual(PillTimerRing.progress(remaining: 300, duration: 1500), 0.8, accuracy: 1e-9)
        XCTAssertEqual(PillTimerRing.progress(remaining: 1500, duration: 1500), 0)
        XCTAssertEqual(PillTimerRing.progress(remaining: 0, duration: 1500), 1)
        XCTAssertEqual(PillTimerRing.progress(remaining: -5, duration: 1500), 1)
        XCTAssertEqual(PillTimerRing.progress(remaining: 2000, duration: 1500), 0)
    }

    func testOnlyShortRunsGlideBetweenTicks() {
        // A 25-minute run barely moves the ring per second: it steps, no 60 fps glide.
        XCTAssertFalse(PillTimerRing.glides(duration: 1500, size: 32, lineWidth: 3))
        XCTAssertFalse(PillTimerRing.glides(duration: 1500, size: 14, lineWidth: 2))
        // A 30-second run moves it several points per second.
        XCTAssertTrue(PillTimerRing.glides(duration: 30, size: 32, lineWidth: 3))
        XCTAssertTrue(PillTimerRing.glides(duration: 30, size: 14, lineWidth: 2))
        XCTAssertFalse(PillTimerRing.glides(duration: 0, size: 32, lineWidth: 3))
        XCTAssertFalse(PillTimerRing.glides(duration: .infinity, size: 32, lineWidth: 3))
    }

    func testBadInputsAreZero() {
        XCTAssertEqual(PillTimerRing.progress(remaining: 5, duration: 0), 0)
        XCTAssertEqual(PillTimerRing.progress(remaining: .nan, duration: 10), 0)
        XCTAssertEqual(PillTimerRing.progress(remaining: 5, duration: .infinity), 0)
    }

    func testCompletedRingIsAlwaysFull() {
        XCTAssertEqual(PillTimerRing.displayedProgress(phase: .completed, progress: 0), 1)
        XCTAssertEqual(PillTimerRing.displayedProgress(phase: .running, progress: 0.4), 0.4)
        XCTAssertEqual(PillTimerRing.displayedProgress(phase: .paused, progress: 1.7), 1)
        XCTAssertEqual(PillTimerRing.displayedProgress(phase: .paused, progress: -1), 0)
        XCTAssertEqual(PillTimerRing.displayedProgress(phase: .running, progress: .nan), 0)
    }

    func testPhaseTints() {
        XCTAssertEqual(PillTimerRing.tint(for: .running), PillPalette.cyan)
        XCTAssertEqual(PillTimerRing.tint(for: .paused), PillPalette.amber)
        XCTAssertEqual(PillTimerRing.tint(for: .completed), PillPalette.green)
    }

    func testIncreaseContrastThickensTheStroke() {
        XCTAssertEqual(PillTimerRing.strokeWidth(base: 3, increasedContrast: false), 3)
        XCTAssertEqual(PillTimerRing.strokeWidth(base: 3, increasedContrast: true), 4)
    }
}

final class PillBatteryGlyphMathTests: XCTestCase {
    func testFillWidthIsProportionalButNeverInvisible() {
        let inner = PillBatteryGlyph.innerWidth
        XCTAssertEqual(PillBatteryGlyph.fillWidth(percent: 100, inner: inner), inner)
        XCTAssertEqual(PillBatteryGlyph.fillWidth(percent: 50, inner: inner), inner / 2, accuracy: 1e-9)
        XCTAssertEqual(PillBatteryGlyph.fillWidth(percent: 0, inner: inner), 0)
        XCTAssertEqual(PillBatteryGlyph.fillWidth(percent: 1, inner: inner), 2, "a sliver stays visible")
    }

    func testOutOfRangePercentIsClamped() {
        let inner = PillBatteryGlyph.innerWidth
        XCTAssertEqual(PillBatteryGlyph.fillWidth(percent: 140, inner: inner), inner)
        XCTAssertEqual(PillBatteryGlyph.fillWidth(percent: -3, inner: inner), 0)
        XCTAssertEqual(PillBatteryGlyph.fraction(percent: 250), 1)
    }

    func testTintFollowsChargeState() {
        XCTAssertEqual(PillBatteryGlyph.tint(percent: 10, isCharging: true), PillPalette.green)
        XCTAssertEqual(PillBatteryGlyph.tint(percent: 20, isCharging: false), PillPalette.red)
        XCTAssertEqual(PillBatteryGlyph.tint(percent: 21, isCharging: false), PillPalette.mist)
        XCTAssertEqual(PillBatteryGlyph.tint(percent: 90, isCharging: false), PillPalette.mist)
    }

    func testBoltContrastsWithTheFillUnderIt() {
        XCTAssertTrue(PillBatteryGlyph.boltIsDark(percent: 80))
        XCTAssertFalse(PillBatteryGlyph.boltIsDark(percent: 30))
    }
}

final class PillSwitchGeometryTests: XCTestCase {
    func testKnobStaysInsideTheTrack() {
        let on = PillSwitch.knobOffset(isOn: true)
        let off = PillSwitch.knobOffset(isOn: false)
        XCTAssertEqual(on, -off)
        XCTAssertGreaterThan(on, 0)
        XCTAssertLessThanOrEqual(on + PillSwitch.knobDiameter / 2, PillSwitch.size.width / 2)
    }
}

final class WingSelectionTests: XCTestCase {
    private func select(_ configure: (inout WingInputs) -> Void) -> (WingIndicator?, WingIndicator?) {
        var inputs = WingInputs()
        configure(&inputs)
        let result = WingSelection.select(inputs)
        return (result.left, result.right)
    }

    func testIdleHasNoIndicators() {
        let result = select { _ in }
        XCTAssertNil(result.0)
        XCTAssertNil(result.1)
    }

    func testVolumeTakesBothWingsOverEverything() {
        let result = select {
            $0.volumeActive = true
            $0.hasMedia = true
            $0.hasAgents = true
            $0.hasTimer = true
        }
        XCTAssertEqual(result.0, .volume)
        XCTAssertEqual(result.1, .volume)
    }

    func testMediaOwnsTheLeftWingAndAgentsTheRight() {
        let result = select {
            $0.hasMedia = true
            $0.hasAgents = true
        }
        XCTAssertEqual(result.0, .media)
        XCTAssertEqual(result.1, .agent)
    }

    func testTimerIsDisplacedToTheRightByMedia() {
        let both = select {
            $0.hasMedia = true
            $0.hasTimer = true
        }
        XCTAssertEqual(both.0, .media)
        XCTAssertEqual(both.1, .timer)

        let timerOnly = select { $0.hasTimer = true }
        XCTAssertEqual(timerOnly.0, .timer)
        XCTAssertNil(timerOnly.1)
    }

    func testAgentsBeatADisplacedTimerOnTheRight() {
        let result = select {
            $0.hasMedia = true
            $0.hasTimer = true
            $0.hasAgents = true
        }
        XCTAssertEqual(result.0, .media)
        XCTAssertEqual(result.1, .agent)
    }

    func testLeftPriorityOrder() {
        XCTAssertEqual(select { $0.hasTimer = true; $0.hasHotProcesses = true }.0, .timer)
        XCTAssertEqual(select { $0.hasHotProcesses = true; $0.calendarImminent = true }.0, .hotProcess)
        XCTAssertEqual(select { $0.calendarImminent = true; $0.reminderUrgent = true }.0, .calendar)
        XCTAssertEqual(select { $0.reminderUrgent = true }.0, .reminder)
    }

    func testNotificationsFillTheRightWingWhenAgentsAreAbsent() {
        let result = select {
            $0.hasMedia = true
            $0.hasNotification = true
        }
        XCTAssertEqual(result.1, .notification)
    }

    func testWhatTheLeftWingDisplacesMovesRight() {
        XCTAssertEqual(select { $0.hasMedia = true; $0.hasHotProcesses = true }.1, .hotProcess)
        XCTAssertEqual(select { $0.hasHotProcesses = true; $0.calendarImminent = true }.1, .calendar)
        XCTAssertEqual(select { $0.hasMedia = true; $0.reminderUrgent = true }.1, .reminder)
        XCTAssertEqual(select { $0.calendarImminent = true; $0.reminderUrgent = true }.1, .reminder)
        // Nothing displaced it: the urgent reminder owns the left wing alone.
        XCTAssertNil(select { $0.reminderUrgent = true }.1)
    }

    func testAnIndicatorNeverAppearsInBothWingsExceptVolume() {
        for bits in 0..<(1 << 7) {
            var inputs = WingInputs()
            inputs.hasMedia = bits & 1 != 0
            inputs.hasTimer = bits & 2 != 0
            inputs.hasAgents = bits & 4 != 0
            inputs.hasHotProcesses = bits & 8 != 0
            inputs.hasNotification = bits & 16 != 0
            inputs.calendarImminent = bits & 32 != 0
            inputs.reminderUrgent = bits & 64 != 0
            let result = WingSelection.select(inputs)
            if let left = result.left, let right = result.right {
                XCTAssertNotEqual(left, right, "inputs \(inputs)")
            }
        }
    }
}

final class CompactTimeFormattingTests: XCTestCase {
    func testMinutesRoundUp() {
        XCTAssertEqual(TimeFormatting.compact(1440), "24m")
        XCTAssertEqual(TimeFormatting.compact(1441), "25m")
        XCTAssertEqual(TimeFormatting.compact(61), "2m")
        XCTAssertEqual(TimeFormatting.compact(60), "1m")
    }

    func testUnderAMinuteIsSeconds() {
        XCTAssertEqual(TimeFormatting.compact(59), "59s")
        XCTAssertEqual(TimeFormatting.compact(45.2), "46s")
        XCTAssertEqual(TimeFormatting.compact(1), "1s")
        XCTAssertEqual(TimeFormatting.compact(0), "0s")
    }

    func testHoursStayShortEnoughForAWing() {
        XCTAssertEqual(TimeFormatting.compact(3600), "1h00")
        XCTAssertEqual(TimeFormatting.compact(3600 + 5 * 60), "1h05")
        XCTAssertEqual(TimeFormatting.compact(2 * 3600 + 30 * 60), "2h30")
        XCTAssertLessThanOrEqual(TimeFormatting.compact(9 * 3600 + 59 * 60).count, 5)
    }

    func testNegativeIsZero() {
        XCTAssertEqual(TimeFormatting.compact(-12), "0s")
    }
}

final class PillSectionHapticsTests: XCTestCase {
    func testSectionEventsMapToTheSpecifiedPatterns() {
        XCTAssertEqual(PillHaptics.pattern(for: .trayDrop), .alignment)
        XCTAssertEqual(PillHaptics.pattern(for: .clipboardCopy), .generic)
        XCTAssertEqual(PillHaptics.pattern(for: .reminderComplete), .levelChange)
        XCTAssertEqual(PillHaptics.pattern(for: .timerComplete), .levelChange)
        XCTAssertEqual(PillHaptics.pattern(for: .privacyToggle), .generic)
    }

    func testOnlyTimerCompletionIsADoubleTap() {
        for event in PillHaptics.Event.allCases {
            let taps = (event == .timerComplete || event == .voiceError) ? 2 : 1
            XCTAssertEqual(PillHaptics.tapCount(for: event), taps, "\(event)")
        }
        // The second tap must clear the rate limiter or it would be dropped.
        XCTAssertGreaterThan(PillHaptics.repeatInterval, PillHaptics.minimumInterval)
    }
}
