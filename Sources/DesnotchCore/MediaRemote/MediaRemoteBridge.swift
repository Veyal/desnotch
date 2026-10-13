import AppKit
import Foundation
import os

/// Bridges to the system's "now playing" (MediaRemote) state via a vendored
/// external adapter process, rather than calling MediaRemote's private C API
/// directly from this process.
///
/// This project originally called `MRMediaRemoteGetNowPlayingInfo` in-process via
/// `dlopen`/`dlsym`, the technique most tutorials describe. As of macOS 15.4 that
/// call is entitlement-gated: it resolves and executes without error but silently
/// returns nil for an arbitrary third-party binary. Only specific Apple-signed
/// processes (e.g. `/usr/bin/perl`) pass that check. `Vendor/MediaRemoteAdapter/`
/// (github.com/ungive/mediaremote-adapter, BSD-3-Clause; see NOTICE.md there) works
/// around this the same way `nowplaying-cli` and `media-control` do: it loads the
/// adapter's code into `perl`'s already-entitled process and streams results back
/// over a pipe.
///
/// Resilience notes (this is where the silent-death paths used to live):
/// - All mutable stream state (`streamProcess`, `lineBuffer`) is touched only on
///   `queue`, the readability handler included, so there are no data races between
///   the read callback and main-thread stop calls.
/// - `stderr` is sent to `/dev/null`, not an undrained `Pipe` whose 64 KB buffer
///   could deadlock the single-threaded adapter.
/// - A `terminationHandler` restarts the stream with exponential backoff (1s → 30s
///   cap) unless `isStopping` is set, so one adapter crash no longer kills
///   now-playing for the app's lifetime.
/// - Every failure path logs via `os.Logger` (subsystem `com.desnotch.app`).
public final class MediaRemoteBridge {
    public static let shared = MediaRemoteBridge()

    /// Distinguishes an authoritative "nothing is playing" response from a failed
    /// reconciliation. Collapsing both to `nil` leaves optimistic transport state
    /// stuck forever when `get` succeeds with an empty payload.
    public enum GetResult: Equatable, @unchecked Sendable {
        case success(NowPlayingInfo?)
        case failure
    }

    public enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    /// Called on the main queue whenever the adapter reports a change. `nil` means
    /// nothing is currently reporting now-playing info.
    public var onNowPlayingChange: ((NowPlayingInfo?) -> Void)?

    private let logger = Logger(subsystem: "com.desnotch.app", category: "MediaRemote")
    private let scriptURL: URL?
    private let frameworkPath: String?

    /// Single serial queue owning all mutable stream state - fixes the readability-
    /// handler-vs-main data races the strict-concurrency checker flagged.
    private let queue = DispatchQueue(label: "desnotch.mediaremote")
    private var streamProcess: Process?
    private var lineBuffer = AdapterLineBuffer()
    private var isStopping = false
    private var backoff = AdapterRestartBackoff()
    /// Bumped on every launch. Pipe reads and termination callbacks hop onto `queue`
    /// asynchronously, so a late one from a dead adapter must not touch the new stream's
    /// buffer or state.
    private var streamGeneration = 0
    private var streamLaunchedAt: TimeInterval = 0
    /// One-shot reconciliation is bounded and independently owned so a wedged `get`
    /// can neither block the stream's serial state queue nor survive app shutdown.
    private let getRunner = SubprocessRunner(outputByteCap: 32 * 1024 * 1024)

    private init() {
        let located = Self.locateAdapter()
        scriptURL = located?.scriptURL
        frameworkPath = located?.frameworkPath
        if scriptURL == nil || frameworkPath == nil {
            logger.error("Adapter resources missing from bundle; now-playing disabled.")
        }
        startStreaming()
    }

