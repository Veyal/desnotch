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

/// Samples per-process CPU via `ps` and flags processes that stay above
/// `cpuThreshold` for at least `sustainedFor` - the "high CPU for a long time =
/// probably stuck" heuristic, but measured over a sustained window from our own
/// samples so a busy compile spike doesn't trigger it. Flagged processes surface
/// as a pill section and a one-shot notification per streak.
@MainActor
public final class ProcessMonitorController: ObservableObject {
    @Published public private(set) var hotProcesses: [HotProcess] = []

    /// CPU% a process must sustain to be considered hot. >=90 catches the classic
    /// single-core spin loop without flagging normally-busy apps.
    private let cpuThreshold = 90.0
    /// How long the streak must last before the process is flagged.
    private let sustainedFor: TimeInterval = 10 * 60
    private let sampleInterval: TimeInterval = 30
    /// Show at most this many rows; sorted by CPU descending.
    private let maxShown = 3

    private var streaks: [Int32: (name: String, cpu: Double, since: Date)] = [:]
    private var notifiedPids: Set<Int32> = []
    private var sampleTask: Task<Void, Never>?

    public init() {
        startSampling()
    }

    private func startSampling() {
        let interval = sampleInterval
        sampleTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let enabled = await MainActor.run { SettingsStore.shared.processMonitorEnabled }
                if enabled {
                    let sample = Self.sampleProcesses()
                    await MainActor.run { [weak self] in
                        self?.apply(sample: sample, now: Date())
                    }
                } else {
                    // Disabled: no `ps` spawns; drop any leftover flags so re-enabling
                    // starts from a clean slate.
                    await MainActor.run { [weak self] in
                        self?.apply(sample: [], now: Date())
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    private func apply(sample: [(pid: Int32, cpu: Double, name: String)], now: Date) {
        // Extend or start streaks for processes above the threshold; drop the rest.
        var next: [Int32: (name: String, cpu: Double, since: Date)] = [:]
        for proc in sample where proc.cpu >= cpuThreshold {
            let since = streaks[proc.pid]?.since ?? now
            next[proc.pid] = (proc.name, proc.cpu, since)
        }
        streaks = next
        notifiedPids.formIntersection(Set(next.keys))

        let flagged = next
            .filter { now.timeIntervalSince($0.value.since) >= sustainedFor }
            .map { HotProcess(pid: $0.key, name: $0.value.name, cpu: $0.value.cpu, since: $0.value.since) }
            .sorted { $0.cpu > $1.cpu }

        for proc in flagged where !notifiedPids.contains(proc.pid) {
            notifiedPids.insert(proc.pid)
            let minutes = Int(now.timeIntervalSince(proc.since) / 60)
            AgentAttentionNotifier.shared.notify(
                title: "Process may be stuck",
                body: "\(proc.name) at \(Int(proc.cpu))% CPU for \(minutes)m (pid \(proc.pid))"
            )
        }

        let shown = Array(flagged.prefix(maxShown))
        if shown != hotProcesses {
            hotProcesses = shown
        }
    }

    /// One `ps` snapshot: pid, %CPU, executable basename. Runs off the main actor.
    nonisolated private static func sampleProcesses() -> [(pid: Int32, cpu: Double, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,comm="]
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
        var result: [(pid: Int32, cpu: Double, name: String)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                let pid = Int32(parts[0]),
                let cpu = Double(parts[1]),
                pid != ownPid
            else { continue }
            let name = URL(fileURLWithPath: String(parts[2])).lastPathComponent
            result.append((pid: pid, cpu: cpu, name: name))
        }
        return result
    }

    deinit {
        sampleTask?.cancel()
    }
}
