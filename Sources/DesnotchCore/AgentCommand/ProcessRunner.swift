import Darwin
import Foundation

public struct AgentProcessResult: Equatable {
    public let stdout: String
    public let stderr: String
    public let truncated: Bool
    public let exitCode: Int32

    public init(stdout: String, stderr: String, truncated: Bool = false, exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.exitCode = exitCode
    }
}

public enum AgentProcessError: Error, Equatable {
    case timeout
    case cancelled
    case launchFailed
    case invalidWorkingDirectory
    case inputTooLarge
}

/// Runs a process without a shell, drains both output pipes even after the UI byte
/// cap is reached, streams chunks to the caller, and owns timeout/cancellation.
public final class AgentProcessRunner: @unchecked Sendable {
    public static let inputByteCap = 64 * 1024
    public let outputByteCap: Int
    private let activeLock = NSLock()
    private var active = [ObjectIdentifier: AgentProcessBox]()

    public init(outputByteCap: Int = 256 * 1024) {
        self.outputByteCap = max(1, outputByteCap)
    }

    public func run(
        executable: URL,
        arguments: [String],
        cwd: URL,
        timeout: TimeInterval = 120,
        standardInput: Data? = nil,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> AgentProcessResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentProcessError.invalidWorkingDirectory
        }
        if let standardInput, standardInput.count > Self.inputByteCap {
            throw AgentProcessError.inputTooLarge
        }

        let processBox = AgentProcessBox()
        register(processBox)
        defer { unregister(processBox) }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                // A fixed Perl launcher creates a new session/process group before
                // `exec`-ing the requested executable. No proposal text is parsed as
                // code; executable and argv remain separate arguments. This lets
                // cancellation reliably terminate descendants as one owned group.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = [
                    "-MPOSIX=setsid",
                    "-e",
                    "setsid(); exec {$ARGV[0]} @ARGV; exit 127",
                    executable.path
                ] + arguments
                process.currentDirectoryURL = cwd
                process.environment = Self.sanitizedEnvironment()

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdinPipe: Pipe?
                if standardInput != nil {
                    let pipe = Pipe()
                    process.standardInput = pipe
                    stdinPipe = pipe
                } else {
                    process.standardInput = FileHandle.nullDevice
                    stdinPipe = nil
                }

                processBox.set(process)
                let workQueue = DispatchQueue(label: "desnotch.agent-process", qos: .userInitiated)
                // This timer has its own queue and is armed before any stdin write. A
                // child which never reads stdin therefore cannot defeat the deadline.
                let timeoutSource = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "desnotch.agent-timeout"))
                timeoutSource.schedule(deadline: .now() + max(0.1, timeout))
                timeoutSource.setEventHandler { processBox.terminate(reason: .timeout) }
                timeoutSource.resume()
                workQueue.async {
                    do {
                        try process.run()
                    } catch {
                        timeoutSource.cancel()
                        _ = processBox.finish()
                        continuation.resume(throwing: AgentProcessError.launchFailed)
                        return
                    }

                    // Make the direct child a process-group leader when possible, so
                    // timeout/cancel can also stop descendants it launched.
                    processBox.establishProcessGroup()

                    let readers = DispatchGroup()
                    let stdoutBox = AgentDataBox()
                    let stderrBox = AgentDataBox()
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stdoutBox.read(stdoutPipe.fileHandleForReading, cap: self.outputByteCap, onChunk: onStdout)
                        readers.leave()
                    }
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stderrBox.read(stderrPipe.fileHandleForReading, cap: self.outputByteCap, onChunk: onStderr)
                        readers.leave()
                    }

                    if let standardInput, let stdinPipe {
                        processBox.write(standardInput, to: stdinPipe.fileHandleForWriting)
                    }

                    process.waitUntilExit()
                    // Cancel the deadline before the bounded drain below: a command
                    // that finished just before the deadline must not be reported
                    // as a timeout while its output is still being collected.
                    timeoutSource.cancel()
                    // A quickly-exiting child can leave a descendant holding the
                    // pipe write ends; bound the drain instead of blocking until
                    // the full timeout on output that already arrived.
                    if readers.wait(timeout: .now() + 2) == .timedOut {
                        processBox.killOwnedGroup()
                        _ = readers.wait(timeout: .now() + 3)
                    }
                    let reason = processBox.finish()
                    switch reason {
                    case .cancelled:
                        continuation.resume(throwing: AgentProcessError.cancelled)
                    case .timeout:
                        continuation.resume(throwing: AgentProcessError.timeout)
                    case nil:
                        continuation.resume(returning: AgentProcessResult(
                            stdout: String(decoding: stdoutBox.data, as: UTF8.self),
                            stderr: String(decoding: stderrBox.data, as: UTF8.self),
                            truncated: stdoutBox.truncated || stderrBox.truncated,
                            exitCode: process.terminationStatus
                        ))
                    }
                }
            }
        }, onCancel: {
            processBox.terminate(reason: .cancelled)
        })
    }

    /// Stops all owned processes and waits briefly for their worker paths to drain.
    /// This is intended for synchronous application shutdown/signal cleanup.
    public func shutdown(timeout: TimeInterval = 2) {
        let boxes: [AgentProcessBox]
        activeLock.lock()
        boxes = Array(active.values)
        activeLock.unlock()
        boxes.forEach { $0.terminate(reason: .cancelled) }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        boxes.forEach { $0.waitUntilFinished(deadline: deadline) }
    }

    private func register(_ box: AgentProcessBox) {
        activeLock.lock(); active[ObjectIdentifier(box)] = box; activeLock.unlock()
    }

    private func unregister(_ box: AgentProcessBox) {
        activeLock.lock(); active.removeValue(forKey: ObjectIdentifier(box)); activeLock.unlock()
    }

    /// Commands run with a minimal, explicit environment: inherited variables like
    /// GIT_EXTERNAL_DIFF, GIT_SSH, PERL5OPT, or DYLD_* could otherwise turn a
    /// policy-approved read-only command into arbitrary code execution.
    static func sanitizedEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_PAGER": "cat",
            "GIT_TERMINAL_PROMPT": "0",
            "PAGER": "cat"
        ]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME"] {
            if let value = base[key] { environment[key] = value }
        }
        return environment
    }
}

