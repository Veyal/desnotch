import AppKit

/// Click-to-jump targets, shared by the pill's tap gestures and the status-menu mirror
/// (the menu is the keyboard/VoiceOver path to the same actions - the pill itself lives
/// in a non-activating panel that assistive tech cannot focus).
enum AppActivation {
    /// Terminals/editors that host agent CLIs, in preference order. The session log
    /// doesn't record which app runs it, so activate the first of these that's running;
    /// with none running, reveal the project folder instead.
    static let agentHostBundleIDs = [
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp",
        "com.apple.Terminal",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode"
    ]

    static func activateMediaApp(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            activate(app)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Focuses the host app actually running this agent, falling back to the old
    /// first-running-host guess.
    ///
    /// The session log still doesn't name its host app, but the agent *process* does:
    /// its cwd is the session's project path, so `lsof` finds those PIDs and the
    /// parent chain (one `ps` snapshot) walks up to whichever terminal/editor owns
    /// them. Resolution runs off the main thread - `lsof` can take a beat - and any
    /// failure, or an agent whose ancestry doesn't reach a known host (tmux/cmux
    /// sessions detach it from the terminal app), just lands on the previous
    /// behavior. Never worse than before, materially better with several terminals
    /// open, which is the whole point: two agent rows used to focus the same app.
    static func activateAgentHost(projectPath: String?) {
        guard let projectPath else {
            activateFirstRunningHost(projectPath: nil)
            return
        }
        Task { @MainActor in
            // Latest click wins: a slower in-flight resolution must never land after
            // a newer one and steal focus to the wrong app.
            AgentActivation.pending?.cancel()
            AgentActivation.pending = Task { @MainActor in
                let ownerPID = await Task.detached(priority: .userInitiated) {
                    owningHostPID(projectPath: projectPath)
                }.value
                guard !Task.isCancelled else { return }
                if let ownerPID,
                   let app = NSRunningApplication(processIdentifier: ownerPID) {
                    activate(app)
                } else {
                    activateFirstRunningHost(projectPath: projectPath)
                }
            }
        }
    }

    /// Holds the in-flight agent activation so a newer click can cancel it.
    @MainActor
    private enum AgentActivation {
        static var pending: Task<Void, Never>?
    }

    private static func activateFirstRunningHost(projectPath: String?) {
        for bundleID in agentHostBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                activate(app)
                return
            }
        }
        if let projectPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: projectPath, isDirectory: true))
        }
    }

    /// PID of the running host app that owns a process whose cwd is `projectPath`,
    /// or nil when nothing can be resolved. Pure lookup - no activation, no logging
    /// of the path (it stays a click target, never surfaced).
    /// Total wall-clock budget for the whole resolution (both helpers combined), so a
    /// slow `lsof` can't be followed by an equally slow `ps` and double the wait.
    private static let resolveBudget: TimeInterval = 2.5

    private static func owningHostPID(projectPath: String) -> pid_t? {
        let hostPIDs = Set(
            agentHostBundleIDs
                .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .map { $0.processIdentifier }
        )
        guard !hostPIDs.isEmpty else { return nil }

        let deadline = Date().addingTimeInterval(resolveBudget)

        // Processes whose *cwd* is this project (the agent CLI, its children).
        guard let cwdOutput = run(
            "/usr/sbin/lsof", ["-a", "-w", "-d", "cwd", "-Fp", "--", projectPath], deadline: deadline
        ) else { return nil }
        let candidates = parseLsofPIDs(cwdOutput)
        guard !candidates.isEmpty else { return nil }

        // One ps snapshot -> child:parent map, then walk each candidate upward.
        guard let psOutput = run("/bin/ps", ["-axo", "pid=,ppid="], deadline: deadline) else {
            return nil
        }
        return firstHostAncestor(
            candidates: candidates, parent: parseParentMap(psOutput), hosts: hostPIDs
        )
    }

    // MARK: - Pure parsing/walking (internal so tests can drive them directly)

    /// PIDs from `lsof -Fp` output. The field format interleaves `p<pid>` lines with
    /// `f<fd>` lines; only the former are PIDs.
    static func parseLsofPIDs(_ output: String) -> [pid_t] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("p") else { return nil }
            return pid_t(line.dropFirst())
        }
    }

    /// child:parent map from `ps -axo pid=,ppid=` output.
    static func parseParentMap(_ output: String) -> [pid_t: pid_t] {
        var parent: [pid_t: pid_t] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " }).compactMap { pid_t($0) }
            if parts.count == 2 { parent[parts[0]] = parts[1] }
        }
        return parent
    }

    /// First candidate whose ancestry reaches a host app, walking up a bounded number
    /// of hops (launchd is the ceiling; the cap also breaks any cycle in bad input).
    static func firstHostAncestor(
        candidates: [pid_t], parent: [pid_t: pid_t], hosts: Set<pid_t>, maxHops: Int = 12
    ) -> pid_t? {
        for candidate in candidates {
            var current = candidate
            var hops = 0
            while hops < maxHops {
                if hosts.contains(current) { return current }
                guard let next = parent[current], next > 1, next != current else { break }
                current = next
                hops += 1
            }
        }
        return nil
    }

    /// Stdout buffer filled on a reader thread; the caller only touches it after the
    /// semaphore confirms the read finished.
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a short-lived helper within the shared `deadline`, or returns nil.
    ///
    /// The read happens on a separate thread so a stalled child can never block the
    /// caller: on timeout the process is asked to terminate and then, if it still
    /// hasn't released the pipe, SIGKILLed - which cannot be caught or ignored, so
    /// the reader always unblocks. `waitUntilExit` is only called on the success path.
    private static func run(_ path: String, _ arguments: [String], deadline: Date) -> String? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let box = OutputBox()
        let finished = DispatchSemaphore(value: 0)
        let handle = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = handle.readDataToEndOfFile()
            finished.signal()
        }

        if finished.wait(timeout: .now() + remaining) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            return nil
        }
        process.waitUntilExit()
        return String(data: box.data, encoding: .utf8)
    }

    static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
