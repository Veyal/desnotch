import AppKit
import SwiftUI
import XCTest
@testable import DesnotchCore

final class MarqueePlanTests: XCTestCase {
    func testTextThatFitsNeverScrolls() {
        XCTAssertNil(MarqueePlan.make(textWidth: 100, containerWidth: 120))
        XCTAssertNil(MarqueePlan.make(textWidth: 120, containerWidth: 120))
    }

    func testTinyOverflowIsNotWorthScrolling() {
        XCTAssertNil(MarqueePlan.make(textWidth: 124, containerWidth: 120), "4pt exactly is still hidden by the fade")
        XCTAssertNotNil(MarqueePlan.make(textWidth: 124.5, containerWidth: 120))
    }

    func testOverflowDrivesTravelAtAConstantSpeed() throws {
        let plan = try XCTUnwrap(MarqueePlan.make(textWidth: 288, containerWidth: 120))
        XCTAssertEqual(plan.overflow, 168)
        XCTAssertEqual(plan.travel, TimeInterval(168 / MarqueePlan.speed), accuracy: 1e-9)
        XCTAssertEqual(plan.travel, 6, accuracy: 1e-9)
    }

    func testCycleIsStartRestPlusTravelPlusHoldPlusReturn() throws {
        let plan = try XCTUnwrap(MarqueePlan.make(textWidth: 280, containerWidth: 140))
        XCTAssertEqual(
            plan.cycleDuration,
            MarqueePlan.startDelay + plan.travel + MarqueePlan.endHold + MarqueePlan.returnFade,
            accuracy: 1e-9
        )
    }

    func testUnusableWidthsProduceNoPlan() {
        XCTAssertNil(MarqueePlan.make(textWidth: 0, containerWidth: 100))
        XCTAssertNil(MarqueePlan.make(textWidth: 200, containerWidth: 0))
        XCTAssertNil(MarqueePlan.make(textWidth: .nan, containerWidth: 100))
        XCTAssertNil(MarqueePlan.make(textWidth: 200, containerWidth: .infinity))
        XCTAssertNil(MarqueePlan.make(textWidth: -5, containerWidth: 100))
    }

    func testItIsFiniteByConstruction() {
        XCTAssertEqual(MarqueePlan.maxPasses, 2)
        XCTAssertGreaterThan(MarqueePlan.startDelay, 0)
    }

    func testRunsOnlyWhileExpandedWithMotionAndAnOverflow() throws {
        let plan = try XCTUnwrap(MarqueePlan.make(textWidth: 300, containerWidth: 120))
        XCTAssertTrue(MarqueePlan.shouldRun(plan: plan, expanded: true, allowsMotion: true))
        XCTAssertFalse(MarqueePlan.shouldRun(plan: plan, expanded: false, allowsMotion: true), "collapsed pill never scrolls")
        XCTAssertFalse(MarqueePlan.shouldRun(plan: plan, expanded: true, allowsMotion: false), "Reduce Motion never scrolls")
        XCTAssertFalse(MarqueePlan.shouldRun(plan: nil, expanded: true, allowsMotion: true), "nothing to reveal")
    }

    func testMotionSuppressionMatchesTheVocabulary() {
        XCTAssertTrue(NotchAnimation.resolve(style: .subtle, reduceMotion: false).allowsGeometry)
        XCTAssertFalse(NotchAnimation.resolve(style: .subtle, reduceMotion: true).allowsGeometry)
        XCTAssertFalse(NotchAnimation.resolve(style: .minimal, reduceMotion: false).allowsGeometry)
    }
}

final class PillProgressCadenceTests: XCTestCase {
    func testLongTracksRedrawAboutOnceASecond() {
        // 196pt bar over 240s moves 0.82pt/s: a half-point step takes ~0.6s.
        XCTAssertEqual(PillProgressCadence.interval(barWidth: 196, duration: 240), 0.612, accuracy: 0.001)
        // A 25 minute timer moves < 0.14pt/s: capped at once a second.
        XCTAssertEqual(PillProgressCadence.interval(barWidth: 196, duration: 25 * 60), 1)
    }

