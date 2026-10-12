import XCTest
@testable import DesnotchCore

@MainActor
final class FakeVolumeControl: VolumeControlling {
    var level: Float?
    var adjustable = true
    private(set) var deltas: [Float] = []

    init(level: Float? = nil, adjustable: Bool = true) {
        self.level = level
        self.adjustable = adjustable
    }

    func current() -> Float? {
        level
    }

    func adjust(by delta: Float) -> Float? {
        deltas.append(delta)
        guard adjustable, let currentLevel = level else {
            return nil
        }
        let updated = min(1, max(0, currentLevel + delta))
        level = updated
        return updated
    }
}

@MainActor
final class FakeMediaTransport: MediaTransporting {
    private(set) var calls: [String] = []

    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func next() { calls.append("next") }
    func previous() { calls.append("previous") }
}

@MainActor
final class FakeTimerControl: TimerControlling {
    var active = false
    var startResult = true
    private(set) var startedMinutes: [Int] = []
    private(set) var cancelCount = 0

    var isActive: Bool { active }

    func start(minutes: Int) -> Bool {
        startedMinutes.append(minutes)
        return startResult
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
final class FakeAppLauncher: AppLaunching {
    private(set) var bundleIDs: [String] = []
    var result = true

    func launch(bundleID: String) async -> Bool {
        bundleIDs.append(bundleID)
        return result
    }
}

@MainActor
final class SystemLocalExecutorTests: XCTestCase {
    func testMediaTransportIntents() async {
        let volume = FakeVolumeControl(level: 0.5)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        let r1 = await executor.execute(.mediaPlay)
        let r2 = await executor.execute(.mediaPause)
        let r3 = await executor.execute(.mediaNext)
        let r4 = await executor.execute(.mediaPrevious)

        XCTAssertEqual(r1, .success(spoken: nil))
        XCTAssertEqual(r2, .success(spoken: nil))
        XCTAssertEqual(r3, .success(spoken: nil))
        XCTAssertEqual(r4, .success(spoken: nil))
        XCTAssertEqual(media.calls, ["play", "pause", "next", "previous"])

        XCTAssertEqual(volume.deltas.count, 0)
        XCTAssertEqual(timer.startedMinutes.count, 0)
        XCTAssertEqual(apps.bundleIDs.count, 0)
    }

    func testVolumeSetNormal() async {
        let volume = FakeVolumeControl(level: 0.5)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        let res = await executor.execute(.volumeSet(percent: 30))
        XCTAssertEqual(res, .success(spoken: "Volume 30"))
        XCTAssertEqual(volume.deltas.count, 1)
        if let delta = volume.deltas.first {
            XCTAssertEqual(delta, -0.2, accuracy: 0.0001)
        }
    }

    func testVolumeSetClampsOutOfRangePercent() async {
        let volume = FakeVolumeControl(level: 0.5)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        let resLow = await executor.execute(.volumeSet(percent: -1))
        XCTAssertEqual(resLow, .success(spoken: "Volume 0"))
        XCTAssertEqual(volume.deltas[0], -0.5, accuracy: 0.0001)

        let resHigh = await executor.execute(.volumeSet(percent: 101))
        XCTAssertEqual(resHigh, .success(spoken: "Volume 100"))
        XCTAssertEqual(volume.deltas[1], 1.0, accuracy: 0.0001)
    }

    func testVolumeStep() async {
        let volume = FakeVolumeControl(level: 0.5)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        let res = await executor.execute(.volumeStep(delta: 10))
        XCTAssertEqual(res, .success(spoken: "Volume 60"))
        XCTAssertEqual(volume.deltas.count, 1)
        XCTAssertEqual(volume.deltas[0], 0.1, accuracy: 0.0001)
    }

    func testMuteAndUnmute() async {
        let volume = FakeVolumeControl(level: 0.5)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        let muteRes = await executor.execute(.mute)
        XCTAssertEqual(muteRes, .success(spoken: "Muted"))
        XCTAssertEqual(volume.level ?? 0, 0, accuracy: 0.0001)

        let muteAgain = await executor.execute(.mute)
        XCTAssertEqual(muteAgain, .success(spoken: "Muted"))
        XCTAssertEqual(volume.deltas.count, 1)

        let unmuteRes = await executor.execute(.unmute)
        XCTAssertEqual(unmuteRes, .success(spoken: "Unmuted"))
        XCTAssertEqual(volume.level ?? 0, 0.5, accuracy: 0.0001)
    }

    func testVolumeFailuresMapToExactCodes() async {
        let volume = FakeVolumeControl(level: nil)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        let resSet = await executor.execute(.volumeSet(percent: 50))
        XCTAssertEqual(resSet, .failure(.executionFailed("volume_unavailable")))

        let resStep = await executor.execute(.volumeStep(delta: 10))
        XCTAssertEqual(resStep, .failure(.executionFailed("volume_unavailable")))

        let resMute = await executor.execute(.mute)
        XCTAssertEqual(resMute, .failure(.executionFailed("volume_unavailable")))

        let resUnmute = await executor.execute(.unmute)
        XCTAssertEqual(resUnmute, .failure(.executionFailed("volume_unavailable")))
    }

    func testOpenAppSuccessAndNotFound() async {
        let volume = FakeVolumeControl(level: 0.5)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        let resSuccess = await executor.execute(.openApp(bundleID: "com.apple.Safari", name: "Safari"))
        XCTAssertEqual(resSuccess, .success(spoken: "Opening Safari"))
        XCTAssertEqual(apps.bundleIDs, ["com.apple.Safari"])

        apps.result = false
        let resFail = await executor.execute(.openApp(bundleID: "com.missing.app", name: "Missing"))
        XCTAssertEqual(resFail, .failure(.executionFailed("app_not_found")))
    }

    func testTimerStartSuccessAndUnavailable() async {
        let volume = FakeVolumeControl(level: 0.5)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        let resSuccess = await executor.execute(.timerStart(minutes: 10))
        XCTAssertEqual(resSuccess, .success(spoken: "Timer 10 minutes"))
        XCTAssertEqual(timer.startedMinutes, [10])

        timer.startResult = false
        let resFail = await executor.execute(.timerStart(minutes: 5))
        XCTAssertEqual(resFail, .failure(.executionFailed("timer_unavailable")))
    }

    func testTimerCancelActiveAndInactive() async {
        let volume = FakeVolumeControl(level: 0.5)
        let media = FakeMediaTransport()
        let timer = FakeTimerControl()
        let apps = FakeAppLauncher()
        let executor = SystemLocalExecutor(volume: volume, media: media, timer: timer, apps: apps)

        timer.active = true
        let resActive = await executor.execute(.timerCancel)
        XCTAssertEqual(resActive, .success(spoken: "Timer cancelled"))
        XCTAssertEqual(timer.cancelCount, 1)

        timer.active = false
        let resInactive = await executor.execute(.timerCancel)
        XCTAssertEqual(resInactive, .success(spoken: "No timer running"))
        XCTAssertEqual(timer.cancelCount, 1)
    }
}
