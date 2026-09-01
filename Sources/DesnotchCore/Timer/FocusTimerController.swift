import Combine
import Foundation

/// The lifecycle of the session-scoped focus timer.
public enum FocusTimerState: Hashable {
    case idle
    case running
    case paused
    case completed
}

/// A completion event. The token is unique for every completed run and is
/// intentionally transient; callers can use it to trigger a one-shot flash or
/// sound without persisting timer data.
public struct FocusTimerCompletion: Equatable {
    public let token: UUID
    public let duration: TimeInterval
    public let completedAt: Date

    public init(token: UUID, duration: TimeInterval, completedAt: Date) {
        self.token = token
        self.duration = duration
        self.completedAt = completedAt
    }
}

/// A small scheduling seam keeps the controller's state machine deterministic
/// in tests. Production scheduling uses one delayed work item, never a ticking
/// timer; the UI derives the live countdown from `endDate` with TimelineView.
protocol FocusTimerScheduling: AnyObject {
    func schedule(at date: Date, action: @escaping () -> Void) -> FocusTimerScheduledTask
}

protocol FocusTimerScheduledTask: AnyObject {
    func cancel()
}

private final class RunLoopScheduledTask: FocusTimerScheduledTask {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// A wall-clock timer is important here: `DispatchTime` is uptime-based and can leave a
/// focus session "running" after its absolute deadline when the Mac slept through it.
/// A non-repeating Foundation timer scheduled for the actual Date fires on the first run
/// loop pass after wake, matching the Date-derived countdown shown by the UI.
private final class RunLoopFocusTimerScheduler: FocusTimerScheduling {
    func schedule(at date: Date, action: @escaping () -> Void) -> FocusTimerScheduledTask {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            action()
        }
        RunLoop.main.add(timer, forMode: .common)
        return RunLoopScheduledTask(timer: timer)
    }
}

/// Owns one optional, session-scoped focus timer.
///
/// The deadline is absolute, so the countdown does not drift while the app is
/// busy or suspended. There is no persistence, polling loop, or permission
/// required. A caller may use `onCompletion` or observe `completion` to drive
/// presentation feedback.
@MainActor
public final class FocusTimerController: ObservableObject {
    @Published public private(set) var state: FocusTimerState = .idle
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var endDate: Date?
    @Published public private(set) var completion: FocusTimerCompletion?

    private let now: () -> Date
    private let scheduler: FocusTimerScheduling
    private var scheduledTask: FocusTimerScheduledTask?
    private var pausedRemaining: TimeInterval?
    private var generation = 0

    public var onCompletion: ((FocusTimerCompletion) -> Void)?

    public convenience init() {
        self.init(now: Date.init, scheduler: RunLoopFocusTimerScheduler())
    }

    init(now: @escaping () -> Date, scheduler: FocusTimerScheduling) {
        self.now = now
        self.scheduler = scheduler
    }

    public var isActive: Bool {
        state == .running || state == .paused
    }

    /// Remaining time is derived from the absolute deadline while running.
    /// Values are clamped so a late UI render never displays a negative value.
    public var remaining: TimeInterval {
        switch state {
        case .running:
            guard let endDate else { return 0 }
            return max(0, endDate.timeIntervalSince(now()))
        case .paused:
            return max(0, pausedRemaining ?? 0)
        case .idle, .completed:
            return 0
        }
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / duration))
    }

    /// Starts a fresh run. Starting while another run is active replaces it.
    @discardableResult
    public func start(duration: TimeInterval) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        invalidateSchedule()
        generation += 1
        completion = nil
        self.duration = duration
        pausedRemaining = nil
        endDate = now().addingTimeInterval(duration)
        state = .running
        scheduleCompletion(for: endDate!, generation: generation)
        return true
    }

    public func pause() {
        guard state == .running else { return }
        let remaining = remaining
        if remaining <= 0 {
            invalidateSchedule()
            finishIfCurrent(generation: generation)
            return
        }
        pausedRemaining = remaining
        endDate = nil
        state = .paused
        invalidateSchedule()
        generation += 1
    }

    public func resume() {
        guard state == .paused, let pausedRemaining else { return }
        if pausedRemaining <= 0 {
            state = .running
            finishIfCurrent(generation: generation)
            return
        }
        generation += 1
        let deadline = now().addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
        endDate = deadline
        state = .running
        scheduleCompletion(for: deadline, generation: generation)
    }

    public func cancel() {
        invalidateSchedule()
        generation += 1
        state = .idle
        duration = 0
        endDate = nil
        pausedRemaining = nil
        completion = nil
    }

    public func reset() {
        cancel()
    }

    private func scheduleCompletion(for deadline: Date, generation scheduledGeneration: Int) {
        scheduledTask = scheduler.schedule(at: deadline) { [weak self] in
            MainActor.assumeIsolated {
                self?.finishIfCurrent(generation: scheduledGeneration)
            }
        }
    }

    private func finishIfCurrent(generation scheduledGeneration: Int) {
        guard generation == scheduledGeneration, state == .running else { return }
        let event = FocusTimerCompletion(
            token: UUID(),
            duration: duration,
            completedAt: now()
        )
        scheduledTask = nil
        endDate = nil
        pausedRemaining = nil
        state = .completed
        completion = event
        onCompletion?(event)
    }

    private func invalidateSchedule() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    deinit {
        scheduledTask?.cancel()
    }
}
