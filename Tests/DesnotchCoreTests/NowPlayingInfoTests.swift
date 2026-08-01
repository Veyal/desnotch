import XCTest
@testable import DesnotchCore

final class NowPlayingInfoTests: XCTestCase {
    func testEmptyPayloadHasNoContent() {
        let info = NowPlayingInfo(adapterPayload: [:])
        XCTAssertFalse(info.hasContent)
        XCTAssertNil(info.title)
        XCTAssertNil(info.artist)
        XCTAssertFalse(info.isPlaying)
        XCTAssertNil(info.uniqueIdentifier)
    }

    func testTitleArtistMeansContent() {
        let info = NowPlayingInfo(adapterPayload: [
            "title": "Track", "artist": "Artist", "playing": true
        ])
        XCTAssertTrue(info.hasContent)
        XCTAssertEqual(info.title, "Track")
        XCTAssertEqual(info.artist, "Artist")
        XCTAssertTrue(info.isPlaying)
    }

    func testNSNullUniqueIdentifierIsNilNotLiteral() {
        // The adapter can return NSNull for uniqueIdentifier; it must not become "<null>".
        let info = NowPlayingInfo(adapterPayload: ["title": "T", "uniqueIdentifier": NSNull()])
        XCTAssertNil(info.uniqueIdentifier)
        XCTAssertNotEqual(info.uniqueIdentifier, "<null>")
    }

    func testNSNumberIdentifierCoercedToString() {
        let info = NowPlayingInfo(adapterPayload: ["title": "T", "uniqueIdentifier": NSNumber(value: 12345)])
        XCTAssertEqual(info.uniqueIdentifier, "12345")
    }

    func testBundleIdentifierParticipatesInEquality() {
        // Same title/artist playing but reported by a different app => a real change.
        var a = NowPlayingInfo(adapterPayload: ["title": "T", "artist": "A", "bundleIdentifier": "com.x"])
        var b = NowPlayingInfo(adapterPayload: ["title": "T", "artist": "A", "bundleIdentifier": "com.y"])
        XCTAssertNotEqual(a, b)
        b = a
        XCTAssertEqual(a, b)
        // Mutate to satisfy compiler that these aren't constants in some toolchains.
        a.isPlaying.toggle()
    }

    func testIsPlayingFlipBreaksEquality() {
        let a = NowPlayingInfo(adapterPayload: ["title": "T", "playing": true])
        let b = NowPlayingInfo(adapterPayload: ["title": "T", "playing": false])
        XCTAssertNotEqual(a, b)
    }
}

final class StaleNowPlayingTests: XCTestCase {
    /// Regression: real payload observed from WhatsApp Web in Safari - the page's
    /// media session lingers after a 40ms notification ping with the page title
    /// ("(5) WhatsApp") and must never surface as an audio-player row.
    func testResidualNotificationPingHasNoContent() {
        let info = NowPlayingInfo(adapterPayload: [
            "title": "(5) WhatsApp",
            "artist": "",
            "playing": false,
            "playbackRate": 0,
            "elapsedTime": 0,
            "duration": 0.04049886621315193,
            "bundleIdentifier": "com.apple.WebKit.GPU"
        ])
        XCTAssertTrue(info.isResidualBlip)
        XCTAssertFalse(info.hasContent)
    }

    func testSubSecondDurationStillShowsWhilePlaying() {
        // Some sources misreport duration for live streams; never hide real playback.
        let info = NowPlayingInfo(adapterPayload: [
            "title": "Live Radio", "playing": true, "duration": 0.0
        ])
        XCTAssertFalse(info.isResidualBlip)
        XCTAssertTrue(info.hasContent)
    }

    func testPausedTrackWithRealDurationIsNotABlip() {
        let info = NowPlayingInfo(adapterPayload: [
            "title": "Song", "playing": false, "duration": 180.0
        ])
        XCTAssertFalse(info.isResidualBlip)
        XCTAssertTrue(info.hasContent)
    }

