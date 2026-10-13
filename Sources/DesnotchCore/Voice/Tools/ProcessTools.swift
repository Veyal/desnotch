import Foundation

// Process tools: a shell command, an AppleScript, a Shortcut. Each is classified by the shared
// `CommandRiskScanner` (no separate pattern list): flagged constructs (pipe to an interpreter,
// command substitution, sudo, protected paths...) are T4, network egress T3, everything else
// T2 behind the hold-to-approve card. Runs go through `SubprocessRunner`: own process group,
// sanitized environment, no TTY, scratch working directory, a timeout and an output cap;
// cancelling the turn (Stop, Cancel, budget) kills the whole group.

/// Result of one process run, already bounded.
enum AgentProcessOutcome: Equatable, Sendable {
    case finished(exitCode: Int32, output: String, truncated: Bool)
    case timedOut
    case cancelled
    case failedToStart
}

/// Seam over `SubprocessRunner` so tests can script runs; the live runner is used by the
/// Stop test to prove the process group really dies.
protocol AgentProcessRunning: Sendable {
    func run(executable: String, arguments: [String], cwd: URL, input: Data?, timeout: TimeInterval) async -> AgentProcessOutcome
}

/// Production runner: one `SubprocessRunner` per call, so a cancelled call cannot leave the
/// runner in its permanent shut-down state.
struct LiveAgentProcessRunner: AgentProcessRunning {
    func run(executable: String, arguments: [String], cwd: URL, input: Data?, timeout: TimeInterval) async -> AgentProcessOutcome {
        let runner = SubprocessRunner(outputByteCap: AgentToolLimits.outputBytes)
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: executable),
                arguments: arguments,
                cwd: cwd,
                timeout: timeout,
                standardInput: input
            )
            var output = result.stdout
            if !result.stderr.isEmpty {
                output += (output.isEmpty ? "" : "\n") + "[stderr]\n" + result.stderr
            }
            return .finished(exitCode: result.exitCode, output: output, truncated: result.truncated)
        } catch let error as SubprocessError {
            switch error {
            case .timeout: return .timedOut
            case .cancelled: return .cancelled
            default: return .failedToStart
            }
        } catch {
            return .failedToStart
        }
    }
}

enum ProcessTools {
    static let shellExecutable = "/bin/zsh"
    static let appleScriptExecutable = "/usr/bin/osascript"
    static let shortcutsExecutable = "/usr/bin/shortcuts"

    /// Scanner tier, never below T2: a process can do anything its text says.
    static func tier(_ risk: CommandRisk) -> VoiceTier {
        if risk.isAutoDeny { return .t4 }
        return max(.t2, risk.tier)
    }

    static func outcome(_ result: AgentProcessOutcome) -> ChatToolOutcome {
        switch result {
        case .finished(let code, let output, let truncated):
            var text = "exit code \(code)"
            if !output.isEmpty { text += "\n" + output }
            if truncated { text += "\n" + AgentToolOutput.truncationMarker }
            return ChatToolOutcome(content: text, isError: code != 0)
        case .timedOut:
            return ChatToolOutcome(content: "Timed out after \(Int(AgentToolLimits.processTimeout)) seconds and was stopped.", isError: true)
        case .cancelled:
            return ChatToolOutcome(content: "Stopped.", isError: true)
        case .failedToStart:
            return ChatToolOutcome(content: "Could not start.", isError: true)
        }
    }

    /// The working directory: the scratch folder, or a folder the model named (classified like
    /// a read; a protected one is T4).
    static func workingDirectory(_ raw: String?, paths: AgentPathContext) -> AgentPathVerdict? {
        guard let raw else { return AgentPathVerdict(url: paths.scratch, tier: .t1) }
        return AgentToolPaths.classify(raw, access: .read, context: paths)
    }
}

