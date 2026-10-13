import Foundation

// WP-LOGIC owns this file. Base commit: fail-closed stub with the final signature.

enum CommandRiskScanner {
    // The dangerous vocabulary lives here as DATA only: one regex constant per line, and one
    // protected path string per line below. Nothing else in this file names those tokens.
    private enum Pat {
        // Optional path (`/bin/sh`) and `env NAME=value` before the interpreter, so
        // `| /bin/sh` and `| env X=1 sh` stay auto-deny.
        static let pipeToInterpreter = #"\|\s*(sudo\s+)?(?:env(?:\s+\S+=\S*)*\s+)?(?:\S*/)?((ba|z|da|k|c|tc)?sh|python[0-9.]*|perl|ruby|node|php|osascript|source)\b"#
        static let base64Flag = #"\bbase64\s+(-d|-D|--decode)\b"#
        static let b64decode = #"\bb64decode\b"#
        static let evalUse = #"\beval\b"#
        static let sudo = #"\b(sudo|doas)\b"#
        static let singlePipe = #"(?<!\|)\|(?!\|)"#
        static let urlScheme = #"\b(https?|ftp|sftp)://"#
        static let networkTool = #"\b(curl|wget|scp|rsync|nc|ncat|netcat|ftp|sftp|telnet|nmap)\b"#
        static let gitPush = #"\bgit\s+push\b"#
        static let sshCommand = #"(?:^|[\s;&|])ssh\s"#
        static let destructive = #"\b(rm|rmdir|mv|kill|killall|pkill|chmod|chown|dd|mkfs|truncate|shred|diskutil)\b"#
        // In-process tools only (see `shellEvasion` / `appleScriptReachesShell`).
        static let globClass = #"\[[^\]]*\]"#
        static let braceExpansion = #"\{[^}]*\}"#
        static let ansiCQuote = #"\$'"#
        static let parameterExpansion = #"\$\{"#
        static let variableExpansion = #"\$[a-z_0-9@*#?!$-]"#
        static let processSubstitution = #"[<>]\("#
        static let sourceBuiltin = #"(?:^|[;&|(\n])\s*(?:source|\.)\s"#
        static let alwaysInterpreter = #"^(osascript|osacompile|awk|gawk|nawk|mawk)$"#
        static let inlineInterpreter = #"^(python[0-9.]*|perl[0-9.]*|ruby|irb|node|nodejs|deno|bun|php|swift|lua|tclsh|jshell|pwsh|sh|bash|zsh|dash|ksh|fish)$"#
        static let inlineCodeFlag = #"^(-[a-z]*[cerp]|--eval|--print|--command|--exec|-)$"#
        static let appleScriptShell = #"\b(do\s+shell\s+script|run\s+script|load\s+script|character\s+id|ascii\s+character)\b"#
    }

    private static let protectedPaths: [String] = [
        ".hermes",
        ".ssh",
        ".env",
        "auth.json",
        "keychain",
        "id_rsa",
        "id_ed25519",
        ".aws/",
        ".gnupg",
        "interseptor",
        "vault",
        "engagement",
        "evidence",
        "pentest",
        "sudoers",
        "/etc/shadow"
    ]

    /// Scans the literal command text of an approval request. Detection runs on the whole
    /// sanitized text before truncation, so a long prefix can never hide a payload.
    static func scan(_ command: String, displayLimit: Int = 2000) -> CommandRisk {
        var flags: RiskFlags = []
        var sanitized = ""
        for scalar in command.unicodeScalars {
            switch scalar.value {
            case 0x09:
                sanitized.append(contentsOf: " ")
            case 0x0A, 0x0D:
                sanitized.append(contentsOf: " \u{23CE} ")
                flags.insert(.chaining)
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F:
                flags.insert(.hiddenCharacters)
            case 0x00AD, 0x061C, 0x200B...0x200F, 0x202A...0x202E,
                 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
                flags.insert(.hiddenCharacters)
            default:
                sanitized.unicodeScalars.append(scalar)
            }
        }
        sanitized = sanitized.trimmingCharacters(in: .whitespaces)
        guard !sanitized.isEmpty else {
            return CommandRisk(flags: [.unscanned], sanitized: "", wasTruncated: false, tier: .t4)
        }

        let lowered = sanitized.lowercased()
        let folded = fold(lowered)
        if matches(Pat.pipeToInterpreter, lowered) || matches(Pat.pipeToInterpreter, folded) {
            flags.insert(.pipeToInterpreter)
        }
        // Every pattern also runs over the quote/backslash-stripped text, so `c\url` or `"su"do`
        // cannot hide a word the shell would still see.
        let either = { (pattern: String) in matches(pattern, lowered) || matches(pattern, folded) }
        if either(Pat.base64Flag) || either(Pat.b64decode) {
            flags.insert(.base64Decode)
        }
        if either(Pat.evalUse) { flags.insert(.evalUse) }
        if lowered.contains("$(") || lowered.contains("`") { flags.insert(.commandSubstitution) }
        if either(Pat.sudo) { flags.insert(.sudo) }
        if mentionsProtected(lowered) || mentionsProtected(folded) || globHitsProtected(folded) {
            flags.insert(.protectedPath)
        }
        if lowered.contains(";") || lowered.contains("&&") || lowered.contains("||") {
            flags.insert(.chaining)
        }
        if matches(Pat.singlePipe, lowered) { flags.insert(.pipe) }
        if lowered.contains(">") || lowered.contains("<") { flags.insert(.redirect) }
        if either(Pat.urlScheme) || either(Pat.networkTool) || either(Pat.gitPush) || either(Pat.sshCommand) {
            flags.insert(.url)
        }
        if either(Pat.destructive) { flags.insert(.destructive) }

        var wasTruncated = false
        if sanitized.count > displayLimit {
            sanitized = String(sanitized.prefix(displayLimit)) + "\u{2026}"
            wasTruncated = true
        }

        let tier: VoiceTier
        if flags.contains(.sudo) || flags.contains(.protectedPath) {
            tier = .t4
        } else if !flags.intersection(.autoDeny).isEmpty {
            tier = .t4
        } else if flags.contains(.url) {
            tier = .t3
        } else {
            tier = .t2
        }
        return CommandRisk(flags: flags, sanitized: sanitized, wasTruncated: wasTruncated, tier: tier)
    }