    func testShortClipsApproachTheFifteenFpsFloor() {
        XCTAssertEqual(PillProgressCadence.interval(barWidth: 196, duration: 30), 0.0765, accuracy: 0.001)
        XCTAssertEqual(PillProgressCadence.interval(barWidth: 196, duration: 2), 1.0 / 15.0, accuracy: 1e-9)
    }

    func testTheVocabularyFloorWins() {
        // Reduce Motion / Minimal resolve `progressMinimumInterval` to 1s.
        let minimal = NotchAnimation.resolve(style: .minimal, reduceMotion: false)
        XCTAssertEqual(
            PillProgressCadence.interval(barWidth: 196, duration: 30, minimum: minimal.progressMinimumInterval), 1
        )
    }

    func testDegenerateInputsFallBackToOneSecond() {
        XCTAssertEqual(PillProgressCadence.interval(barWidth: 0, duration: 100), 1)
        XCTAssertEqual(PillProgressCadence.interval(barWidth: 100, duration: 0), 1)
        XCTAssertEqual(PillProgressCadence.interval(barWidth: .nan, duration: 100), 1)
        XCTAssertEqual(PillProgressCadence.interval(barWidth: 100, duration: .infinity), 1)
    }

    func testIntervalStaysInsideTheFloorAndOneSecond() {
        for width in stride(from: CGFloat(20), through: 400, by: 40) {
            for duration in [1.0, 10, 90, 240, 3600, 36000] {
                let interval = PillProgressCadence.interval(barWidth: width, duration: duration)
                XCTAssertGreaterThanOrEqual(interval, 1.0 / 15.0)
                XCTAssertLessThanOrEqual(interval, 1)
            }
        }
    }
}

final class PlaybackScrubTests: XCTestCase {
    func testFractionIsClampedAndEdgesAreFlagged() {
        XCTAssertEqual(PlaybackScrub.sample(x: 50, width: 200), PlaybackScrub.Sample(fraction: 0.25, atEdge: false))
        XCTAssertEqual(PlaybackScrub.sample(x: -30, width: 200), PlaybackScrub.Sample(fraction: 0, atEdge: true))
        XCTAssertEqual(PlaybackScrub.sample(x: 0, width: 200), PlaybackScrub.Sample(fraction: 0, atEdge: true))
        XCTAssertEqual(PlaybackScrub.sample(x: 200, width: 200), PlaybackScrub.Sample(fraction: 1, atEdge: true))
        XCTAssertEqual(PlaybackScrub.sample(x: 999, width: 200), PlaybackScrub.Sample(fraction: 1, atEdge: true))
    }

    func testUnusableGeometryYieldsNoSample() {
        XCTAssertNil(PlaybackScrub.sample(x: 10, width: 0))
        XCTAssertNil(PlaybackScrub.sample(x: .nan, width: 100))
        XCTAssertNil(PlaybackScrub.sample(x: 10, width: .infinity))
    }

    func testPositionScalesWithDurationAndClamps() {
        XCTAssertEqual(PlaybackScrub.position(fraction: 0.5, duration: 240), 120)
        XCTAssertEqual(PlaybackScrub.position(fraction: 1.4, duration: 240), 240)
        XCTAssertEqual(PlaybackScrub.position(fraction: -1, duration: 240), 0)
        XCTAssertEqual(PlaybackScrub.position(fraction: 0.5, duration: -10), 0)
    }
}

final class NowPlayingLayoutTests: XCTestCase {
    func testTextColumnReplacesTheOldHardCap() {
        // Default 300pt pill: 268pt of content - 40 art - 10 gap - 88 transport - 8.
        XCTAssertEqual(NowPlayingLayout.textColumnWidth(contentWidth: 268), 122)
        XCTAssertEqual(NowPlayingLayout.textColumnWidth(contentWidth: 448), 302, "a wider pill gives titles more room")
    }

    func testTextColumnNeverDropsBelowTheFloor() {
        XCTAssertEqual(NowPlayingLayout.textColumnWidth(contentWidth: 200), 96)
        XCTAssertEqual(NowPlayingLayout.textColumnWidth(contentWidth: 0), 96)
    }

