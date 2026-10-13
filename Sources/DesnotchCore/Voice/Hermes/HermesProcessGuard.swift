import Darwin
import Foundation

/// `ensureRunning`'s only error type. The backend maps `.backoff` to `agentFailed("backoff")`
/// and `.spawnFailed` to `agentFailed("spawn_failed")`.
enum HermesGuardError: Error, Equatable {
    case backoff
    case spawnFailed
}

/// Owns the ACP child: one process, one pid file, one restart ladder.
/// One `NSLock` covers `current`, the backoff and `retryNotBefore`, and it is never held
/// across start, send, terminate, ps, kill, a wait, or file IO.
/// This type has no `deinit`: a dropped guard is a simulated crash and must leave the child running.
final class HermesProcessGuard: @unchecked Sendable {
    private struct Current {
        var transport: ACPTransport
        var generation: Int
        /// The spawned leader's start time, read right after spawn. The pid fallback in `signal`
        /// only fires while the pid still names this exact process.
        var identity: ProcessIdentity?
    }

    /// A process start time to the microsecond: a reused pid gets a different one.
    struct ProcessIdentity: Equatable {
        var seconds: UInt64
        var microseconds: UInt64
    }

    private let lock = NSLock()
    private let launch: @Sendable () -> ACPLaunch?
    private let pidFileDirectory: URL
    private let workingDirectoryRoot: URL
    private let transportFactory: @Sendable (ACPLaunch, URL) -> ACPTransport
    private let now: @Sendable () -> Date
    private let killGroup: @Sendable (Int32, Int32) -> Int32
    private var current: Current?
    private var generation = 0
    private var backoff = AdapterRestartBackoff()
    private var retryNotBefore: Date?