    func testPausedExpiryCountsFromAdapterTimestamp() {
        let pausedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let info = NowPlayingInfo(adapterPayload: [
            "title": "Song", "playing": false, "duration": 180.0,
            "timestamp": pausedAt.timeIntervalSince1970
        ])
        XCTAssertEqual(
            info.pausedExpiry()!.timeIntervalSince1970,
            pausedAt.timeIntervalSince1970 + NowPlayingInfo.pausedRetention,
            accuracy: 0.001
        )
    }

    func testPlayingMediaNeverExpires() {
        let info = NowPlayingInfo(adapterPayload: ["title": "Song", "playing": true])
        XCTAssertNil(info.pausedExpiry())
    }
}

final class ArtworkCacheTests: XCTestCase {
    /// Two same-sized TIFFs differing only in pixel content. Built from a bitmap rep
    /// rather than `lockFocus` so this runs headless (CI has no window server).
    /// Colors are device-space: a catalog color (`.red`) would need conversion and
    /// floods the log with colorspace warnings.
    private func artworkData(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for x in 0..<16 {
            for y in 0..<16 {
                rep.setColor(color, atX: x, y: y)
            }
        }
        return rep.representation(using: .tiff, properties: [:])!
    }

    func testDistinctArtworkSharingFirstEightBytesDoesNotCollide() {
        let red = artworkData(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        let blue = artworkData(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))

        // Precondition - this is exactly the case the old key got wrong: same header,
        // same length, different pixels.
        XCTAssertEqual(red.prefix(8), blue.prefix(8))
        XCTAssertNotEqual(red, blue)

        XCTAssertNotEqual(red.contentKey, blue.contentKey)

        let a = ArtworkCache.downsampled(data: red)
        let b = ArtworkCache.downsampled(data: blue)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertFalse(a === b, "distinct artwork must not resolve to one cached image")
        XCTAssertNotEqual(a?.tiffRepresentation, b?.tiffRepresentation)
    }

    func testIdenticalBytesReuseTheCachedImage() {
        // The optimization the cache exists for must survive content addressing -
        // including across tracks (album covers are shared by every track).
        let art = artworkData(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1))
        let first = ArtworkCache.downsampled(data: art)
        let second = ArtworkCache.downsampled(data: art)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "identical bytes must hit the cache")
    }

    func testContentKeyCoversEveryByteNotJustThePrefix() {
        var a = Data(repeating: 0xAB, count: 4096)
        var b = a
        b[4095] = 0x00 // last byte only
        XCTAssertEqual(a.prefix(8), b.prefix(8))
        XCTAssertNotEqual(a.contentKey, b.contentKey)
        // Stable across calls.
        XCTAssertEqual(a.contentKey, a.contentKey)
        a[0] = 0x00
        XCTAssertNotEqual(a.contentKey, b.contentKey)
    }
}

final class AppActivationParsingTests: XCTestCase {
    func testParsesPIDsFromLsofFieldOutput() {
        // `-Fp` interleaves p<pid> with f<fd> lines; only PIDs may be picked up.
        let output = "p32487\nfcwd\np45717\nfcwd\np45719\nfcwd\n"
        XCTAssertEqual(AppActivation.parseLsofPIDs(output), [32487, 45717, 45719])
    }

    func testIgnoresMalformedLsofLines() {
        XCTAssertEqual(AppActivation.parseLsofPIDs("pnotanumber\nfcwd\n\np12\n"), [12])
        XCTAssertTrue(AppActivation.parseLsofPIDs("").isEmpty)
    }

    func testParsesParentMapFromPS() {
        let output = "  501     1\n 63907   501\n 32487 63907\n"
        let map = AppActivation.parseParentMap(output)
        XCTAssertEqual(map[63907], 501)
        XCTAssertEqual(map[32487], 63907)
        XCTAssertNil(map[999])
    }

    func testWalksAncestryToTheOwningHost() {
        // agent(32487) -> zsh(63907) -> login(501) -> iTerm2(400)
        let parent: [pid_t: pid_t] = [32487: 63907, 63907: 501, 501: 400, 400: 1]
        XCTAssertEqual(
            AppActivation.firstHostAncestor(candidates: [32487], parent: parent, hosts: [400]),
            400
        )
    }

