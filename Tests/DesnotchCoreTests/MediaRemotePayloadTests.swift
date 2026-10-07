import XCTest
@testable import DesnotchCore

final class MediaRemotePayloadTests: XCTestCase {
    func testParsesPayload() {
        let json = #"{"type":"nowPlayingInfo","payload":{"title":"T"}}"#
        let payload = MediaRemoteBridge.payload(from: json.data(using: .utf8)!)
        XCTAssertEqual(payload?["title"] as? String, "T")
    }

    func testMissingPayloadReturnsNil() {
        let json = #"{"type":"somethingElse"}"#
        XCTAssertNil(MediaRemoteBridge.payload(from: json.data(using: .utf8)!))
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(MediaRemoteBridge.payload(from: Data([0x68, 0x65, 0x6c]))) // "hel"
    }

    func testEmptyPayloadPreserved() {
        let json = #"{"payload":{}}"#
        let payload = MediaRemoteBridge.payload(from: json.data(using: .utf8)!)
        XCTAssertEqual(payload?.count, 0)
    }

    func testEmptyGetPayloadIsAuthoritativeSuccess() {
        let json = #"{"payload":{}}"#
        XCTAssertEqual(
            MediaRemoteBridge.getResult(from: Data(json.utf8)),
            .success(nil)
        )
    }

    func testGetAcceptsAdaptersDirectPayloadShape() {
        let json = #"{"title":"Track","artist":"Artist","playing":true}"#
        guard case .success(let info) = MediaRemoteBridge.getResult(from: Data(json.utf8)) else {
            return XCTFail("expected direct get payload to decode")
        }
        XCTAssertEqual(info?.title, "Track")
        XCTAssertEqual(info?.artist, "Artist")
        XCTAssertTrue(info?.isPlaying == true)
    }

    func testDirectEmptyGetPayloadIsAuthoritativeSuccess() {
        XCTAssertEqual(MediaRemoteBridge.getResult(from: Data("{}".utf8)), .success(nil))
    }

    func testMalformedOrFailedGetIsNotAnEmptySuccess() {
        XCTAssertEqual(MediaRemoteBridge.getResult(from: Data("bad".utf8)), .failure)
        let json = #"{"payload":{}}"#
        XCTAssertEqual(
            MediaRemoteBridge.getResult(from: Data(json.utf8), terminationStatus: 1),
            .failure
        )
    }
}

final class MediaRemoteAdapterLaunchTests: XCTestCase {
    /// `Bundle.module` traps when its resource bundle is absent, so a packaged app (an
    /// incomplete bundle after an interrupted upgrade) must never reach it.
    func testModuleBundleFallbackIsOnlyForUnpackagedRuns() {
        XCTAssertFalse(MediaRemoteBridge.shouldConsultModuleBundle(bundleURL: URL(fileURLWithPath: "/Applications/desnotch.app")))
        XCTAssertTrue(MediaRemoteBridge.shouldConsultModuleBundle(bundleURL: URL(fileURLWithPath: "/Users/dev/desnotch/.build/debug")))
    }