    init(
        launch: @escaping @Sendable () -> ACPLaunch?,
        pidFileDirectory: URL,
        workingDirectoryRoot: URL,
        transportFactory: @escaping @Sendable (ACPLaunch, URL) -> ACPTransport = {
            ProcessACPTransport(launch: $0, workingDirectoryRoot: $1)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        killGroup: @escaping @Sendable (_ pgid: Int32, _ signal: Int32) -> Int32 = { Darwin.killpg($0, $1) }
    ) {
        self.launch = launch
        self.pidFileDirectory = pidFileDirectory
        self.workingDirectoryRoot = workingDirectoryRoot
        self.transportFactory = transportFactory
        self.now = now
        self.killGroup = killGroup
    }

    func ensureRunning() throws -> ACPTransport {
        if let existing = try existingOrBackoff() { return existing }
        recoverStalePidFile()
        guard let resolved = launch() else { throw HermesGuardError.spawnFailed }
        let transport = transportFactory(resolved, workingDirectoryRoot)
        let token = register(transport)
        do {
            try transport.start()
        } catch {
            drop(generation: token)
            throw HermesGuardError.spawnFailed
        }
        if !isCurrent(token) {
            transport.terminate()
            throw HermesGuardError.spawnFailed
        }
        recordIdentity(transport.processID.flatMap(Self.identity(of:)), generation: token)
        writePidFile(for: transport)
        return transport
    }

    var liveTransport: ACPTransport? {
        lock.lock()
        defer { lock.unlock() }
        return current?.transport
    }

    func markHealthy() {
        lock.lock()
        _ = backoff.recordHealthyOutput()
        lock.unlock()
    }

    func hardStop(sendCancel: @Sendable () -> Void) async -> EmergencyStopReport {
        let taken = takeCurrent()
        guard let taken else {
            sendCancel()
            return EmergencyStopReport()
        }
        let transport = taken.transport
        guard let pid = transport.processID else {
            sendCancel()
            transport.terminate()
            return EmergencyStopReport()
        }
        let identity = taken.identity ?? Self.identity(of: pid)
        let descendants = Self.descendants(of: pid)
        sendCancel()
        Self.pause(until: { false }, seconds: VoiceTiming.hardStopGrace)
        _ = signal(pid, SIGTERM, identity: identity)
        Self.pause(until: { false }, seconds: 0.5)
        _ = signal(pid, SIGKILL, identity: identity)
        Self.pause(until: { !descendants.contains(where: Self.alive) }, seconds: 0.5)
        let survivors = descendants.filter(Self.alive).map(Self.processName)
        transport.terminate()
        deletePidFile(matching: pid)
        return EmergencyStopReport(survivors: survivors)
    }

    func terminate(_ transport: ACPTransport) {
        if isCurrentTransport(transport) {
            terminateNow()
            return
        }
        transport.terminate()
    }

    func terminateNow() {
        guard let taken = takeCurrent() else { return }
        let transport = taken.transport
        if let pid = transport.processID, Self.alive(pid) {
            let identity = taken.identity ?? Self.identity(of: pid)
            _ = signal(pid, SIGTERM, identity: identity)
            Self.pause(until: { !Self.alive(pid) }, seconds: 0.5)
            // SIGKILL even when the leader has already died, so a member that ignored
            // SIGTERM does not outlive Stop. A pid that was already dead is left alone.
            _ = signal(pid, SIGKILL, identity: identity)
            transport.terminate()
            deletePidFile(matching: pid)
            return
        }
        transport.terminate()
    }

    /// `killpg` is ESRCH until the perl launcher has called `setsid`. Fall back to the pid, but
    /// only while it is still the process desnotch spawned: `killpg` cannot hit a reused pid
    /// (the kernel does not hand out a pid that is still a live group id), `kill(pid)` can once
    /// the group is gone and the leader was reaped.
    private func signal(_ pid: Int32, _ code: Int32, identity: ProcessIdentity?) -> Int32 {
        let grouped = killGroup(pid, code)
        if grouped == 0 { return grouped }
        guard Self.mayFallBack(to: pid, spawned: identity) else { return grouped }
        return Darwin.kill(pid, code)
    }

    static func mayFallBack(to pid: Int32, spawned: ProcessIdentity?) -> Bool {
        guard let spawned, alive(pid) else { return false }
        return identity(of: pid) == spawned
    }

    static func identity(of pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if read <= 0 { return nil }
        return ProcessIdentity(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    func shutdown() async {
        terminateNow()
    }

    static func isHermesACP(commandLine: String) -> Bool {
        let tokens = commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        guard tokens.count >= 3 else { return false }
        for index in 0...(tokens.count - 3) {
            if tokens[index] == "-p", tokens[index + 1] == "voice", tokens[index + 2] == "acp" {
                return true
            }
        }
        return false
    }

    static func parsePidFile(_ text: String) -> (pid: Int32, startSeconds: Int)? {
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        if body.isEmpty || body.contains("\n") || body.contains("\t") { return nil }
        let parts = body.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let pidText = String(parts[0])
        let startText = String(parts[1])
        guard let pid = Int32(pidText), let start = Int(startText), pid > 1, start >= 0 else { return nil }
        guard String(pid) == pidText, String(start) == startText else { return nil }
        return (pid, start)
    }

    static func startTimesAgree(recorded: Int, actual: Int) -> Bool {
        abs(recorded - actual) <= 5
    }

    static func alive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) != 0 { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if read <= 0 { return true }
        return info.pbi_status != SZOMB
    }

    static func processStartSeconds(pid: Int32) -> Int? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if read <= 0 { return nil }
        return Int(info.pbi_start_tvsec)
    }

    static func childPIDs(of pid: Int32) -> [Int32] {
        var capacity = 256
        while capacity <= 4096 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else { return -1 }
                return proc_listchildpids(pid, base, Int32(pointer.count * MemoryLayout<Int32>.size))
            }
            if count <= 0 { return [] }
            if Int(count) < capacity { return Array(buffer.prefix(Int(count))) }
            capacity *= 2
        }
        return []
    }

    static func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var frontier = [pid]
        var seen: Set<Int32> = [pid]
        var depth = 0
        while !frontier.isEmpty, depth < 64, result.count < 512 {
            var next: [Int32] = []
            for parent in frontier {
                for child in childPIDs(of: parent) where seen.insert(child).inserted {
                    result.append(child)
                    next.append(child)
                    if result.count >= 512 { return result }
                }
            }
            frontier = next
            depth += 1
        }
        return result
    }

    static func processName(_ pid: Int32) -> String {
        var bytes = [CChar](repeating: 0, count: 256)
        let read = proc_name(pid, &bytes, UInt32(bytes.count))
        if read <= 0 { return "unknown" }
        let name = String(cString: bytes)
        if name.isEmpty { return "unknown" }
        return (name as NSString).lastPathComponent
    }

    private func existingOrBackoff() throws -> ACPTransport? {
        lock.lock()
        if let current {
            let transport = current.transport
            lock.unlock()
            return transport
        }
        let deadline = retryNotBefore
        lock.unlock()
        if let deadline, now() < deadline { throw HermesGuardError.backoff }
        return nil
    }

    private func register(_ transport: ACPTransport) -> Int {
        lock.lock()
        generation += 1
        let token = generation
        lock.unlock()
        transport.setExitHandler { [weak self] uptime in
            self?.transportExited(generation: token, uptime: uptime)
        }
        lock.lock()
        current = Current(transport: transport, generation: token)
        lock.unlock()
        return token
    }

    private func transportExited(generation token: Int, uptime: TimeInterval) {
        lock.lock()
        guard let current, current.generation == token else {
            lock.unlock()
            return
        }
        let transport = current.transport
        self.current = nil
        let delay = backoff.nextDelay(afterUptime: uptime)
        let moment = now()
        retryNotBefore = moment.addingTimeInterval(delay)
        lock.unlock()
        let pid = transport.processID
        transport.terminate()
        deletePidFile(matching: pid)
    }

    private func takeCurrent() -> Current? {
        lock.lock()
        let taken = current
        current = nil
        lock.unlock()
        return taken
    }

    private func recordIdentity(_ identity: ProcessIdentity?, generation token: Int) {
        lock.lock()
        if current?.generation == token { current?.identity = identity }
        lock.unlock()
    }

    private func drop(generation token: Int) {
        lock.lock()
        if current?.generation == token { current = nil }
        lock.unlock()
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current?.generation == token
    }

    private func isCurrentTransport(_ transport: ACPTransport) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current?.transport === transport
    }

    private func recoverStalePidFile() {
        let url = pidURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let parsed = Self.parsePidFile(text) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let command = Self.commandLine(pid: parsed.pid)
        let actual = Self.processStartSeconds(pid: parsed.pid)
        let group = Darwin.getpgid(parsed.pid)
        let matches = command.map(Self.isHermesACP) == true
            && actual.map { Self.startTimesAgree(recorded: parsed.startSeconds, actual: $0) } == true
            && group == parsed.pid
        if !matches {
            try? FileManager.default.removeItem(at: url)
            return
        }
        _ = killGroup(parsed.pid, SIGTERM)
        Self.pause(until: { !Self.alive(parsed.pid) }, seconds: 0.5)
        if Self.alive(parsed.pid) { _ = killGroup(parsed.pid, SIGKILL) }
        try? FileManager.default.removeItem(at: url)
    }

    private func writePidFile(for transport: ACPTransport) {
        guard let pid = transport.processID, let start = Self.processStartSeconds(pid: pid) else { return }
        try? FileManager.default.createDirectory(
            at: pidFileDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let url = pidURL
        try? FileManager.default.removeItem(at: url)
        let text = "\(pid) \(start)\n"
        FileManager.default.createFile(
            atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]
        )
    }

    private func deletePidFile(matching pid: Int32?) {
        let url = pidURL
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = Self.parsePidFile(text) else { return }
        if let pid {
            guard parsed.pid == pid else { return }
        }
        try? FileManager.default.removeItem(at: url)
    }

    private var pidURL: URL {
        pidFileDirectory.appendingPathComponent("hermes-acp.pid")
    }

    private static func commandLine(pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = Darwin.fcntl(fd, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var data = Data()
        let deadline = Date().addingTimeInterval(2)
        while data.count < 4096 && Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 4096 - data.count)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { break }
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
            if !process.isRunning { break }
            var polled = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remain = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            _ = Darwin.poll(&polled, 1, min(remain, 50))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        if data.isEmpty { return nil }
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else { return nil }
        return text
    }

    private static func pause(until condition: () -> Bool, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            var polled = pollfd(fd: -1, events: 0, revents: 0)
            _ = Darwin.poll(&polled, 1, 10)
        }
    }
}