    /// Resolves the vendored adapter. In a packaged `.app` it lives under
    /// `Contents/Resources/MediaRemoteAdapter` (sealed by codesign - notarizable). When
    /// running via `swift run` it comes from the SPM resource bundle (`Bundle.module`), which is
    /// never consulted from a packaged app.
    private static func locateAdapter() -> (scriptURL: URL, frameworkPath: String)? {
        if let resources = Bundle.main.resourceURL {
            let dir = resources.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
            let script = dir.appendingPathComponent("mediaremote-adapter.pl")
            if FileManager.default.fileExists(atPath: script.path) {
                return (script, dir.appendingPathComponent("MediaRemoteAdapter.framework").path)
            }
        }
        // `Bundle.module` traps (fatalError) when its resource bundle is missing, so a packaged
        // app with an incomplete bundle must degrade to "now-playing disabled", not crash.
        if shouldConsultModuleBundle(bundleURL: Bundle.main.bundleURL), let resources = Bundle.module.resourceURL {
            let dir = resources.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
            let script = dir.appendingPathComponent("mediaremote-adapter.pl")
            if FileManager.default.fileExists(atPath: script.path) {
                return (script, dir.appendingPathComponent("MediaRemoteAdapter.framework").path)
            }
        }
        return nil
    }

    /// `Bundle.module` is the `swift run` fallback only; a packaged `.app` never uses it.
    static func shouldConsultModuleBundle(bundleURL: URL) -> Bool {
        bundleURL.pathExtension != "app"
    }

    // MARK: - Adapter process