    func testAdapterEnvironmentStripsInterpreterAndLoaderInjection() {
        let environment = MediaRemoteBridge.adapterEnvironment(base: [
            "HOME": "/tmp/home",
            "PERL5OPT": "-Mevil",
            "PERL5LIB": "/tmp/evil",
            "PERLLIB": "/tmp/evil",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "DYLD_FRAMEWORK_PATH": "/tmp/evil"
        ])
        XCTAssertEqual(environment["HOME"], "/tmp/home")
        XCTAssertNil(environment["PERL5OPT"])
        XCTAssertNil(environment["PERL5LIB"])
        XCTAssertNil(environment["PERLLIB"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["DYLD_FRAMEWORK_PATH"])
    }

    func testEveryAdapterProcessUsesTheSanitizedEnvironment() {
        let script = URL(fileURLWithPath: "/tmp/adapter/mediaremote-adapter.pl")
        let environment = MediaRemoteBridge.adapterEnvironment(base: ["PERL5OPT": "-Mevil"])
        for arguments in [["stream", "--no-diff"], ["send", "2"], ["seek", "1000000"]] {
            let process = MediaRemoteBridge.makeAdapterProcess(
                scriptURL: script,
                frameworkPath: "/tmp/adapter/MediaRemoteAdapter.framework",
                arguments: arguments,
                environment: environment
            )
            XCTAssertEqual(process.executableURL?.path, "/usr/bin/perl")
            XCTAssertEqual(
                process.arguments,
                [script.path, "/tmp/adapter/MediaRemoteAdapter.framework"] + arguments
            )
            XCTAssertNil(process.environment?["PERL5OPT"])
            XCTAssertEqual(process.environment, environment)
        }
    }

    func testBackoffDoublesAndCapsWhileAdapterKeepsDyingEarly() {
        var backoff = AdapterRestartBackoff()
        XCTAssertEqual(backoff.nextDelay(afterUptime: 0.2), 1)
        XCTAssertEqual(backoff.nextDelay(afterUptime: 0.2), 2)
        XCTAssertEqual(backoff.nextDelay(afterUptime: nil), 4)
        for _ in 0..<10 { _ = backoff.nextDelay(afterUptime: 1) }
        XCTAssertEqual(backoff.nextDelay(afterUptime: 1), AdapterRestartBackoff.maxDelay)
    }

    func testBackoffIsNotResetByLaunchAloneButByStableUptime() {
        var backoff = AdapterRestartBackoff()
        _ = backoff.nextDelay(afterUptime: 0.1)
        _ = backoff.nextDelay(afterUptime: 0.1)
        XCTAssertEqual(backoff.attempt, 2)
        // Just under the threshold still counts as a quick death.
        XCTAssertEqual(backoff.nextDelay(afterUptime: AdapterRestartBackoff.stableUptime - 0.1), 4)
        // An adapter that survived long enough starts the ladder over.
        XCTAssertEqual(backoff.nextDelay(afterUptime: AdapterRestartBackoff.stableUptime), 1)
    }

    func testBackoffResetsOnFirstValidOutputOnly() {
        var backoff = AdapterRestartBackoff()
        XCTAssertFalse(backoff.recordHealthyOutput())
        _ = backoff.nextDelay(afterUptime: 0.1)
        _ = backoff.nextDelay(afterUptime: 0.1)
        XCTAssertTrue(backoff.recordHealthyOutput())
        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertEqual(backoff.nextDelay(afterUptime: 0.1), 1)
    }
}

final class AdapterLineBufferTests: XCTestCase {
    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    func testWholeLineIsReturnedWithoutItsNewline() {
        var buffer = AdapterLineBuffer()
        XCTAssertEqual(strings(buffer.append(Data("{\"payload\":{}}\n".utf8))), ["{\"payload\":{}}"])
        XCTAssertEqual(buffer.pendingByteCount, 0)
    }

    func testPartialLineWaitsForItsNewlineAcrossReads() {
        var buffer = AdapterLineBuffer()
        XCTAssertTrue(buffer.append(Data("{\"payload\":{\"ti".utf8)).isEmpty)
        XCTAssertGreaterThan(buffer.pendingByteCount, 0)
        XCTAssertTrue(buffer.append(Data("tle\":\"T\"}".utf8)).isEmpty)
        let lines = buffer.append(Data("}\n".utf8))
        XCTAssertEqual(strings(lines), ["{\"payload\":{\"title\":\"T\"}}"])
        XCTAssertEqual(MediaRemoteBridge.payload(from: lines[0])?["title"] as? String, "T")
        XCTAssertEqual(buffer.pendingByteCount, 0)
    }

    func testSeveralLinesInOneReadComeBackInOrderAndTheTailIsKept() {
        var buffer = AdapterLineBuffer()
        let lines = buffer.append(Data("one\ntwo\nthr".utf8))
        XCTAssertEqual(strings(lines), ["one", "two"])
        XCTAssertEqual(buffer.pendingByteCount, 3)
        XCTAssertEqual(strings(buffer.append(Data("ee\n".utf8))), ["three"])
    }