    /// Stricter check for desnotch's own `run_shell` tool only (the Hermes lane keeps `scan`
    /// unchanged): shell syntax that builds a word or runs code assembled at run time can spell a
    /// protected path or a network tool the scanner never sees, so such a command is refused (T4):
    /// glob classes `[...]`, brace expansion `{...}`, ANSI-C quoting `$'...'`, any parameter or
    /// variable expansion (`${...}`, `$x`, `$1`, `$@`, `$$`...), command substitution (`$(`,
    /// backticks), process substitution (`<(`, `>(`), and the `eval`, `source` and `.` builtins.
    static func shellEvasion(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let patterns = [
            Pat.globClass, Pat.braceExpansion, Pat.ansiCQuote, Pat.parameterExpansion, Pat.variableExpansion,
            Pat.processSubstitution, Pat.sourceBuiltin, Pat.evalUse
        ]
        return lowered.contains("$(") || lowered.contains("`")
            || patterns.contains { matches($0, lowered) || matches($0, fold(lowered)) }
    }

    /// Stricter check for desnotch's own `run_shell` tool only: a script interpreter given its
    /// code inline (`-e`, `-c`, `-E`, `--eval`, combined flags such as `-lc`/`-ne`), on stdin (no
    /// argument, `-`, a `<` redirect) or in a heredoc can assemble a protected path or a network
    /// call at run time, out of the scanner's sight, so it is refused (T4). The AppleScript runner
    /// and awk are refused in any form: AppleScript goes through `run_applescript`, and an awk
    /// program is always inline. Running a script FILE (`python3 tool.py`) stays a T2 card.
    static func inlineInterpreter(_ command: String) -> Bool {
        let folded = fold(command.lowercased())
        let words = folded.split { $0.isWhitespace || ";&|()".contains($0) }.map(String.init)
        for (index, word) in words.enumerated() {
            let name = word.split(separator: "/").last.map(String.init) ?? word
            if matches(Pat.alwaysInterpreter, name) { return true }
            guard matches(Pat.inlineInterpreter, name) else { continue }
            let rest = words.dropFirst(index + 1)
            if rest.isEmpty || folded.contains("<<") { return true }
            if rest.contains(where: { matches(Pat.inlineCodeFlag, $0) || $0.hasPrefix("<") }) { return true }
        }
        return false
    }

    /// Stricter check for desnotch's own `run_applescript` tool only: an AppleScript that can reach
    /// a shell or build a string at run time (`do shell script`, `run script`, `load script`,
    /// `character id`, `ASCII character`, or `&` concatenation) is refused (T4), so shell
    /// commands only ever run through `run_shell`, where the card shows them literally.
    static func appleScriptReachesShell(_ script: String) -> Bool {
        let collapsed = script.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.contains("&") || matches(Pat.appleScriptShell, collapsed)
            || matches(Pat.appleScriptShell, fold(collapsed))
    }

    /// True when a path (or any text) names a protected location. The machine-control file
    /// tools use this for every path they touch and every entry a search returns, so the tools
    /// and the command scanner share one protected-path list.
    static func mentionsProtectedPath(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let folded = fold(lowered)
        return mentionsProtected(lowered) || mentionsProtected(folded) || globHitsProtected(folded)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Drops quotes and backslashes so `$HOME/.h""ermes` still contains `.hermes`.
    private static func fold(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var escaped = false
        for scalar in text.unicodeScalars {
            if escaped {
                escaped = false
                out.append(scalar)
                continue
            }
            if scalar == "\\" {
                escaped = true
                continue
            }
            if scalar == "\"" || scalar == "'" { continue }
            out.append(scalar)
        }
        return String(out)
    }

    private static func mentionsProtected(_ text: String) -> Bool {
        protectedPaths.contains { text.contains($0) }
    }

    /// A token glob such as `~/.herm*` or `auth.js*` that can expand onto a protected path.
    private static func globHitsProtected(_ text: String) -> Bool {
        let tokens = text.split { character in
            character == " " || character == "\t" || character == ";" || character == "|"
                || character == "&" || character == "\n" || character == ">" || character == "<"
        }
        for token in tokens {
            let raw = String(token)
            guard raw.contains("*") || raw.contains("?") else { continue }
            let literalPrefix = raw.prefix { $0 != "*" && $0 != "?" }
            if literalPrefix.count < 3 { continue }
            let pattern = NSRegularExpression.escapedPattern(for: raw)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { continue }
            if protectedCandidates().contains(where: { candidate in
                let range = NSRange(candidate.startIndex..., in: candidate)
                return regex.firstMatch(in: candidate, range: range) != nil
            }) {
                return true
            }
        }
        return false
    }

    private static func protectedCandidates() -> [String] {
        var candidates: [String] = []
        for path in protectedPaths {
            candidates.append(path)
            candidates.append("~/\(path)")
            candidates.append("$home/\(path)")
            for other in protectedPaths where other != path {
                candidates.append("~/\(path)/\(other)")
                candidates.append("\(path)/\(other)")
            }
        }
        return candidates
    }
}
