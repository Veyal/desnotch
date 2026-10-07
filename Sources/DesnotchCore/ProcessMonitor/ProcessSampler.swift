import Foundation

/// Source of per-process accumulated CPU time. Injectable so the monitor's loop can be
/// tested without running `ps`.
protocol ProcessSampling: Sendable {
    /// Every process, or nil when the sample failed (timeout, truncated output, launch
    /// failure). A nil result must be skipped, never read as "no processes".
    func snapshotAll() async -> [ProcessCPUSnapshot]?
    /// Only the given pids (exited ones are simply absent), or nil on failure.
    func snapshot(pids: [Int32]) async -> [ProcessCPUSnapshot]?
}

/// `ps`-backed sampler running through `SubprocessRunner`, so every call has a timeout, an
/// output cap, a sanitized environment, and is killed on cancellation. `ps` is used instead
/// of libproc on purpose: `proc_pidinfo` cannot read root-owned processes from a user
/// session (about 30% of this machine's processes, including the usual runaway daemons
/// such as indexers), while `ps` can.
struct PSProcessSampler: ProcessSampling {
    private let runner: SubprocessRunner
    private let timeout: TimeInterval
    private let ownPID: Int32

    init(
        runner: SubprocessRunner = SubprocessRunner(outputByteCap: 1024 * 1024),
        timeout: TimeInterval = 8,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.runner = runner
        self.timeout = timeout
        self.ownPID = ownPID
    }

    func snapshotAll() async -> [ProcessCPUSnapshot]? {
        await run(["-axo", "pid=,time=,comm="])
    }

    func snapshot(pids: [Int32]) async -> [ProcessCPUSnapshot]? {
        guard !pids.isEmpty else { return [] }
        return await run(["-o", "pid=,time=,comm=", "-p", pids.map(String.init).joined(separator: ",")])
    }

    private func run(_ arguments: [String]) async -> [ProcessCPUSnapshot]? {
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: arguments,
                cwd: URL(fileURLWithPath: "/", isDirectory: true),
                timeout: timeout
            )
            // `ps -p` exits 1 when some requested pid no longer exists but still prints the
            // rest; anything else (or a truncated listing) is a failed sample.
            guard !result.truncated, result.exitCode == 0 || result.exitCode == 1 else { return nil }
            return Self.parse(result.stdout, excludingPID: ownPID)
        } catch {
            return nil
        }
    }

    /// Parses `pid= time= comm=` rows. Executable paths may contain spaces, so the third
    /// field takes the remainder of the line.
    static func parse(_ text: String, excludingPID ownPID: Int32) -> [ProcessCPUSnapshot] {
        var result: [ProcessCPUSnapshot] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let totalCPUTime = ProcessCPUSnapshot.parseCPUTime(parts[1]),
                  pid != ownPID
            else { continue }
            let name = URL(fileURLWithPath: String(parts[2])).lastPathComponent
            result.append(ProcessCPUSnapshot(pid: pid, totalCPUTime: totalCPUTime, name: name))
        }
        return result
    }
}