    func testTransportWidthMatchesItsButtons() {
        XCTAssertEqual(NowPlayingLayout.transportWidth, 24 + 32 + 24 + 2 * NowPlayingLayout.transportSpacing)
    }

    func testProgressBarWidthExcludesBothTimeLabels() {
        XCTAssertEqual(NowPlayingLayout.progressBarWidth(contentWidth: 268), 192)
        XCTAssertEqual(NowPlayingLayout.progressBarWidth(contentWidth: 10), 0)
    }
}

final class PillHapticsTests: XCTestCase {
    func testPatternMapping() {
        XCTAssertEqual(PillHaptics.pattern(for: .transport), .generic)
        XCTAssertEqual(PillHaptics.pattern(for: .scrubBegin), .alignment)
        XCTAssertEqual(PillHaptics.pattern(for: .scrubCommit), .alignment)
        XCTAssertEqual(PillHaptics.pattern(for: .scrubEdge), .levelChange)
    }

    func testRateLimit() {
        XCTAssertTrue(PillHaptics.shouldPlay(now: 100, lastPlayed: nil))
        XCTAssertFalse(PillHaptics.shouldPlay(now: 100.05, lastPlayed: 100))
        XCTAssertTrue(PillHaptics.shouldPlay(now: 100.09, lastPlayed: 100))
        XCTAssertTrue(PillHaptics.shouldPlay(now: 101, lastPlayed: 100))
    }
}

final class NowPlayingMotionTokenTests: XCTestCase {
    func testReduceMotionRemovesEveryNowPlayingGeometryToken() {
        let suppressed = [
            NotchAnimation.resolve(style: .subtle, reduceMotion: true),
            NotchAnimation.resolve(style: .dynamic, reduceMotion: true),
            NotchAnimation.resolve(style: .minimal, reduceMotion: false)
        ]
        for motion in suppressed {
            XCTAssertEqual(motion.iconPressScale, 1)
            XCTAssertEqual(motion.artPauseScale, 1)
            XCTAssertEqual(motion.transportNudge, 0)
            XCTAssertEqual(motion.trackSwapOffset, 0)
            XCTAssertEqual(motion.trackSwapBlur, 0)
            XCTAssertEqual(motion.artArrivalScale, 1)
            XCTAssertNil(motion.direct)
            XCTAssertFalse(motion.allowsAmbient, "no glow without motion")
            XCTAssertLessThan(motion.artPausedOpacity, 1, "paused state is still carried by opacity")
        }
    }

    func testFluidIsSubtlerThanLively() {
        let fluid = NotchAnimation.resolve(style: .subtle, reduceMotion: false)
        let lively = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)
        XCTAssertGreaterThan(fluid.iconPressScale, lively.iconPressScale)
        XCTAssertGreaterThan(fluid.artPauseScale, lively.artPauseScale)
        XCTAssertLessThan(fluid.transportNudge, lively.transportNudge)
        XCTAssertLessThan(fluid.trackSwapOffset, lively.trackSwapOffset)
        XCTAssertLessThanOrEqual(fluid.trackSwapBlur, lively.trackSwapBlur)
        XCTAssertGreaterThan(fluid.artArrivalScale, lively.artArrivalScale)
        XCTAssertNotNil(fluid.direct)
        XCTAssertTrue(fluid.allowsAmbient)
    }

    func testNowPlayingBlurRespectsTheGuardrail() {
        for style in [AnimationStyle.subtle, .dynamic] {
            let motion = NotchAnimation.resolve(style: style, reduceMotion: false)
            XCTAssertLessThanOrEqual(motion.trackSwapBlur, 6)
            XCTAssertLessThan(motion.iconPressScale, 1)
            XCTAssertLessThan(motion.artPauseScale, 1)
        }
    }
}

// MARK: - Contrast and accent

final class PillPaletteTests: XCTestCase {
    func testBlackAndWhiteContrast() {
        XCTAssertEqual(PillPalette.contrastOnBlack(red: 1, green: 1, blue: 1), 21, accuracy: 0.001)
        XCTAssertEqual(PillPalette.contrastOnBlack(red: 0, green: 0, blue: 0), 1, accuracy: 0.001)
    }