    func testPrefersTheHostThatActuallyOwnsTheProcess() {
        // Two terminals running; only 400 is in this agent's ancestry. The old
        // implementation activated whichever app ranked first in the static list.
        let parent: [pid_t: pid_t] = [32487: 63907, 63907: 400, 400: 1]
        XCTAssertEqual(
            AppActivation.firstHostAncestor(candidates: [32487], parent: parent, hosts: [400, 900]),
            400
        )
    }

    func testNoHostInAncestryReturnsNil() {
        // tmux/cmux detaches the agent from any terminal app - must fall back, not guess.
        let parent: [pid_t: pid_t] = [32487: 63907, 63907: 1925, 1925: 1]
        XCTAssertNil(
            AppActivation.firstHostAncestor(candidates: [32487], parent: parent, hosts: [400])
        )
    }

    func testCyclicAndSelfParentingInputTerminates() {
        let cyclic: [pid_t: pid_t] = [10: 11, 11: 10]
        XCTAssertNil(AppActivation.firstHostAncestor(candidates: [10], parent: cyclic, hosts: [400]))
        let selfParent: [pid_t: pid_t] = [10: 10]
        XCTAssertNil(
            AppActivation.firstHostAncestor(candidates: [10], parent: selfParent, hosts: [400])
        )
    }
}

final class NotchAnimationTests: XCTestCase {
    func testReduceMotionForcesTheMinimalVocabularyForEveryStyle() {
        let minimal = NotchAnimation.resolve(style: .minimal, reduceMotion: false)
        for style in AnimationStyle.allCases {
            let resolved = NotchAnimation.resolve(style: style, reduceMotion: true)
            XCTAssertEqual(resolved, minimal, "\(style) must collapse to minimal under Reduce Motion")
            XCTAssertFalse(resolved.allowsLooping)
            XCTAssertFalse(resolved.allowsPulse)
            XCTAssertEqual(resolved.arrivalScale, 1)
            XCTAssertFalse(resolved.arrivalSlides)
        }
    }

    func testSubtleAndDynamicAllowMotionButDiffer() {
        let subtle = NotchAnimation.resolve(style: .subtle, reduceMotion: false)
        let dynamic = NotchAnimation.resolve(style: .dynamic, reduceMotion: false)
        for m in [subtle, dynamic] {
            XCTAssertTrue(m.allowsLooping)
            XCTAssertTrue(m.allowsPulse)
            XCTAssertTrue(m.arrivalSlides)
        }
        XCTAssertNotEqual(subtle, dynamic)
        // Dynamic travels further on arrival; subtle stays restrained.
        XCTAssertLessThan(dynamic.arrivalScale, subtle.arrivalScale)
    }

    func testMinimalStyleSuppressesMotionWithoutReduceMotion() {
        let m = NotchAnimation.resolve(style: .minimal, reduceMotion: false)
        XCTAssertFalse(m.allowsLooping)
        XCTAssertFalse(m.allowsPulse)
    }

    func testGeometryIsAllowedOnlyWhenMotionIs() {
        // Drives press scale, scrub-knob growth and row slides - the size/position
        // effects Reduce Motion is actually about.
        XCTAssertTrue(NotchAnimation.resolve(style: .subtle, reduceMotion: false).allowsGeometry)
        XCTAssertTrue(NotchAnimation.resolve(style: .dynamic, reduceMotion: false).allowsGeometry)
        XCTAssertFalse(NotchAnimation.resolve(style: .minimal, reduceMotion: false).allowsGeometry)
        for style in AnimationStyle.allCases {
            XCTAssertFalse(NotchAnimation.resolve(style: style, reduceMotion: true).allowsGeometry)
        }
    }
}

@MainActor
final class AnimationStyleSettingsTests: XCTestCase {
    private func freshStore(_ name: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }

    func testDefaultIsSubtle() {
        XCTAssertEqual(freshStore("desnotch.tests.anim-default").animationStyle, .subtle)
    }