private final class AgentProcessBox: @unchecked Sendable {
    enum StopReason { case timeout, cancelled }

    private let lock = NSLock()
    private var process: Process?
    private var processGroupID: pid_t?
    private var stopReason: StopReason?
    private var completed = false
    private let finished = DispatchSemaphore(value: 0)

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldStop = stopReason != nil
        lock.unlock()
        if shouldStop { terminateProcess(process) }
    }

    func establishProcessGroup() {
        lock.lock()
        guard let process, !completed else { lock.unlock(); return }
        let pid = process.processIdentifier
        if setpgid(pid, pid) == 0 || getpgid(pid) == pid {
            processGroupID = pid
        }
        let shouldStop = stopReason != nil
        lock.unlock()
        if shouldStop { terminateProcess(process) }
    }

    func terminate(reason: StopReason) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        if stopReason == nil { stopReason = reason }
        let process = self.process
        lock.unlock()
        if let process { terminateProcess(process) }
    }

    func finish() -> StopReason? {
        lock.lock()
        if completed { let reason = stopReason; lock.unlock(); return reason }
        completed = true
        let reason = stopReason
        process = nil
        lock.unlock()
        // The leader has already been reaped by `waitUntilExit` here, so its
        // numeric pgid may have been recycled; signaling it now could hit an
        // unrelated process. Group-wide kills happen only pre-reap
        // (`terminateProcess`) or from the bounded pipe drain (`killOwnedGroup`).
        finished.signal()
        return reason
    }

    func killOwnedGroup() {
        lock.lock()
        let groupID = completed ? nil : processGroupID
        lock.unlock()
        if let groupID, groupExists(groupID) { Darwin.kill(-groupID, SIGKILL) }
    }

    func waitUntilFinished(deadline: Date) {
        lock.lock()
        let alreadyFinished = completed
        lock.unlock()
        if alreadyFinished { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { _ = finished.wait(timeout: .now() + remaining) }
    }

    func write(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        let flags = Darwin.fcntl(fd, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count && !isStopping {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 { offset += written; continue }
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&pollFD, 1, 50)
            }
        }
        try? handle.close()
    }

    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopReason != nil || completed
    }

    private func groupExists(_ groupID: pid_t) -> Bool {
        // EPERM means the group exists but is not ours to signal - a recycled
        // pgid owned by someone else, never desnotch's own child group.
        Darwin.kill(-groupID, 0) == 0
    }

    private func terminateProcess(_ process: Process) {
        lock.lock()
        let alreadyCompleted = completed
        let groupID = processGroupID
        lock.unlock()
        if alreadyCompleted { return }
        if let groupID, groupExists(groupID) {
            Darwin.kill(-groupID, SIGTERM)
            // Cancellation/timeout is an immediate stop boundary. Escalate while
            // the owned Process object still identifies the group leader; do not
            // schedule a later numeric-PGID kill that could hit a reused group.
            Darwin.kill(-groupID, SIGKILL)
        } else if process.isRunning {
            process.terminate()
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class AgentDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var didTruncate = false

    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return didTruncate }

    func read(_ handle: FileHandle, cap: Int, onChunk: (@Sendable (Data) -> Void)?) {
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            lock.lock()
            let accepted: Data
            if storage.count < cap {
                let remaining = cap - storage.count
                accepted = Data(chunk.prefix(remaining))
                storage.append(accepted)
                if chunk.count > remaining { didTruncate = true }
            } else {
                accepted = Data()
                didTruncate = true
            }
            lock.unlock()
            if !accepted.isEmpty { onChunk?(accepted) }
        }
    }
}