    func testLuminanceThresholdIsWCAGAA() {
        XCTAssertGreaterThanOrEqual((PillPalette.aaLuminanceOnBlack + 0.05) / 0.05, 4.5)
        XCTAssertGreaterThan(PillPalette.increasedContrastLuminanceOnBlack, PillPalette.aaLuminanceOnBlack)
    }

    func testTextColorsMeetAAOnBlack() {
        for (name, rgb) in [
            ("mist", (161.0, 161.0, 166.0)), ("slate", (142.0, 142.0, 147.0)), ("silver", (199.0, 199.0, 204.0))
        ] {
            let ratio = PillPalette.contrastOnBlack(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, name)
        }
    }

    func testLiftLeavesBrightColorsAlone() {
        let lifted = PillPalette.lift(red: 1, green: 0.8, blue: 0.2)
        XCTAssertEqual(lifted.red, 1)
        XCTAssertEqual(lifted.green, 0.8)
        XCTAssertEqual(lifted.blue, 0.2)
    }

    func testLiftBrightensDarkBlueTowardsWhite() {
        let blue = (red: CGFloat(0.12), green: CGFloat(0.12), blue: CGFloat(0.82))
        XCTAssertLessThan(PillPalette.contrastOnBlack(red: blue.red, green: blue.green, blue: blue.blue), 4.5)
        let lifted = PillPalette.lift(red: blue.red, green: blue.green, blue: blue.blue)
        XCTAssertGreaterThanOrEqual(
            PillPalette.contrastOnBlack(red: lifted.red, green: lifted.green, blue: lifted.blue), 4.5
        )
        XCTAssertGreaterThan(lifted.red, blue.red)
        XCTAssertLessThanOrEqual(lifted.blue, 1)
    }

    func testLiftIsBoundedToSixSteps() {
        // Black can never reach the threshold in six 8% steps; it must still terminate.
        let lifted = PillPalette.lift(red: 0, green: 0, blue: 0, toMinLuminance: 0.9)
        XCTAssertLessThan(lifted.red, 0.5)
        XCTAssertEqual(lifted.red, 1 - pow(0.92, 6), accuracy: 1e-9)
    }
}

final class ArtworkAccentTests: XCTestCase {
    private static let size = ArtworkAccent.sampleSize

