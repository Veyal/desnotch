import Combine
import Foundation

/// A process flagged as presumed-stuck: sustained high CPU for many minutes.
public struct HotProcess: Equatable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    /// Latest sampled CPU percentage (can exceed 100 for multi-threaded processes).
    public let cpu: Double
    /// When the sustained high-CPU streak started (from our own sampling).
    public let since: Date

    public init(pid: Int32, name: String, cpu: Double, since: Date) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.since = since
    }
}

/// One process's accumulated CPU time at a point in time.
struct ProcessCPUSnapshot: Equatable {
    let pid: Int32
    let totalCPUTime: TimeInterval
    let name: String

    /// macOS `ps time` is normally `minutes:seconds.hundredths`, with minutes
    /// allowed to exceed 59. Accept the longer BSD forms as well.
    static func parseCPUTime(_ rawValue: Substring) -> TimeInterval? {
        let dayParts = rawValue.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard dayParts.count == 1 || dayParts.count == 2 else { return nil }

        let days: Double
        let clock: Substring
        if dayParts.count == 2 {
            guard let parsedDays = Double(dayParts[0]), parsedDays >= 0 else { return nil }
            days = parsedDays
            clock = dayParts[1]
        } else {
            days = 0
            clock = dayParts[0]
        }

        let fields = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3,
              let seconds = Double(fields[fields.count - 1]),
              let minutes = Double(fields[fields.count - 2]),
              seconds >= 0, seconds < 60, minutes >= 0
        else { return nil }

        let hours: Double
        if fields.count == 3 {
            guard minutes < 60, let parsedHours = Double(fields[0]), parsedHours >= 0 else { return nil }
            hours = parsedHours
        } else {
            hours = 0
        }

        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }
}

/// Derives utilization over the latest sampling interval from accumulated CPU
/// time. Unlike `ps %cpu`, this has no decaying one-minute history, so a process
/// that stops using CPU reads as cool on the very next sample.
///
/// Each pid remembers when it was last sampled, so a quick refresh of only the
/// flagged pids (`isPartial`) and a later full scan can interleave without distorting
/// each other's intervals.
struct ProcessCPUCalculator {
    private var previous: [Int32: (snapshot: ProcessCPUSnapshot, sampledAt: TimeInterval)] = [:]

    /// `isPartial` marks a sample of a pid subset: it updates just those pids instead of
    /// replacing the whole baseline.
    mutating func utilization(
        from snapshots: [ProcessCPUSnapshot],
        sampledAt: TimeInterval,
        isPartial: Bool = false
    ) -> [(pid: Int32, cpu: Double, name: String)] {
        defer {
            let fresh = snapshots.map { ($0.pid, (snapshot: $0, sampledAt: sampledAt)) }
            if isPartial {
                for (pid, entry) in fresh { previous[pid] = entry }
            } else {
                previous = Dictionary(fresh, uniquingKeysWith: { _, latest in latest })
            }
        }

        return snapshots.compactMap { current in
            guard let old = previous[current.pid],
                  old.snapshot.name == current.name,
                  current.totalCPUTime >= old.snapshot.totalCPUTime
            else { return nil }
            let elapsed = sampledAt - old.sampledAt
            guard elapsed > 0 else { return nil }

            let cpu = (current.totalCPUTime - old.snapshot.totalCPUTime) / elapsed * 100
            return (pid: current.pid, cpu: cpu, name: current.name)
        }
    }

    mutating func reset() {
        previous = [:]
    }
}

struct ProcessHotState {
    struct Update {
        let shown: [HotProcess]
        let newlyFlagged: [HotProcess]
        /// How long each flagged pid's streak has run, on the same clock that flagged it.
        let ages: [Int32: TimeInterval]
    }

    private let cpuThreshold: Double
    private let sustainedFor: TimeInterval
    private let maxShown: Int
    /// `since` is the wall-clock start (display only); `sinceUptime` is the monotonic start
    /// that the sustained-for test uses, so a clock step cannot age or rewind a streak. The
    /// CPU intervals themselves already come from `systemUptime`.
    private var streaks: [Int32: (name: String, cpu: Double, since: Date, sinceUptime: TimeInterval?)] = [:]
    private var notifiedPids: Set<Int32> = []