    func testPersistsAndFallsBackOnGarbage() {
        let suite = "desnotch.tests.anim-persist"
        let store = freshStore(suite)
        store.animationStyle = .dynamic
        XCTAssertEqual(SettingsStore(defaults: UserDefaults(suiteName: suite)!).animationStyle, .dynamic)

        let bad = "desnotch.tests.anim-garbage"
        let defaults = UserDefaults(suiteName: bad)!
        defaults.removePersistentDomain(forName: bad)
        defaults.set("disco", forKey: "animationStyle")
        XCTAssertEqual(SettingsStore(defaults: defaults).animationStyle, .subtle)
    }
}

final class MusicIndicatorResolverTests: XCTestCase {
    func testNoteStyleIsAlwaysNote() {
        for playing in [true, false] {
            XCTAssertEqual(
                MusicIndicatorResolver.resolve(
                    style: .note, hasArtwork: true, isPlaying: playing,
                    allowsLooping: true, privacyMode: false
                ),
                .note
            )
        }
    }

    func testEqualizerStyleFollowsPlaybackAndMotion() {
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .equalizer, hasArtwork: false, isPlaying: true,
                allowsLooping: true, privacyMode: false
            ),
            .equalizer
        )
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .equalizer, hasArtwork: false, isPlaying: false,
                allowsLooping: true, privacyMode: false
            ),
            .note
        )
        // Reduced motion never gets the animated bars.
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .equalizer, hasArtwork: false, isPlaying: true,
                allowsLooping: false, privacyMode: false
            ),
            .note
        )
    }

    func testAlbumArtNeedsArtworkAndPrivacyOff() {
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: true, isPlaying: true,
                allowsLooping: true, privacyMode: false
            ),
            .art
        )
        // No artwork -> equalizer/note fallback chain.
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: false, isPlaying: true,
                allowsLooping: true, privacyMode: false
            ),
            .equalizer
        )
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: false, isPlaying: false,
                allowsLooping: true, privacyMode: false
            ),
            .note
        )
        // Privacy mode suppresses art even when available (art identifies the track).
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: true, isPlaying: true,
                allowsLooping: true, privacyMode: true
            ),
            .equalizer
        )
    }

    func testAlbumArtRespectsReducedMotionInFallbackOnly() {
        // Art itself is static - fine under reduced motion.
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: true, isPlaying: true,
                allowsLooping: false, privacyMode: false
            ),
            .art
        )
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: false, isPlaying: true,
                allowsLooping: false, privacyMode: false
            ),
            .note
        )
    }
}

@MainActor
final class MusicIndicatorSettingsTests: XCTestCase {
    private func freshStore(_ name: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }

    func testDefaultStyleIsTheStaticNote() {
        // Deliberate: the pill is always on screen, so nothing loops by default.
        XCTAssertEqual(freshStore("desnotch.tests.indicator-default").musicIndicatorStyle, .note)
    }

    func testStylePersistsAcrossStores() {
        let suite = "desnotch.tests.indicator-persist"
        let store = freshStore(suite)
        store.musicIndicatorStyle = .albumArt
        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reloaded.musicIndicatorStyle, .albumArt)
    }

    func testGarbageStoredValueFallsBackToDefault() {
        let suite = "desnotch.tests.indicator-garbage"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("vinyl-hologram", forKey: "musicIndicatorStyle")
        XCTAssertEqual(SettingsStore(defaults: defaults).musicIndicatorStyle, .note)
    }
}

final class NowPlayingEqualizerTests: XCTestCase {
    func testBarLevelsBoundedAndDeterministic() {
        for i in 0..<NowPlayingEqualizer.barCount {
            for step in 0..<200 {
                let t = Double(step) * 0.037
                let level = NowPlayingEqualizer.barLevel(i, at: t)
                XCTAssertGreaterThanOrEqual(level, 0)
                XCTAssertLessThanOrEqual(level, 1)
                XCTAssertEqual(level, NowPlayingEqualizer.barLevel(i, at: t))
            }
        }
    }

    func testBarsMoveIndependently() {
        // Distinct frequencies/phases: at some sampled instant the bars must differ,
        // otherwise the "equalizer" would pump as one block.
        let t = 1.234
        let levels = (0..<NowPlayingEqualizer.barCount).map { NowPlayingEqualizer.barLevel($0, at: t) }
        XCTAssertGreaterThan(Set(levels.map { Int($0 * 1000) }).count, 1)
    }
}