    func testEmptyLinesAreDropped() {
        var buffer = AdapterLineBuffer()
        XCTAssertEqual(strings(buffer.append(Data("\n\nalpha\n\nbeta\n".utf8))), ["alpha", "beta"])
    }

    func testMultibyteCharacterSplitAcrossReadsIsReassembled() {
        // "é" is C3 A9; the pipe can deliver the two bytes in different reads.
        var buffer = AdapterLineBuffer()
        XCTAssertTrue(buffer.append(Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xC3])).isEmpty)
        let lines = buffer.append(Data([0xA9, 0x22, 0x7D, 0x0A]))
        XCTAssertEqual(strings(lines), ["{\"a\":\"\u{E9}\"}"])
    }

    func testResetDropsTheDeadAdaptersTruncatedTail() {
        // Regression: bytes left over from an adapter that died mid-line must not be glued
        // onto the replacement stream's first line.
        var buffer = AdapterLineBuffer()
        XCTAssertTrue(buffer.append(Data("{\"payload\":{\"title\":\"Tru".utf8)).isEmpty)
        buffer.reset()
        XCTAssertEqual(buffer.pendingByteCount, 0)
        let lines = buffer.append(Data("{\"payload\":{\"title\":\"Fresh\"}}\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(MediaRemoteBridge.payload(from: lines[0])?["title"] as? String, "Fresh")
    }

    func testMalformedLineStillComesBackSoTheBridgeCanLogAndSkipIt() {
        var buffer = AdapterLineBuffer()
        let lines = buffer.append(Data("not json\n{\"payload\":{}}\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertNil(MediaRemoteBridge.payload(from: lines[0]))
        XCTAssertEqual(MediaRemoteBridge.payload(from: lines[1])?.count, 0)
    }
}

final class AdapterRestartBackoffSequenceTests: XCTestCase {
    func testLadderIsOneTwoFourEightSixteenThenCapped() {
        var backoff = AdapterRestartBackoff()
        let delays = (0..<8).map { _ in backoff.nextDelay(afterUptime: 0.1) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testFailedLaunchesClimbTheLadderAndNeverResetIt() {
        var backoff = AdapterRestartBackoff()
        XCTAssertEqual(backoff.nextDelay(afterUptime: nil), 1)
        XCTAssertEqual(backoff.nextDelay(afterUptime: nil), 2)
        XCTAssertEqual(backoff.nextDelay(afterUptime: nil), 4)
        XCTAssertEqual(backoff.attempt, 3)
    }

    func testHealthyOutputThenAnImmediateCrashStartsBackAtOneSecond() {
        var backoff = AdapterRestartBackoff()
        _ = backoff.nextDelay(afterUptime: 0.1)
        _ = backoff.nextDelay(afterUptime: 0.1)
        _ = backoff.nextDelay(afterUptime: 0.1)
        XCTAssertTrue(backoff.recordHealthyOutput())
        XCTAssertFalse(backoff.recordHealthyOutput(), "only the first line of a recovery reports it")
        XCTAssertEqual(backoff.nextDelay(afterUptime: 0.1), 1)
    }

    func testAnAdapterThatLivedLongEnoughRestartsQuicklyEvenAfterAFailureStreak() {
        var backoff = AdapterRestartBackoff()
        for _ in 0..<6 { _ = backoff.nextDelay(afterUptime: 0.1) }
        XCTAssertEqual(backoff.nextDelay(afterUptime: 3600), 1)
        XCTAssertEqual(backoff.nextDelay(afterUptime: 0.1), 2)
    }

    func testDelayStaysCappedAfterManyConsecutiveFailures() {
        var backoff = AdapterRestartBackoff()
        var last: TimeInterval = 0
        for _ in 0..<5_000 { last = backoff.nextDelay(afterUptime: 0) }
        XCTAssertEqual(last, AdapterRestartBackoff.maxDelay)
    }
}
