import Foundation

/// The automatic execution boundary for commands proposed by an agent.
///
/// This is intentionally an argv policy, rather than a list of executable names:
/// an otherwise harmless executable can still write files or change Git's view of
/// the repository through an option.  Anything not explicitly described below is
/// sent through the confirmation UI.
public struct AgentCommandPolicy {
    public var readOnlyCommands: Set<String> = ["pwd", "ls", "cat", "head", "tail", "wc", "whoami", "date", "uname", "git"]

    public init(readOnlyCommands: Set<String>? = nil) {
        if let readOnlyCommands { self.readOnlyCommands = readOnlyCommands }
    }

    /// `cwd` is the directory in which the command will actually execute.
    public func decision(for proposal: AgentCommandProposal, cwd: URL) -> AgentCommandPolicyDecision {
        guard isWellFormed(proposal) else { return .blocked(reason: "The command proposal is malformed or too large.") }

        let command = URL(fileURLWithPath: proposal.command).lastPathComponent.lowercased()
        let combined = proposal.argv.joined(separator: " ").lowercased()

        if proposal.command.contains("/") { return .confirmationRequired(reason: "Explicit executable paths always require confirmation.") }
        let sensitiveFragments = [".ssh", ".aws", ".gnupg", ".env", "credentials", "id_rsa", "id_ed25519", "keychain", "password", "api_key", "apikey", "token", "secret", "authorization"]
        if sensitiveFragments.contains(where: combined.contains) { return .confirmationRequired(reason: "The command may access credentials or secrets.") }
        let alwaysConfirm = ["sudo", "ssh", "scp", "sftp", "curl", "wget", "nc", "ncat", "rm", "rmdir", "mv", "cp", "mkdir", "touch", "chmod", "chown", "install", "brew", "npm", "pnpm", "yarn", "pip", "pip3", "gem", "cargo", "security", "osascript", "dd", "mkfs", "diskutil", "kill", "pkill", "launchctl"]
        if alwaysConfirm.contains(command) { return .confirmationRequired(reason: "This command can write, delete, install, use the network, access credentials, or control another process.") }
        let shellOrInterpreter = ["sh", "bash", "zsh", "fish", "python", "python3", "ruby", "perl", "node", "env", "xargs", "find", "eval"]
        if shellOrInterpreter.contains(command) { return .confirmationRequired(reason: "Shell and interpreter commands always require confirmation.") }
        let shellOperators = ["|", ";", "&&", "||", ">", "<", "`", "$(", "\n"]
        if shellOperators.contains(where: combined.contains) { return .confirmationRequired(reason: "Shell operators always require confirmation.") }
        if combined.contains("http://") || combined.contains("https://") { return .confirmationRequired(reason: "Network access always requires confirmation.") }
        guard readOnlyCommands.contains(command) else { return .confirmationRequired(reason: "This command is not on the read-only allowlist.") }

        let valid: Bool
        switch command {
        case "pwd", "whoami", "date": valid = proposal.arguments.isEmpty
        case "uname": valid = proposal.arguments.allSatisfy { ["-a", "-s", "-n", "-r", "-v", "-m", "-p", "-i", "-o"].contains($0) }
        case "ls": valid = validateSimple(arguments: proposal.arguments, options: ["-a", "-l", "-h", "-la", "-al"], cwd: cwd)
        case "cat": valid = validateSimple(arguments: proposal.arguments, options: [], cwd: cwd)
        case "head", "tail": valid = validateHeadTail(arguments: proposal.arguments, cwd: cwd)
        case "wc": valid = validateSimple(arguments: proposal.arguments, options: ["-l", "-w", "-c", "-m"], cwd: cwd)
        case "git": valid = validateGit(arguments: proposal.arguments, cwd: cwd)
        default: valid = false
        }
        return valid ? .readOnly : .confirmationRequired(reason: "The command arguments are not on the automatic read-only allowlist.")
    }

    /// Compatibility overload for callers that do not yet provide execution cwd.
    /// Production execution must use the cwd-taking overload.
    public func decision(for proposal: AgentCommandProposal) -> AgentCommandPolicyDecision {
        decision(for: proposal, cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    private func validateSimple(arguments: [String], options: Set<String>, cwd: URL) -> Bool {
        let paths = arguments.filter { !$0.hasPrefix("-") }
        return arguments.allSatisfy { $0.hasPrefix("-") ? options.contains($0) : isSafePath($0, cwd: cwd) } && paths.count <= 32
    }

    private func validateHeadTail(arguments: [String], cwd: URL) -> Bool {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "-n" || arg == "-c" {
                index += 1
                guard index < arguments.count, arguments[index].allSatisfy(\.isNumber) else { return false }
            } else if arg.hasPrefix("-") {
                guard arg == "-q" || arg == "-v" || (arg.hasPrefix("-") && arg.dropFirst().allSatisfy(\.isNumber)) else { return false }
            } else if !isSafePath(arg, cwd: cwd) { return false }
            index += 1
        }
        return true
    }

    private func validateGit(arguments: [String], cwd: URL) -> Bool {
        guard let subcommandIndex = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else { return false }
        let subcommand = arguments[subcommandIndex].lowercased()
        guard ["status", "diff", "log", "show", "branch", "rev-parse"].contains(subcommand) else { return false }
        // No global/config/worktree/output option is admitted. Unknown options are
        // rejected too, so new Git write/config features fail closed by default.
        let allowed: Set<String> = ["--short", "-s", "--porcelain", "--branch", "-b", "--stat", "--name-only", "--name-status", "--no-ext-diff", "--oneline", "--list", "-a", "--all", "--show-current", "--show-toplevel", "--is-inside-work-tree", "--color=never", "--", "-n"]
        var afterSeparator = false
        for (index, arg) in arguments.enumerated() {
            if index == subcommandIndex { continue }
            if arg == "--" { afterSeparator = true; continue }
            if arg == "-n" {
                guard index + 1 < arguments.count, arguments[index + 1].allSatisfy(\.isNumber) else { return false }
                continue
            }
            if arg.hasPrefix("-") {
                guard allowed.contains(arg) else { return false }
            } else {
                // Refs are permitted for show/log; path operands are only
                // permitted after `--`, where Git unambiguously treats them as
                // paths and we can enforce the canonical cwd boundary.
                if !afterSeparator && (subcommand == "show" || subcommand == "log") { continue }
                guard isSafePath(arg, cwd: cwd) else { return false }
            }
        }
        if subcommand == "branch" {
            let operands = arguments.enumerated().filter { $0.offset != subcommandIndex && !$0.element.hasPrefix("-") }
            guard operands.isEmpty || arguments.contains("--list") else { return false }
        }
        return true
    }

    private func isSafePath(_ argument: String, cwd: URL) -> Bool {
        guard !argument.isEmpty, !argument.hasPrefix("/"), !argument.hasPrefix("~"), !argument.contains("\0") else { return false }
        let base = cwd.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(argument).standardizedFileURL.resolvingSymlinksInPath()
        return target.path == base.path || target.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/")
    }

    private func isWellFormed(_ proposal: AgentCommandProposal) -> Bool {
        let bytes = proposal.argv.reduce(0) { $0 + $1.utf8.count }
        return !proposal.command.isEmpty && proposal.command.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && !proposal.command.utf8.contains(0) && proposal.arguments.count <= 64 && bytes <= 16 * 1024 && !proposal.arguments.contains(where: { $0.utf8.contains(0) })
    }
}