    /// Environment for every perl launch. Inherited `PERL5OPT`/`PERL5LIB`/`DYLD_*` would
    /// otherwise run attacker-chosen code inside an entitled Apple-signed interpreter.
    static func adapterEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        SubprocessRunner.sanitizedEnvironment(base: base)
    }

    /// The one place that builds an adapter `Process` (stream, send, seek): fixed
    /// interpreter, sanitized environment, no inherited stdin.
    static func makeAdapterProcess(
        scriptURL: URL,
        frameworkPath: String,
        arguments: [String],
        environment: [String: String] = MediaRemoteBridge.adapterEnvironment()
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath] + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// Fire-and-forget adapter subcommand (`send`, `seek`).
    private func runOneShot(_ arguments: [String], label: String) {
        guard let scriptURL, let frameworkPath else { return }
        let process = Self.makeAdapterProcess(scriptURL: scriptURL, frameworkPath: frameworkPath, arguments: arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("Adapter \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public).")
        }
    }

    // MARK: - Stream

    private func startStreaming() {
        guard scriptURL != nil, frameworkPath != nil else { return }
        queue.async { [weak self] in
            self?.launchStream()
        }
    }

    private func launchStream() {
        guard !isStopping, let scriptURL, let frameworkPath else { return }

        // --debounce=100 coalesces the burst of updates that fire on a track change
        // (title/artist/artwork/elapsed arrive separately) so the pill isn't re-decoded
        // a half-dozen times per change.
        let process = Self.makeAdapterProcess(
            scriptURL: scriptURL,
            frameworkPath: frameworkPath,
            arguments: ["stream", "--no-diff", "--debounce=100"]
        )

        streamGeneration += 1
        let generation = streamGeneration
        lineBuffer.reset()

        let stdout = Pipe()
        process.standardOutput = stdout
        // Send stderr to /dev/null, NOT an undrained Pipe: 64 KB of adapter stderr
        // would block the single-threaded perl and freeze now-playing silently.
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: the adapter closed its end. Without clearing the handler, Foundation
                // keeps invoking it with empty data in a tight loop until the pipe is freed.
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.consume(data, generation: generation)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.handleStreamTermination(generation: generation)
            }
        }

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch adapter stream: \(error.localizedDescription, privacy: .public).")
            stdout.fileHandleForReading.readabilityHandler = nil
            scheduleRestart(uptime: nil)
            return
        }
        streamProcess = process
        streamLaunchedAt = ProcessInfo.processInfo.systemUptime
        // The backoff is NOT reset here: a launch that dies instantly must keep climbing the
        // delay ladder. It resets on the first valid JSON line or after `stableUptime`.
    }

    private func handleStreamTermination(generation: Int) {
        // A termination callback from an already-replaced adapter is stale.
        guard generation == streamGeneration else { return }
        let uptime = ProcessInfo.processInfo.systemUptime - streamLaunchedAt
        streamProcess = nil
        lineBuffer.reset()
        guard !isStopping else { return }
        logger.notice("Adapter stream exited unexpectedly; scheduling relaunch.")
        scheduleRestart(uptime: uptime)
    }

    private func scheduleRestart(uptime: TimeInterval?) {
        let delay = backoff.nextDelay(afterUptime: uptime)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping else { return }
            self.launchStream()
        }
    }

    /// The adapter writes newline-delimited JSON; `availableData` doesn't respect
    /// line boundaries, so incomplete lines are buffered across calls.
    private func consume(_ data: Data, generation: Int) {
        // Bytes read from an adapter that has since been replaced (or has exited) would
        // glue its truncated last line onto the new stream's first line and corrupt it.
        guard generation == streamGeneration else { return }
        for line in lineBuffer.append(data) {
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let payload = Self.payload(from: line) else {
            logger.error("Failed to parse adapter JSON line.")
            return
        }
        if backoff.recordHealthyOutput() {
            logger.info("Adapter stream recovered after relaunch.")
        }
        let info = payload.isEmpty ? nil : NowPlayingInfo(adapterPayload: payload)
        DispatchQueue.main.async { [weak self] in
            self?.onNowPlayingChange?(info)
        }
    }

    // MARK: - One-shot get (reconciliation fallback)

    /// Runs the adapter `get` once and returns an authoritative result on the main
    /// queue. Used by `NowPlayingController` to reconcile after a transport command when
    /// the change-driven stream hasn't confirmed the new state. This path deliberately
    /// does not run on `queue`: a failed private-framework call must not freeze stream
    /// delivery or the synchronous shutdown path.
    public func getOnce(completion: @escaping @Sendable (GetResult) -> Void) {
        guard let scriptURL, let frameworkPath else {
            DispatchQueue.main.async { completion(.failure) }
            return
        }
        let runner = getRunner
        Task.detached(priority: .userInitiated) { [logger] in
            let resolved: GetResult
            do {
                let result = try await runner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/perl"),
                    arguments: [scriptURL.path, frameworkPath, "get"],
                    cwd: scriptURL.deletingLastPathComponent(),
                    timeout: 5
                )
                if result.truncated {
                    logger.error("Adapter get output exceeded the reconciliation limit.")
                    resolved = .failure
                } else {
                    resolved = Self.getResult(
                        from: Data(result.stdout.utf8),
                        terminationStatus: result.exitCode
                    )
                }
            } catch {
                logger.error("Adapter get failed: \(error.localizedDescription, privacy: .public).")
                resolved = .failure
            }
            DispatchQueue.main.async { completion(resolved) }
        }
    }

    // MARK: - Commands

    public func send(_ command: Command) {
        runOneShot(["send", String(command.rawValue)], label: "send(\(command.rawValue))")
    }

    /// Seeks to an absolute timeline position via the adapter's `seek` subcommand
    /// (which takes microseconds). Same fire-and-forget shape as `send(_:)`.
    public func seek(to seconds: TimeInterval) {
        let micros = Int64((max(0, seconds) * 1_000_000).rounded())
        runOneShot(["seek", String(micros)], label: "seek(\(micros))")
    }

    // MARK: - Shutdown

    /// Stops the long-lived `stream` subprocess. Without this, quitting the app
    /// orphans the perl process (reparented to launchd) with a live MediaRemote
    /// subscription still running indefinitely.
    public func stopStreaming() {
        queue.sync {
            isStopping = true
            let proc = streamProcess
            if let handle = (proc?.standardOutput as? Pipe)?.fileHandleForReading {
                handle.readabilityHandler = nil
            }
            proc?.terminate()
            streamProcess = nil
            streamGeneration += 1
        }
        getRunner.shutdown(timeout: 1)
    }

    // MARK: - Parsing

    /// Extracts the `payload` dictionary from one adapter JSON line/object. Returns nil
    /// if the data isn't valid JSON or lacks a `payload` key.
    public static func payload(from data: Data) -> [String: Any]? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = json["payload"] as? [String: Any]
        else { return nil }
        return payload
    }

    /// Pure reconciliation decoder, kept separate so empty-success and failure
    /// semantics stay regression-testable without launching the private adapter.
    /// `stream` emits an envelope with `payload`; `get` emits the payload dictionary
    /// directly (verified against the vendored adapter), so accept both shapes.
    public static func getResult(from data: Data, terminationStatus: Int32 = 0) -> GetResult {
        guard terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure }
        let payload: [String: Any]
        if object.keys.contains("payload") {
            guard let nested = object["payload"] as? [String: Any] else { return .failure }
            payload = nested
        } else {
            payload = object
        }
        return .success(payload.isEmpty ? nil : NowPlayingInfo(adapterPayload: payload))
    }
}