/// `run_shell`: `/bin/zsh -f -c <command>` (no rc files) inside `AgentShellSandbox`, which is
/// the enforcement boundary (the static checks in `propose` are layer 1 only). The card shows the
/// exact command and, when it is not the scratch folder, the working directory. Without a working
/// sandbox nothing runs: the call classifies T3, and a profile that fails to load is refused.
struct RunShellTool: AgentTool {
    let paths: AgentPathContext
    let runner: AgentProcessRunning
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "run_shell",
            description: "Run a shell command (zsh) on this Mac. The user must approve each command. Output is capped.",
            inputSchemaJSON: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string","description":"Working folder; default is a private scratch folder"}},"required":["command"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let command = args.text("command"), command.count <= 4_000,
              let folder = ProcessTools.workingDirectory(args.text("cwd"), paths: paths)
        else {
            return AgentProposals.invalid("tool.run_shell", label: AgentToolStep.runCommandApproved, "command is required")
        }
        let risk = CommandRiskScanner.scan(command)
        var tier = ProcessTools.tier(risk)
        if folder.tier >= .t4 || CommandRiskScanner.shellEvasion(command)
            || CommandRiskScanner.inlineInterpreter(command) {
            tier = .t4
        }
        if tier < .t3, !AgentShellSandbox.isAvailable
            || AgentShellSandbox.profile(paths: paths, temporaryDirectory: FileManager.default.temporaryDirectory) == nil {
            tier = .t3
        }
        var literal = risk.sanitized
        if args.text("cwd") != nil {
            literal = "cd \(CommandRiskScanner.scan(AgentToolPaths.display(folder.url, context: paths)).sanitized)\n" + literal
        }
        return ChatToolProposal(
            tier: tier, stepLabel: AgentToolStep.runCommandApproved, summary: "Run a shell command",
            literal: literal, risk: risk.flags, isTruncated: risk.wasTruncated, auditCode: "tool.run_shell"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let command = args.text("command"),
              let folder = ProcessTools.workingDirectory(args.text("cwd"), paths: paths),
              args.text("cwd") != nil || paths.ensureScratch()
        else {
            return ChatToolOutcome(content: "Invalid command or folder.", isError: true)
        }
        guard AgentShellSandbox.isAvailable,
              let profile = AgentShellSandbox.profile(paths: paths, temporaryDirectory: FileManager.default.temporaryDirectory)
        else {
            return ChatToolOutcome(content: "Refused: the command sandbox is not available on this Mac, so nothing ran.", isError: true)
        }
        // The profile must load before the real command starts; a profile that fails to compile
        // must never leave the command running unsandboxed.
        let check = await runner.run(
            executable: AgentShellSandbox.executable, arguments: ["-p", profile, "/usr/bin/true"], cwd: folder.url,
            input: nil, timeout: 5
        )
        guard case .finished(0, _, _) = check else {
            return ChatToolOutcome(content: "Refused: the command sandbox did not load, so nothing ran.", isError: true)
        }
        let result = await runner.run(
            executable: AgentShellSandbox.executable,
            arguments: ["-p", profile, "/usr/bin/env", "HOME=\(AgentToolPaths.canonical(paths.home).path)",
                        ProcessTools.shellExecutable, "-f", "-c", command],
            cwd: folder.url, input: nil, timeout: AgentToolLimits.processTimeout
        )
        return ProcessTools.outcome(result)
    }
}

/// `run_applescript`: the script is passed to the system AppleScript runner on stdin and runs
/// in the scratch folder. The first script that targets an app makes macOS ask for Automation
/// permission for desnotch.
struct RunAppleScriptTool: AgentTool {
    let paths: AgentPathContext
    let runner: AgentProcessRunning
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "run_applescript",
            description: "Run an AppleScript to control a Mac app. The user must approve each script.",
            inputSchemaJSON: #"{"type":"object","properties":{"script":{"type":"string"}},"required":["script"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let script = args.text("script"), script.utf8.count <= SubprocessRunner.inputByteCap else {
            return AgentProposals.invalid("tool.run_applescript", label: AgentToolStep.runAppleScriptApproved, "script is required")
        }
        let risk = CommandRiskScanner.scan(script)
        let tier = CommandRiskScanner.appleScriptReachesShell(script) ? .t4 : ProcessTools.tier(risk)
        return ChatToolProposal(
            tier: tier, stepLabel: AgentToolStep.runAppleScriptApproved,
            summary: "Run an AppleScript", literal: risk.sanitized, risk: risk.flags,
            isTruncated: risk.wasTruncated, auditCode: "tool.run_applescript"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let script = args.text("script"), paths.ensureScratch() else {
            return ChatToolOutcome(content: "Invalid script.", isError: true)
        }
        let result = await runner.run(
            executable: ProcessTools.appleScriptExecutable, arguments: [], cwd: paths.scratch,
            input: Data(script.utf8), timeout: AgentToolLimits.processTimeout
        )
        return ProcessTools.outcome(result)
    }
}

/// `run_shortcut`: `shortcuts run <name>` with the name as one argument (no shell).
struct RunShortcutTool: AgentTool {
    let paths: AgentPathContext
    let runner: AgentProcessRunning
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "run_shortcut",
            description: "Run one of the user's macOS Shortcuts by name. The user must approve.",
            inputSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let name = args.text("name"), name.count <= 200 else {
            return AgentProposals.invalid("tool.run_shortcut", label: AgentToolStep.runShortcutApproved, "name is required")
        }
        let risk = CommandRiskScanner.scan(name)
        let protected = risk.flags.contains(.hiddenCharacters) || CommandRiskScanner.mentionsProtectedPath(name)
        return ChatToolProposal(
            tier: protected ? .t4 : .t2, stepLabel: AgentToolStep.runShortcutApproved,
            summary: "Run a Shortcut", literal: "Shortcut: " + risk.sanitized,
            risk: risk.flags.intersection(.hiddenCharacters), isTruncated: risk.wasTruncated,
            auditCode: "tool.run_shortcut"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let name = args.text("name"), paths.ensureScratch() else {
            return ChatToolOutcome(content: "Invalid shortcut name.", isError: true)
        }
        let result = await runner.run(
            executable: ProcessTools.shortcutsExecutable, arguments: ["run", name], cwd: paths.scratch,
            input: nil, timeout: AgentToolLimits.processTimeout
        )
        return ProcessTools.outcome(result)
    }
}