    /// Premultiplied RGBA8 buffer filled by a per-pixel closure (opaque unless it returns alpha).
    private func buffer(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes = [UInt8]()
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                let p = pixel(x, y)
                bytes += [p.0, p.1, p.2, p.3]
            }
        }
        return bytes
    }

    private func srgb(_ color: NSColor?) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    private func hue(_ color: NSColor?) -> Double? {
        guard let c = srgb(color) else { return nil }
        return ArtworkAccent.hsb(red: Double(c.r), green: Double(c.g), blue: Double(c.b)).0
    }

    private func cgImage(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let size = Self.size * 2
        var bytes = [UInt8]()
        for y in 0..<size {
            for x in 0..<size {
                let p = pixel(x, y)
                bytes += [p.0, p.1, p.2, 255]
            }
        }
        let data = Data(bytes) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    func testSolidRedYieldsARedAccent() throws {
        let accent = ArtworkAccent.accent(fromRGBA: buffer { _, _ in (255, 0, 0, 255) })
        let h = try XCTUnwrap(hue(accent))
        XCTAssertTrue(h < 0.03 || h > 0.97, "hue \(h)")
        let c = try XCTUnwrap(srgb(accent))
        XCTAssertGreaterThan(c.r, c.g)
        XCTAssertGreaterThan(c.r, c.b)
    }

    func testSolidGreenYieldsAGreenAccent() throws {
        let accent = ArtworkAccent.accent(fromRGBA: buffer { _, _ in (0, 200, 40, 255) })
        let h = try XCTUnwrap(hue(accent))
        XCTAssertEqual(h, 0.37, accuracy: 0.05)
    }

    func testGrayscaleArtworkHasNoAccent() {
        XCTAssertNil(ArtworkAccent.accent(fromRGBA: buffer { x, _ in
            let v = UInt8(truncatingIfNeeded: 40 + x * 12)
            return (v, v, v, 255)
        }))
        XCTAssertNil(ArtworkAccent.accent(fromRGBA: buffer { _, _ in (255, 255, 255, 255) }))
    }

    func testVeryDarkAndTransparentArtworkHasNoAccent() {
        XCTAssertNil(ArtworkAccent.accent(fromRGBA: buffer { _, _ in (20, 0, 0, 255) }), "too dark to vote")
        XCTAssertNil(ArtworkAccent.accent(fromRGBA: buffer { _, _ in (0, 0, 0, 0) }), "fully transparent")
        XCTAssertNil(ArtworkAccent.accent(fromRGBA: []))
    }

    func testDominantHueWinsOverAMinorityColor() throws {
        // Three quarters blue, one quarter red.
        let accent = ArtworkAccent.accent(fromRGBA: buffer { x, _ in
            x < Self.size * 3 / 4 ? (20, 60, 230, 255) : (230, 30, 30, 255)
        })
        let h = try XCTUnwrap(hue(accent))
        XCTAssertEqual(h, 0.64, accuracy: 0.05, "blue, not red")
    }

    func testGradientPicksTheLargerHueBucket() throws {
        // Left 10 columns yellowish-orange, right 6 columns teal.
        let accent = ArtworkAccent.accent(fromRGBA: buffer { x, _ in
            x < 10 ? (240, 170, 20, 255) : (20, 190, 200, 255)
        })
        let h = try XCTUnwrap(hue(accent))
        XCTAssertEqual(h, 0.12, accuracy: 0.05)
    }

    func testAccentIsAlwaysLegibleOnBlackForEveryHue() throws {
        for degrees in stride(from: 0, to: 360, by: 1) {
            let rgb = ArtworkAccent.rgb(hue: Double(degrees) / 360, saturation: 0.85, brightness: 0.82)
            let pixel = (
                UInt8((rgb.red * 255).rounded()), UInt8((rgb.green * 255).rounded()),
                UInt8((rgb.blue * 255).rounded()), UInt8(255)
            )
            let accent = try XCTUnwrap(ArtworkAccent.accent(fromRGBA: buffer { _, _ in pixel }), "hue \(degrees)")
            let c = try XCTUnwrap(srgb(accent))
            XCTAssertGreaterThanOrEqual(
                PillPalette.contrastOnBlack(red: c.r, green: c.g, blue: c.b), 4.5, "hue \(degrees)"
            )
        }
    }

    func testIncreasedContrastLuminanceIsHonored() throws {
        let pixels = buffer { _, _ in (20, 20, 255, 255) }
        let normal = try XCTUnwrap(srgb(ArtworkAccent.accent(fromRGBA: pixels)))
        let boosted = try XCTUnwrap(srgb(ArtworkAccent.accent(
            fromRGBA: pixels, minLuminance: PillPalette.increasedContrastLuminanceOnBlack
        )))
        XCTAssertGreaterThanOrEqual(
            PillPalette.relativeLuminance(red: boosted.r, green: boosted.g, blue: boosted.b),
            PillPalette.relativeLuminance(red: normal.r, green: normal.g, blue: normal.b)
        )
    }

    func testCGImagePathSamplesTheDrawnImage() throws {
        let image = cgImage { _, _ in (230, 30, 30) }
        let h = try XCTUnwrap(hue(ArtworkAccent.accent(from: image)))
        XCTAssertTrue(h < 0.03 || h > 0.97)
        XCTAssertNil(ArtworkAccent.accent(from: cgImage { _, _ in (128, 128, 128) }))
    }

    func testKeyIsStableAndDistinguishesColors() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        XCTAssertEqual(ArtworkAccent.key(for: red), "ff0000")
        XCTAssertNotEqual(ArtworkAccent.key(for: red), ArtworkAccent.key(for: blue))
        XCTAssertEqual(ArtworkAccent.key(for: nil), "none")
    }

    func testHSBRoundTrip() {
        for (h, s, b) in [(0.0, 1.0, 1.0), (0.33, 0.6, 0.8), (0.5, 0.45, 0.9), (0.9, 0.85, 0.82)] {
            let rgb = ArtworkAccent.rgb(hue: h, saturation: s, brightness: b)
            let back = ArtworkAccent.hsb(red: rgb.red, green: rgb.green, blue: rgb.blue)
            XCTAssertEqual(back.0, h, accuracy: 0.002)
            XCTAssertEqual(back.1, s, accuracy: 0.002)
            XCTAssertEqual(back.2, b, accuracy: 0.002)
        }
    }
}

