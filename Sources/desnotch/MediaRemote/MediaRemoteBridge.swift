import AppKit
import Foundation

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
/// The adapter's `stream` subcommand keeps one long-lived subprocess running and
/// only writes a line when now-playing state actually changes, so - like the
/// previous in-process implementation - this stays notification-driven rather than
/// polling: idle CPU stays near zero regardless of which underlying technique is
/// fetching the data.
final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    /// Matches the adapter's `send` command IDs (`kMRPlay` etc.), which are the
    /// same reverse-engineered `MRMediaRemoteCommand` values this project used
    /// directly before switching to the adapter.
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    /// Called on the main queue whenever the adapter reports a change. `nil` means
    /// nothing is currently reporting now-playing info.
    var onNowPlayingChange: ((NowPlayingInfo?) -> Void)?

    private let scriptURL: URL?
    private let frameworkPath: String?
    private var streamProcess: Process?
    private var stdoutBuffer = Data()

    private init() {
        let adapterDir = Bundle.module.resourceURL?.appendingPathComponent("MediaRemoteAdapter")
        scriptURL = adapterDir?.appendingPathComponent("mediaremote-adapter.pl")
        frameworkPath = adapterDir?.appendingPathComponent("MediaRemoteAdapter.framework").path
        startStreaming()
    }

    private func startStreaming() {
        guard let scriptURL, let frameworkPath else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream", "--no-diff"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }

        guard (try? process.run()) != nil else { return }
        streamProcess = process
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
        guard
            let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = json["payload"] as? [String: Any]
        else { return }

        let info = payload.isEmpty ? nil : NowPlayingInfo(adapterPayload: payload)
        DispatchQueue.main.async { [weak self] in
            self?.onNowPlayingChange?(info)
        }
    }

    func send(_ command: Command) {
        guard let scriptURL, let frameworkPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "send", String(command.rawValue)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Stops the long-lived `stream` subprocess. Without this, quitting the app
    /// orphans the perl process (reparented to launchd) with a live MediaRemote
    /// subscription still running indefinitely.
    func stopStreaming() {
        stdout(for: streamProcess)?.readabilityHandler = nil
        streamProcess?.terminate()
        streamProcess = nil
    }

    private func stdout(for process: Process?) -> FileHandle? {
        (process?.standardOutput as? Pipe)?.fileHandleForReading
    }
}
