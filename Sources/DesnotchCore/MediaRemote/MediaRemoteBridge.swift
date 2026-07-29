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
/// - All mutable stream state (`streamProcess`, `stdoutBuffer`) is touched only on
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
    private var stdoutBuffer = Data()
    private var isStopping = false
    private var restartAttempt = 0

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
    /// running via `swift run` it comes from the SPM resource bundle (`Bundle.module`).
    private static func locateAdapter() -> (scriptURL: URL, frameworkPath: String)? {
        if let resources = Bundle.main.resourceURL {
            let dir = resources.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
            let script = dir.appendingPathComponent("mediaremote-adapter.pl")
            if FileManager.default.fileExists(atPath: script.path) {
                return (script, dir.appendingPathComponent("MediaRemoteAdapter.framework").path)
            }
        }
        if let resources = Bundle.module.resourceURL {
            let dir = resources.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
            let script = dir.appendingPathComponent("mediaremote-adapter.pl")
            if FileManager.default.fileExists(atPath: script.path) {
                return (script, dir.appendingPathComponent("MediaRemoteAdapter.framework").path)
            }
        }
        return nil
    }

    // MARK: - Stream

    private func startStreaming() {
        guard scriptURL != nil, frameworkPath != nil else { return }
        queue.async { [weak self] in
            self?.launchStream()
        }
    }

    private func launchStream() {
        guard let scriptURL, let frameworkPath else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // --debounce=100 coalesces the burst of updates that fire on a track change
        // (title/artist/artwork/elapsed arrive separately) so the pill isn't re-decoded
        // a half-dozen times per change.
        process.arguments = [scriptURL.path, frameworkPath, "stream", "--no-diff", "--debounce=100"]

        let stdout = Pipe()
        process.standardOutput = stdout
        // Send stderr to /dev/null, NOT an undrained Pipe: 64 KB of adapter stderr
        // would block the single-threaded perl and freeze now-playing silently.
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consume(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.handleStreamTermination()
            }
        }

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch adapter stream: \(error.localizedDescription, privacy: .public).")
            scheduleRestart()
            return
        }
        streamProcess = process
        if restartAttempt != 0 {
            logger.info("Adapter stream recovered after \(self.restartAttempt) relaunch attempt(s).")
        }
        restartAttempt = 0
    }

    private func handleStreamTermination() {
        streamProcess = nil
        stdoutBuffer = Data()
        guard !isStopping else { return }
        logger.notice("Adapter stream exited unexpectedly; scheduling relaunch.")
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartAttempt += 1
        let delay = min(30.0, pow(2.0, Double(restartAttempt - 1)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping else { return }
            self.launchStream()
        }
    }

    /// The adapter writes newline-delimited JSON; `availableData` doesn't respect
    /// line boundaries, so incomplete lines are buffered across calls.
    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handle(line: Data(lineData))
        }
    }

    private func handle(line: Data) {
        guard let payload = Self.payload(from: line) else {
            logger.error("Failed to parse adapter JSON line.")
            return
        }
        let info = payload.isEmpty ? nil : NowPlayingInfo(adapterPayload: payload)
        DispatchQueue.main.async { [weak self] in
            self?.onNowPlayingChange?(info)
        }
    }

    // MARK: - One-shot get (reconciliation fallback)

    /// Runs the adapter `get` once and returns the parsed now-playing info on the main
    /// queue. Used by `NowPlayingController` to reconcile after a transport command when
    /// the change-driven stream hasn't confirmed the new state.
    public func getOnce(completion: @escaping @Sendable (NowPlayingInfo?) -> Void) {
        guard let scriptURL, let frameworkPath else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.async { [logger] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptURL.path, frameworkPath, "get"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                logger.error("Adapter get failed to launch: \(error.localizedDescription, privacy: .public).")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let info = Self.payload(from: data).map { payload in
                payload.isEmpty ? nil : NowPlayingInfo(adapterPayload: payload)
            } ?? nil
            DispatchQueue.main.async { completion(info) }
        }
    }

    // MARK: - Commands

    public func send(_ command: Command) {
        guard let scriptURL, let frameworkPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "send", String(command.rawValue)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("Adapter send(\(command.rawValue)) failed: \(error.localizedDescription, privacy: .public).")
        }
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
        }
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
}