    init(cpuThreshold: Double = 90, sustainedFor: TimeInterval = 10 * 60, maxShown: Int = 3) {
        self.cpuThreshold = cpuThreshold
        self.sustainedFor = sustainedFor
        self.maxShown = maxShown
    }

    /// `queried` is the pid subset a partial refresh looked at: streaks of other pids are
    /// left untouched, while queried pids missing from `sample` (exited or cooled) are dropped.
    /// `nil` means the sample covered every process.
    mutating func apply(
        sample: [(pid: Int32, cpu: Double, name: String)],
        now: Date,
        uptime: TimeInterval? = nil,
        queried: Set<Int32>? = nil
    ) -> Update {
        // Extend or start streaks for processes above the threshold; drop the rest.
        var next: [Int32: (name: String, cpu: Double, since: Date, sinceUptime: TimeInterval?)] = [:]
        if let queried {
            for (pid, streak) in streaks where !queried.contains(pid) { next[pid] = streak }
        }
        for process in sample where process.cpu >= cpuThreshold {
            // A reused PID belongs to a new streak when the executable name changes.
            // Carrying the previous `since` across PID reuse could flag a brand-new
            // process immediately.
            let previous = streaks[process.pid]
            let continued = previous?.name == process.name ? previous : nil
            next[process.pid] = (
                process.name, process.cpu, continued?.since ?? now, continued?.sinceUptime ?? uptime
            )
        }
        streaks = next
        notifiedPids.formIntersection(Set(next.keys))

        func age(_ streak: (name: String, cpu: Double, since: Date, sinceUptime: TimeInterval?)) -> TimeInterval {
            if let uptime, let sinceUptime = streak.sinceUptime { return uptime - sinceUptime }
            return now.timeIntervalSince(streak.since)
        }
        let ages = next.mapValues(age)
        let flagged = next
            .filter { age($0.value) >= sustainedFor }
            .map { HotProcess(pid: $0.key, name: $0.value.name, cpu: $0.value.cpu, since: $0.value.since) }
            .sorted { $0.cpu > $1.cpu }
        let newlyFlagged = flagged.filter { notifiedPids.insert($0.pid).inserted }

        return Update(shown: Array(flagged.prefix(maxShown)), newlyFlagged: newlyFlagged, ages: ages)
    }

    mutating func reset() {
        streaks = [:]
        notifiedPids = []
    }
}

/// Samples per-process accumulated CPU time and flags processes that stay above
/// `cpuThreshold` for at least `sustainedFor` - the "high CPU for a long time =
/// probably stuck" heuristic, but measured over a sustained window from our own
/// samples so a busy compile spike doesn't trigger it. Flagged processes surface
/// as a pill section and a one-shot notification per streak.
///
/// The loop runs only while the setting is on and `PollingActivity` is not suspended
/// (display/system asleep, session inactive). A full `ps` scan runs every
/// `sampleInterval`; while processes are flagged, the quick refresh in between samples
/// just those pids so recovery shows up in seconds without re-listing everything.
@MainActor
public final class ProcessMonitorController: ObservableObject {
    @Published public private(set) var hotProcesses: [HotProcess] = []

    private let sampleInterval: TimeInterval
    /// Once a process is visible, refresh quickly so recovered processes disappear
    /// promptly without increasing the monitor's normal idle polling rate.
    private let hotSampleInterval: TimeInterval

    private let settings: SettingsStore
    private let activity: PollingActivity
    private let sampler: ProcessSampling
    private let notify: (String, String) -> Void
    private var cpuCalculator = ProcessCPUCalculator()
    private var hotState = ProcessHotState()
    private var sampleTask: Task<Void, Never>?
    private var lastFullScanAt: TimeInterval?
    private var isEnabled = false
    private var isSuspended = false
    private var cancellables = Set<AnyCancellable>()

    public convenience init() {
        self.init(settings: .shared, activity: .shared, sampler: PSProcessSampler())
    }