/// Restart delay ladder for the adapter stream (1s, 2s, 4s ... capped at 30s).
///
/// A relaunch only counts as recovered once the adapter proves it is healthy: it emits a
/// valid JSON line, or it stays up for `stableUptime` before dying. Resetting at launch
/// would pin a crash-on-startup adapter at the 1s rung forever, forking perl every second.
struct AdapterRestartBackoff {
    static let stableUptime: TimeInterval = 10
    static let maxDelay: TimeInterval = 30

    private(set) var attempt = 0

    /// Call on each valid adapter line. Returns true when this ended a failure streak.
    mutating func recordHealthyOutput() -> Bool {
        defer { attempt = 0 }
        return attempt != 0
    }

    /// Delay before the next launch. `uptime` is how long the previous adapter lived, or
    /// nil when it failed to launch at all.
    mutating func nextDelay(afterUptime uptime: TimeInterval?) -> TimeInterval {
        if let uptime, uptime >= Self.stableUptime { attempt = 0 }
        attempt += 1
        return min(Self.maxDelay, pow(2.0, Double(attempt - 1)))
    }
}

/// Splits the adapter's newline-delimited JSON stream back into whole lines. `availableData`
/// doesn't respect line boundaries, so a partial trailing line is held until its newline
/// arrives. Empty lines are dropped. A line that grows past `maxPendingBytes` is discarded,
/// and further bytes are ignored until the next newline, so a newline-less stream cannot
/// grow without bound. Each append scans only the bytes just received.
struct AdapterLineBuffer {
    static let maxPendingBytes = 1_048_576

    private var pending = Data()
    private var discarding = false

    /// Bytes of an incomplete trailing line still waiting for its newline.
    var pendingByteCount: Int { pending.count }

    /// Appends `data` and returns every line it completed, in order, without the newline.
    mutating func append(_ data: Data) -> [Data] {
        if discarding {
            guard let newline = data.firstIndex(of: 0x0A) else { return [] }
            discarding = false
            let rest = data[data.index(after: newline)...]
            return rest.isEmpty ? [] : append(Data(rest))
        }
        let prior = pending.count
        pending.append(data)
        var lines: [Data] = []
        var consumed = pending.startIndex
        var scan = pending.index(pending.startIndex, offsetBy: prior)
        while scan < pending.endIndex, let newline = pending[scan...].firstIndex(of: 0x0A) {
            let line = pending[consumed..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            consumed = pending.index(after: newline)
            scan = consumed
        }
        if consumed > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<consumed)
        }
        if pending.count > Self.maxPendingBytes {
            pending.removeAll(keepingCapacity: false)
            discarding = true
        }
        return lines
    }

    /// Drops any partial line (a new adapter stream must never inherit a dead one's tail).
    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
        discarding = false
    }
}
