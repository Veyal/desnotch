import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceTimersTests: XCTestCase {
    func testRealSchedulerFiresExactlyOnce() {
        let scheduler = RunLoopTimerScheduler()
        let fired = expectation(description: "timer fired")
        var count = 0
        _ = scheduler.schedule(after: 0.01) {
            count += 1
            fired.fulfill()
        }
        wait(for: [fired], timeout: 1)
        drainMainQueue()
        drainMainQueue()
        XCTAssertEqual(count, 1)
    }

    func testCancelledTimerNeverFires() {
        let scheduler = RunLoopTimerScheduler()
        var count = 0
        let handle = scheduler.schedule(after: 0.01) { count += 1 }
        handle.cancel()
        let sentinel = expectation(description: "sentinel fired")
        _ = scheduler.schedule(after: 0.03) { sentinel.fulfill() }
        wait(for: [sentinel], timeout: 1)
        XCTAssertEqual(count, 0)
    }

    func testCancelTwiceIsHarmless() {
        let scheduler = RunLoopTimerScheduler()
        var count = 0
        let handle = scheduler.schedule(after: 0.01) { count += 1 }
        handle.cancel()
        handle.cancel()
        let sentinel = expectation(description: "sentinel fired")
        _ = scheduler.schedule(after: 0.03) { sentinel.fulfill() }
        wait(for: [sentinel], timeout: 1)
        XCTAssertEqual(count, 0)
    }

    func testManualSchedulerFireSkipsCancelledTimers() {
        let scheduler = CoordManualTimerScheduler()
        var ran: [Int] = []
        let first = scheduler.schedule(after: 1) { ran.append(1) }
        _ = scheduler.schedule(after: 2) { ran.append(2) }
        first.cancel()
        scheduler.fire(index: 0)
        scheduler.fire(index: 1)
        XCTAssertEqual(ran, [2])
        XCTAssertEqual(scheduler.cancelledCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testManualSchedulerFireLatestPicksTheNewestPending() {
        let scheduler = CoordManualTimerScheduler()
        var ran: [Int] = []
        _ = scheduler.schedule(after: 1) { ran.append(1) }
        _ = scheduler.schedule(after: 2) { ran.append(2) }
        scheduler.fireLatest()
        XCTAssertEqual(ran, [2])
        scheduler.fireLatest()
        XCTAssertEqual(ran, [2, 1])
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(scheduler.scheduled, [1, 2])
    }
}

/// Test double for `VoiceTimerScheduling`. It never learns `(kind, generation)`; the coordinator keys handles.
@MainActor
final class CoordManualTimerScheduler: VoiceTimerScheduling {
    private struct Entry {
        var seconds: Double
        var action: @MainActor () -> Void
        var cancelled = false
        var fired = false
    }

    private var entries: [Entry] = []
    private(set) var scheduled: [Double] = []
    private(set) var cancelledCount = 0

    var pendingCount: Int {
        entries.filter { !$0.cancelled && !$0.fired }.count
    }

    func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> VoiceTimerHandle {
        scheduled.append(seconds)
        entries.append(Entry(seconds: seconds, action: action))
        let index = entries.count - 1
        let handle = Handle()
        handle.onCancel = { [weak self] in
            self?.cancel(index: index)
        }
        return handle
    }

    func fire(index: Int) {
        guard entries.indices.contains(index) else { return }
        guard !entries[index].cancelled, !entries[index].fired else { return }
        entries[index].fired = true
        entries[index].action()
    }

    func fireLatest() {
        guard let index = entries.indices.reversed().first(where: { index in
            !entries[index].cancelled && !entries[index].fired
        }) else { return }
        fire(index: index)
    }

    func fireAll() {
        for index in entries.indices {
            fire(index: index)
        }
    }

    private func cancel(index: Int) {
        guard entries.indices.contains(index), !entries[index].cancelled else { return }
        entries[index].cancelled = true
        cancelledCount += 1
    }

    @MainActor
    private final class Handle: VoiceTimerHandle {
        var onCancel: (@MainActor () -> Void)?

        func cancel() {
            let action = onCancel
            onCancel = nil
            action?()
        }
    }
}
