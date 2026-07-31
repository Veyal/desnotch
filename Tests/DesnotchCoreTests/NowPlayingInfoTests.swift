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

final class MusicIndicatorResolverTests: XCTestCase {
    func testNoteStyleIsAlwaysNote() {
        for playing in [true, false] {
            XCTAssertEqual(
                MusicIndicatorResolver.resolve(
                    style: .note, hasArtwork: true, isPlaying: playing,
                    reduceMotion: false, privacyMode: false
                ),
                .note
            )
        }
    }

    func testEqualizerStyleFollowsPlaybackAndMotion() {
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .equalizer, hasArtwork: false, isPlaying: true,
                reduceMotion: false, privacyMode: false
            ),
            .equalizer
        )
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .equalizer, hasArtwork: false, isPlaying: false,
                reduceMotion: false, privacyMode: false
            ),
            .note
        )
        // Reduced motion never gets the animated bars.
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .equalizer, hasArtwork: false, isPlaying: true,
                reduceMotion: true, privacyMode: false
            ),
            .note
        )
    }

    func testAlbumArtNeedsArtworkAndPrivacyOff() {
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: true, isPlaying: true,
                reduceMotion: false, privacyMode: false
            ),
            .art
        )
        // No artwork -> equalizer/note fallback chain.
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: false, isPlaying: true,
                reduceMotion: false, privacyMode: false
            ),
            .equalizer
        )
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: false, isPlaying: false,
                reduceMotion: false, privacyMode: false
            ),
            .note
        )
        // Privacy mode suppresses art even when available (art identifies the track).
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: true, isPlaying: true,
                reduceMotion: false, privacyMode: true
            ),
            .equalizer
        )
    }

    func testAlbumArtRespectsReducedMotionInFallbackOnly() {
        // Art itself is static - fine under reduced motion.
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: true, isPlaying: true,
                reduceMotion: true, privacyMode: false
            ),
            .art
        )
        XCTAssertEqual(
            MusicIndicatorResolver.resolve(
                style: .albumArt, hasArtwork: false, isPlaying: true,
                reduceMotion: true, privacyMode: false
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

    func testDefaultStyleIsEqualizer() {
        XCTAssertEqual(freshStore("desnotch.tests.indicator-default").musicIndicatorStyle, .equalizer)
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
        XCTAssertEqual(SettingsStore(defaults: defaults).musicIndicatorStyle, .equalizer)
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