final class ArtworkAccentCacheTests: XCTestCase {
    private func tiff(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for x in 0..<24 {
            for y in 0..<24 { rep.setColor(color, atX: x, y: y) }
        }
        return rep.representation(using: .tiff, properties: [:])!
    }

    func testDecodeDerivesAnAccentOnceAndReusesIt() throws {
        let data = tiff(NSColor(deviceRed: 0.1, green: 0.8, blue: 0.3, alpha: 1))
        let first = ArtworkCache.decode(data: data)
        let second = ArtworkCache.decode(data: data)
        XCTAssertTrue(first === second, "identical bytes must reuse the cached decode (image and accent)")
        XCTAssertNotNil(first.image)
        let accent = try XCTUnwrap(first.accent)
        XCTAssertGreaterThan(accent.usingColorSpace(.sRGB)!.greenComponent, accent.usingColorSpace(.sRGB)!.redComponent)
    }

    func testGrayscaleArtworkDecodesWithoutAnAccent() {
        let entry = ArtworkCache.decode(data: tiff(NSColor(deviceWhite: 0.5, alpha: 1)))
        XCTAssertNotNil(entry.image)
        XCTAssertNil(entry.accent)
    }

    func testPayloadCarriesTheAccentButEqualityIgnoresIt() {
        let data = tiff(NSColor(deviceRed: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        let payload: [String: Any] = [
            "title": "T", "artist": "A", "playing": true,
            "artworkData": data.base64EncodedString()
        ]
        let withArt = NowPlayingInfo(adapterPayload: payload)
        XCTAssertNotNil(withArt.accent)
        var other = withArt
        other.accent = NSColor.blue
        XCTAssertEqual(withArt, other, "accent is presentation data, not track identity")
        let withoutArt = NowPlayingInfo(adapterPayload: ["title": "T", "artist": "A", "playing": true])
        XCTAssertNil(withoutArt.accent)
        XCTAssertEqual(withArt, withoutArt)
    }

    func testTrackTextKeyFollowsTitleAndArtistOnly() {
        let a = NowPlayingInfo(adapterPayload: ["title": "T", "artist": "A", "uniqueIdentifier": "1"])
        let b = NowPlayingInfo(adapterPayload: ["title": "T", "artist": "A", "uniqueIdentifier": "2", "playing": true])
        let c = NowPlayingInfo(adapterPayload: ["title": "T", "artist": "B"])
        XCTAssertEqual(a.trackTextKey, b.trackTextKey)
        XCTAssertNotEqual(a.trackTextKey, c.trackTextKey)
        XCTAssertNotEqual(
            NowPlayingInfo(adapterPayload: ["title": "TA"]).trackTextKey,
            NowPlayingInfo(adapterPayload: ["title": "T", "artist": "A"]).trackTextKey,
            "the separator keeps title/artist boundaries distinct"
        )
    }
}

final class NowPlayingEqualizerLayoutTests: XCTestCase {
    func testExpandedVariantHasFourDistinctBars() {
        XCTAssertEqual(NowPlayingEqualizer.expandedBarCount, 4)
        let t = 2.5
        let levels = (0..<NowPlayingEqualizer.expandedBarCount).map { NowPlayingEqualizer.barLevel($0, at: t) }
        XCTAssertEqual(Set(levels.map { Int($0 * 1000) }).count, 4)
        for level in levels {
            XCTAssertGreaterThanOrEqual(level, 0)
            XCTAssertLessThanOrEqual(level, 1)
        }
    }

    func testBarLevelIsTotalForAnyIndex() {
        XCTAssertEqual(NowPlayingEqualizer.barLevel(-1, at: 1), NowPlayingEqualizer.barLevel(3, at: 1))
        XCTAssertEqual(NowPlayingEqualizer.barLevel(7, at: 1), NowPlayingEqualizer.barLevel(3, at: 1))
    }
}
