import AppKit

/// Click-to-jump targets, shared by the pill's tap gestures and the status-menu mirror
/// (the menu is the keyboard path to the same actions - the pill itself lives in a
/// non-activating panel that is never key; VoiceOver reaches it only via the cursor when pinned open).
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
                let hostPIDs = runningHostPIDs()
                // Awaits the bounded helpers off the main actor; cancelling this task (a newer
                // click) also kills an in-flight lsof/ps through SubprocessRunner.
                let ownerPID = await owningHostPID(projectPath: projectPath, hostPIDs: hostPIDs)
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

    /// Total wall-clock budget for the whole resolution (both helpers combined), so a
    /// slow `lsof` can't be followed by an equally slow `ps` and double the wait.
    static let resolveBudget: TimeInterval = 2.5

    /// Runs one short-lived helper and returns its stdout, or nil on failure/timeout.
    /// Injectable so the resolution can be tested without spawning `lsof`/`ps`.
    typealias HelperRun = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async -> String?

    private static let helperRunner = SubprocessRunner(outputByteCap: 1024 * 1024)

    /// Production helper runner: `SubprocessRunner` supplies the timeout, output cap,
    /// sanitized environment and kill-on-cancel that a bare `Process` + `readDataToEndOfFile`
    /// lacked. Exit status is ignored on purpose: `lsof` exits 1 when nothing matches.
    static let runHelper: HelperRun = { executable, arguments, timeout in
        guard let result = try? await helperRunner.run(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            cwd: URL(fileURLWithPath: "/", isDirectory: true),
            timeout: timeout
        ), !result.truncated else { return nil }
        return result.stdout
    }

    private static func runningHostPIDs() -> Set<pid_t> {
        Set(
            agentHostBundleIDs
                .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .map { $0.processIdentifier }
        )
    }

    /// PID of the running host app that owns a process whose cwd is `projectPath`,
    /// or nil when nothing can be resolved. Pure lookup - no activation, no logging
    /// of the path (it stays a click target, never surfaced).
    static func owningHostPID(
        projectPath: String,
        hostPIDs: Set<pid_t>,
        run: HelperRun = AppActivation.runHelper,
        budget: TimeInterval = AppActivation.resolveBudget
    ) async -> pid_t? {
        guard !hostPIDs.isEmpty else { return nil }

        let deadline = Date().addingTimeInterval(budget)

        // Processes whose *cwd* is this project (the agent CLI, its children).
        let cwdRemaining = deadline.timeIntervalSinceNow
        guard cwdRemaining > 0, let cwdOutput = await run(
            "/usr/sbin/lsof", ["-a", "-w", "-d", "cwd", "-Fp", "--", projectPath], cwdRemaining
        ) else { return nil }
        let candidates = parseLsofPIDs(cwdOutput)
        guard !candidates.isEmpty else { return nil }

        // One ps snapshot -> child:parent map, then walk each candidate upward.
        let psRemaining = deadline.timeIntervalSinceNow
        guard psRemaining > 0, let psOutput = await run(
            "/bin/ps", ["-axo", "pid=,ppid="], psRemaining
        ) else { return nil }
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

    static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
