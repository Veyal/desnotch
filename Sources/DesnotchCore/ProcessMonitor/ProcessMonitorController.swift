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
struct ProcessCPUCalculator {
    private var previous: [Int32: ProcessCPUSnapshot] = [:]
    private var previousSampleAt: TimeInterval?

    mutating func utilization(
        from snapshots: [ProcessCPUSnapshot],
        sampledAt: TimeInterval
    ) -> [(pid: Int32, cpu: Double, name: String)] {
        defer {
            previous = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
            previousSampleAt = sampledAt
        }

        guard let previousSampleAt else { return [] }
        let elapsed = sampledAt - previousSampleAt
        guard elapsed > 0 else { return [] }

        return snapshots.compactMap { current in
            guard let old = previous[current.pid],
                  old.name == current.name,
                  current.totalCPUTime >= old.totalCPUTime
            else { return nil }

            let cpu = (current.totalCPUTime - old.totalCPUTime) / elapsed * 100
            return (pid: current.pid, cpu: cpu, name: current.name)
        }
    }
}

struct ProcessHotState {
    struct Update {
        let shown: [HotProcess]
        let newlyFlagged: [HotProcess]
    }

    private let cpuThreshold: Double
    private let sustainedFor: TimeInterval
    private let maxShown: Int
    private var streaks: [Int32: (name: String, cpu: Double, since: Date)] = [:]
    private var notifiedPids: Set<Int32> = []

    init(cpuThreshold: Double = 90, sustainedFor: TimeInterval = 10 * 60, maxShown: Int = 3) {
        self.cpuThreshold = cpuThreshold
        self.sustainedFor = sustainedFor
        self.maxShown = maxShown
    }

    mutating func apply(
        sample: [(pid: Int32, cpu: Double, name: String)],
        now: Date
    ) -> Update {
        // Extend or start streaks for processes above the threshold; drop the rest.
        var next: [Int32: (name: String, cpu: Double, since: Date)] = [:]
        for process in sample where process.cpu >= cpuThreshold {
            let since = streaks[process.pid]?.since ?? now
            next[process.pid] = (process.name, process.cpu, since)
        }
        streaks = next
        notifiedPids.formIntersection(Set(next.keys))

        let flagged = next
            .filter { now.timeIntervalSince($0.value.since) >= sustainedFor }
            .map { HotProcess(pid: $0.key, name: $0.value.name, cpu: $0.value.cpu, since: $0.value.since) }
            .sorted { $0.cpu > $1.cpu }
        let newlyFlagged = flagged.filter { notifiedPids.insert($0.pid).inserted }

        return Update(shown: Array(flagged.prefix(maxShown)), newlyFlagged: newlyFlagged)
    }
}

/// Samples per-process accumulated CPU time and flags processes that stay above
/// `cpuThreshold` for at least `sustainedFor` - the "high CPU for a long time =
/// probably stuck" heuristic, but measured over a sustained window from our own
/// samples so a busy compile spike doesn't trigger it. Flagged processes surface
/// as a pill section and a one-shot notification per streak.
@MainActor
public final class ProcessMonitorController: ObservableObject {
    @Published public private(set) var hotProcesses: [HotProcess] = []

    private let sampleInterval: TimeInterval = 30
    /// Once a process is visible, refresh quickly so recovered processes disappear
    /// promptly without increasing the monitor's normal idle polling rate.
    private let hotSampleInterval: TimeInterval = 5

    private var cpuCalculator = ProcessCPUCalculator()
    private var hotState = ProcessHotState()
    private var sampleTask: Task<Void, Never>?

    public init() {
        startSampling()
    }

    private func startSampling() {
        let normalInterval = sampleInterval
        let flaggedInterval = hotSampleInterval
        sampleTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let enabled = await MainActor.run { SettingsStore.shared.processMonitorEnabled }
                let snapshots = enabled ? Self.sampleProcesses() : []
                let sampledAt = ProcessInfo.processInfo.systemUptime
                await MainActor.run { [weak self] in
                    self?.apply(snapshots: snapshots, sampledAt: sampledAt, now: Date())
                }

                let hasFlaggedProcesses = await MainActor.run { [weak self] in
                    self?.hotProcesses.isEmpty == false
                }
                let interval = hasFlaggedProcesses ? flaggedInterval : normalInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func apply(snapshots: [ProcessCPUSnapshot], sampledAt: TimeInterval, now: Date) {
        let sample = cpuCalculator.utilization(from: snapshots, sampledAt: sampledAt)
        let update = hotState.apply(sample: sample, now: now)

        for process in update.newlyFlagged {
            let minutes = Int(now.timeIntervalSince(process.since) / 60)
            AgentAttentionNotifier.shared.notify(
                title: "Process may be stuck",
                body: "\(process.name) at \(Int(process.cpu))% CPU for \(minutes)m (pid \(process.pid))"
            )
        }

        if update.shown != hotProcesses {
            hotProcesses = update.shown
        }
    }

    /// One `ps` snapshot: pid, accumulated CPU time, executable basename. Runs
    /// off the main actor; interval utilization is calculated from two snapshots.
    nonisolated private static func sampleProcesses() -> [ProcessCPUSnapshot] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,time=,comm="]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let ownPid = ProcessInfo.processInfo.processIdentifier
        var result: [ProcessCPUSnapshot] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let totalCPUTime = ProcessCPUSnapshot.parseCPUTime(parts[1]),
                  pid != ownPid
            else { continue }
            let name = URL(fileURLWithPath: String(parts[2])).lastPathComponent
            result.append(ProcessCPUSnapshot(pid: pid, totalCPUTime: totalCPUTime, name: name))
        }
        return result
    }

    deinit {
        sampleTask?.cancel()
    }
}
