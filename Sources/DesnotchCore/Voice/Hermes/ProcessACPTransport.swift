import Darwin
import Foundation

/// A real ACP child. The working directory is created in `init` (mode 0700) and never changes.
/// Pipe callbacks share one serial queue and a generation so a dead child cannot write a later stream.
/// `deinit` only clears pipe callbacks. Dropping a transport must not signal the child.
final class ProcessACPTransport: ACPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let launch: ACPLaunch
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var lineBuffer = AdapterLineBuffer()
    private var lineContinuation: AsyncStream<Data>.Continuation
    private var process: Process?
    private var storedPID: Int32?
    private var terminated = false
    private var didStart = false
    private var exitReported = false
    private var stdoutClosed = false
    private var processExited = false
    private var directoryRemoved = false
    private var writeClosed = false
    private var readClosed = false
    private var startedAt: Date?
    private var exitHandler: (@Sendable (TimeInterval) -> Void)?
    private var generation: UInt64 = 0
    private var eofWait: DispatchWorkItem?
    private var readSource: DispatchSourceRead?
    private var ownedReadFD: Int32 = -1

    let lines: AsyncStream<Data>
    let workingDirectory: URL

    init(launch: ACPLaunch, workingDirectoryRoot: URL) {
        self.launch = launch
        let directory = workingDirectoryRoot.appendingPathComponent(
            "desnotch-voice-\(UUID().uuidString)", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        workingDirectory = directory
        let pair = AsyncStream<Data>.makeStream()
        lines = pair.stream
        lineContinuation = pair.continuation
        queue = DispatchQueue(label: "desnotch.voice.acp.\(UUID().uuidString)")
        queue.setSpecific(key: queueKey, value: 1)
        let writeFD = stdinPipe.fileHandleForWriting.fileDescriptor
        _ = Darwin.fcntl(writeFD, F_SETNOSIGPIPE, 1)
        let flags = Darwin.fcntl(writeFD, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(writeFD, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Cancels the stdout source only. The source closes its own descriptor from its cancel
    /// handler, so a later pipe cannot inherit that number early. Dropping a transport must
    /// not signal its child.
    deinit {
        lock.lock()
        let source = readSource
        readSource = nil
        ownedReadFD = -1
        lock.unlock()
        source?.cancel()
        process?.terminationHandler = nil
    }

    func setExitHandler(_ handler: @escaping @Sendable (TimeInterval) -> Void) {
        lock.lock()
        exitHandler = handler
        lock.unlock()
    }

    var processID: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedPID
    }

    func start() throws {
        let built = try prepareStart()
        guard installHandlers(generation: built.generation, process: built.process) else {
            throw ACPTransportError.launchFailed
        }
        do {
            try built.process.run()
        } catch {
            stopReading()
            throw ACPTransportError.launchFailed
        }
        queue.async { [weak self] in self?.drainStdoutNonblocking() }
        try commitStart(built.process)
    }

    func send(line: Data) throws {
        let fd = try writeFDIfAlive()
        var payload = line
        payload.append(0x0A)
        try Self.writeAll(payload, to: fd)
    }

    func terminate() {
        let snapshot = beginTerminate()
        closeWriteEnd()
        if let pid = snapshot.pid, !snapshot.exitReported {
            Darwin.killpg(pid, SIGTERM)
            Self.pause(until: { !HermesProcessGuard.alive(pid) }, seconds: 0.5)
            if HermesProcessGuard.alive(pid) {
                Darwin.killpg(pid, SIGKILL)
            }
        }
        drainOnQueue()
        markStdoutClosed()
        retireGeneration()
        reportExitIfNeeded()
        closeReadEnd()
        removeDirectory()
    }

    private func prepareStart() throws -> (process: Process, generation: UInt64) {
        lock.lock()
        if terminated || didStart {
            lock.unlock()
            throw ACPTransportError.terminated
        }
        didStart = true
        generation &+= 1
        let token = generation
        lock.unlock()
        let process = Process()
        process.executableURL = launch.perl
        process.arguments = launch.arguments
        process.environment = SubprocessRunner.sanitizedEnvironment()
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        return (process, token)
    }

    private func commitStart(_ process: Process) throws {
        let pid = process.processIdentifier
        lock.lock()
        let stop = terminated
        if !stop {
            self.process = process
            storedPID = pid
            startedAt = Date()
        }
        lock.unlock()
        if stop {
            if pid > 0 {
                Darwin.killpg(pid, SIGKILL)
                Darwin.kill(pid, SIGKILL)
            }
            throw ACPTransportError.terminated
        }
    }

    private func installHandlers(generation token: UInt64, process: Process) -> Bool {
        let readFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let status = Darwin.fcntl(readFD, F_GETFL)
        if status >= 0 { _ = Darwin.fcntl(readFD, F_SETFL, status | O_NONBLOCK) }
        let descriptor = Darwin.fcntl(readFD, F_GETFD)
        if descriptor >= 0 { _ = Darwin.fcntl(readFD, F_SETFD, descriptor | FD_CLOEXEC) }
        let owned = Darwin.dup(readFD)
        if owned < 0 { return false }
        let ownedStatus = Darwin.fcntl(owned, F_GETFL)
        if ownedStatus >= 0 { _ = Darwin.fcntl(owned, F_SETFL, ownedStatus | O_NONBLOCK) }
        let ownedDescriptor = Darwin.fcntl(owned, F_GETFD)
        if ownedDescriptor >= 0 { _ = Darwin.fcntl(owned, F_SETFD, ownedDescriptor | FD_CLOEXEC) }
        let source = DispatchSource.makeReadSource(fileDescriptor: owned, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainStdoutNonblocking()
        }
        source.setCancelHandler {
            Darwin.close(owned)
        }
        lock.lock()
        ownedReadFD = owned
        readSource = source
        lock.unlock()
        source.resume()
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.noteProcessExited(generation: token)
            }
        }
        return true
    }

    private func noteProcessExited(generation token: UInt64) {
        guard generationMatches(token) else { return }
        markProcessExited()
        if stdoutIsClosed() {
            reportExitIfNeeded()
            return
        }
        let wait = DispatchWorkItem { [weak self] in
            self?.forceStdoutClosed(generation: token)
        }
        storeEOFWait(wait)
        queue.asyncAfter(deadline: .now() + 1, execute: wait)
    }

    private func forceStdoutClosed(generation token: UInt64) {
        guard generationMatches(token) else { return }
        drainStdoutNonblocking()
        markStdoutClosed()
        reportExitIfNeeded()
    }

    private func drainOnQueue() {
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            drainStdoutNonblocking()
        } else {
            queue.sync { self.drainStdoutNonblocking() }
        }
    }

    private func drainStdoutNonblocking() {
        let fd = currentReadFD()
        if fd < 0 { return }
        while true {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let completed = lineBuffer.append(Data(buffer.prefix(count)))
                for line in completed { lineContinuation.yield(line) }
                continue
            }
            if count == 0 || (count < 0 && errno == EBADF) {
                stopReading()
                markStdoutClosed()
                reportExitIfNeeded()
            }
            break
        }
    }

    private func currentReadFD() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return ownedReadFD
    }

    private func stopReading() {
        lock.lock()
        let source = readSource
        readSource = nil
        ownedReadFD = -1
        readClosed = true
        lock.unlock()
        cancelEOFWait()
        source?.cancel()
    }

    private func generationMatches(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }

    private func markStdoutClosed() {
        lock.lock()
        stdoutClosed = true
        lock.unlock()
    }

    private func processHasExited() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return processExited
    }

    private func markProcessExited() {
        lock.lock()
        processExited = true
        lock.unlock()
    }

    private func stdoutIsClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdoutClosed
    }

    private func cancelEOFWait() {
        eofWait?.cancel()
        eofWait = nil
    }

    private func storeEOFWait(_ wait: DispatchWorkItem) {
        eofWait = wait
    }

    private func retireGeneration() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private func reportExitIfNeeded() {
        lock.lock()
        let ready = processExited && stdoutClosed && !exitReported
        if !ready {
            lock.unlock()
            return
        }
        exitReported = true
        let handler = exitHandler
        let uptime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()
        lineContinuation.finish()
        handler?(uptime)
    }

    private struct TerminateSnapshot {
        var pid: Int32?
        var exitReported: Bool
    }

    private func beginTerminate() -> TerminateSnapshot {
        lock.lock()
        terminated = true
        let pid = storedPID
        let reported = exitReported
        processExited = true
        lock.unlock()
        return TerminateSnapshot(pid: pid, exitReported: reported)
    }

    private func writeFDIfAlive() throws -> Int32 {
        lock.lock()
        let stop = terminated
        lock.unlock()
        if stop { throw ACPTransportError.terminated }
        return stdinPipe.fileHandleForWriting.fileDescriptor
    }

    private func closeWriteEnd() {
        lock.lock()
        let already = writeClosed
        writeClosed = true
        lock.unlock()
        if !already { Darwin.close(stdinPipe.fileHandleForWriting.fileDescriptor) }
    }

    private func closeReadEnd() {
        stopReading()
    }

    private func removeDirectory() {
        lock.lock()
        if directoryRemoved {
            lock.unlock()
            return
        }
        directoryRemoved = true
        lock.unlock()
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let deadline = Date().addingTimeInterval(3)
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let error = errno
                if error == EINTR { continue }
                if error == EAGAIN || error == EWOULDBLOCK {
                    if Date() >= deadline { throw ACPTransportError.timedOut }
                    var polled = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&polled, 1, 50)
                    continue
                }
                throw ACPTransportError.writeFailed(error)
            }
        }
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
