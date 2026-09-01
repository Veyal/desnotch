import XCTest
@testable import DesnotchCore

@MainActor
final class FocusTimerControllerTests: XCTestCase {
    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private final class Task: FocusTimerScheduledTask {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private final class Scheduler: FocusTimerScheduling {
        struct Entry {
            let date: Date
            let task: Task
            let action: () -> Void
        }
        var entries: [Entry] = []

        func schedule(at date: Date, action: @escaping () -> Void) -> FocusTimerScheduledTask {
            let task = Task()
            entries.append(Entry(date: date, task: task, action: action))
            return task
        }

        var scheduleCount: Int { entries.count }

        func fireLatest() {
            guard let entry = entries.last else { return }
            guard !entry.task.cancelled else { return }
            entry.action()
        }
    }

    func testStartUsesAbsoluteDeadlineAndDerivedProgress() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let scheduler = Scheduler()
        let controller = FocusTimerController(now: { clock.date }, scheduler: scheduler)

        XCTAssertTrue(controller.start(duration: 60))
        XCTAssertEqual(controller.endDate, Date(timeIntervalSince1970: 1_060))
        clock.date = Date(timeIntervalSince1970: 1_030)
        XCTAssertEqual(controller.remaining, 30, accuracy: 0.001)
        XCTAssertEqual(controller.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(scheduler.scheduleCount, 1)
    }

    func testPauseResumeSchedulesOneNewDeadlineWithoutDrift() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let scheduler = Scheduler()
        let controller = FocusTimerController(now: { clock.date }, scheduler: scheduler)
        XCTAssertTrue(controller.start(duration: 60))

        clock.date = Date(timeIntervalSince1970: 1_025)
        controller.pause()
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.remaining, 35, accuracy: 0.001)
        XCTAssertEqual(scheduler.scheduleCount, 1)

        clock.date = Date(timeIntervalSince1970: 2_000)
        controller.resume()
        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(controller.endDate, Date(timeIntervalSince1970: 2_035))
        XCTAssertEqual(scheduler.scheduleCount, 2)
    }

    func testCompletionPublishesTransientTokenAndCallback() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let scheduler = Scheduler()
        let controller = FocusTimerController(now: { clock.date }, scheduler: scheduler)
        var received: FocusTimerCompletion?
        controller.onCompletion = { received = $0 }
        XCTAssertTrue(controller.start(duration: 5))

        clock.date = Date(timeIntervalSince1970: 1_005)
        scheduler.fireLatest()

        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.remaining, 0)
        XCTAssertEqual(controller.completion, received)
        XCTAssertEqual(received?.duration, 5)
        XCTAssertNotNil(received?.token)
    }

    func testCancelInvalidatesCompletionAndClearsState() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let scheduler = Scheduler()
        let controller = FocusTimerController(now: { clock.date }, scheduler: scheduler)
        XCTAssertTrue(controller.start(duration: 5))
        controller.cancel()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.duration, 0)
        XCTAssertNil(controller.endDate)
        XCTAssertNil(controller.completion)
        scheduler.fireLatest()
        XCTAssertEqual(controller.state, .idle)
    }

    func testRejectsNonPositiveOrNonFiniteDurations() {
        let controller = FocusTimerController(now: Date.init, scheduler: Scheduler())
        XCTAssertFalse(controller.start(duration: 0))
        XCTAssertFalse(controller.start(duration: -1))
        XCTAssertFalse(controller.start(duration: .infinity))
        XCTAssertEqual(controller.state, .idle)
    }
}