    /// Internal injection point so tests can drive sampling without running `ps`.
    init(
        settings: SettingsStore,
        activity: PollingActivity,
        sampler: ProcessSampling,
        sampleInterval: TimeInterval = 30,
        hotSampleInterval: TimeInterval = 5,
        notify: @escaping (String, String) -> Void = { title, body in
            AgentAttentionNotifier.shared.notify(title: title, body: body)
        }
    ) {
        self.settings = settings
        self.activity = activity
        self.sampler = sampler
        self.sampleInterval = sampleInterval
        self.hotSampleInterval = hotSampleInterval
        self.notify = notify

        settings.$processMonitorEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.isEnabled = enabled
                if !enabled { self.reset() }
                self.updateSampling()
            }
            .store(in: &cancellables)
        activity.$isSuspended
            .removeDuplicates()
            .sink { [weak self] suspended in
                guard let self else { return }
                let wasSuspended = self.isSuspended
                self.isSuspended = suspended
                // Streaks are measured on the wall clock but CPU time stops during sleep, so
                // a streak that began before the lid closed would read as 10+ minutes on the
                // first post-wake sample. Start again from fresh baselines on resume.
                if wasSuspended && !suspended { self.reset() }
                self.updateSampling()
            }
            .store(in: &cancellables)
    }

    /// Internal so tests can assert the loop follows the setting and the sleep gate.
    var isSampling: Bool { sampleTask != nil }

    private func updateSampling() {
        if isEnabled && !isSuspended {
            guard sampleTask == nil else { return }
            sampleTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let delay = await self?.sampleOnce() else { return }
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        } else {
            sampleTask?.cancel()
            sampleTask = nil
        }
    }

    /// Disabled in Settings or resumed after sleep: forget baselines and streaks so the next
    /// sample starts clean instead of reporting a streak that spans the time the monitor was off.
    private func reset() {
        cpuCalculator.reset()
        hotState.reset()
        lastFullScanAt = nil
        if !hotProcesses.isEmpty { hotProcesses = [] }
    }

    /// One sample; returns how long to wait before the next one.
    private func sampleOnce() async -> TimeInterval {
        let flaggedPIDs = hotProcesses.map(\.pid)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let isFullScan = flaggedPIDs.isEmpty
            || lastFullScanAt.map { startedAt - $0 >= sampleInterval } ?? true

        let snapshots = isFullScan
            ? await sampler.snapshotAll()
            : await sampler.snapshot(pids: flaggedPIDs)
        // Cancelled mid-sample (setting turned off, display asleep): the result is stale.
        // A failed sample (nil) is skipped rather than read as "no processes", which would
        // wipe every baseline and streak on one slow `ps`.
        if !Task.isCancelled, let snapshots {
            let sampledAt = ProcessInfo.processInfo.systemUptime
            if isFullScan { lastFullScanAt = sampledAt }
            apply(
                snapshots: snapshots,
                sampledAt: sampledAt,
                now: Date(),
                queried: isFullScan ? nil : Set(flaggedPIDs)
            )
        }
        return activity.scaled(hotProcesses.isEmpty ? sampleInterval : hotSampleInterval)
    }

    func apply(
        snapshots: [ProcessCPUSnapshot],
        sampledAt: TimeInterval,
        now: Date,
        queried: Set<Int32>? = nil
    ) {
        let sample = cpuCalculator.utilization(from: snapshots, sampledAt: sampledAt, isPartial: queried != nil)
        let update = hotState.apply(sample: sample, now: now, uptime: sampledAt, queried: queried)

        for process in update.newlyFlagged where settings.notifyStuckProcess {
            let minutes = Int((update.ages[process.pid] ?? now.timeIntervalSince(process.since)) / 60)
            notify(
                "Process may be stuck",
                "\(process.name) at \(Int(process.cpu))% CPU for \(minutes)m (pid \(process.pid))"
            )
        }

        if update.shown != hotProcesses {
            hotProcesses = update.shown
        }
    }

    deinit {
        sampleTask?.cancel()
    }
}
