import Foundation

/// The enforcement boundary of `run_shell`. Static classification (`CommandRiskScanner`) is only
/// layer 1: a shell can always assemble a path or a network call at run time. Every approved
/// command therefore runs under `/usr/bin/sandbox-exec` with a profile generated here, and the
/// kernel refuses what the policy forbids however the command was spelled:
/// - no network at all (`network*`), no Apple Events, no LaunchServices or Apple Event lookups;
/// - no exec of the AppleScript runners, `open`, `shortcuts`, `automator` or terminal apps;
/// - no read or write of protected locations (`~/.ssh`, `~/.hermes`, `~/.gnupg`, `~/.aws`,
///   `~/.config/gh`, keychains, desnotch's own voice folder, and any path under home that names a
///   protected marker such as `engagement`, `evidence` or `pentest`);
/// - writes only to the scratch folder, the temporary folders, and home's ordinary folders (not
///   hidden ones, not `~/Library`), the same scope `write_file` allows.
/// SBPL applies the LAST matching rule, so the order of the rules below is the policy.
enum AgentShellSandbox {
    static let executable = "/usr/bin/sandbox-exec"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    /// Hidden folders under home that are always off limits, besides the shared markers.
    static let protectedHomeFolders = [
        ".ssh", ".hermes", ".gnupg", ".aws", ".config/gh", ".netrc", ".interseptor", ".docker", ".kube",
        "Library/Keychains"
    ]

    /// Executables a sandboxed command may not start (a terminal or an Apple Event sender would
    /// run outside this sandbox).
    static let deniedExecutables = [
        ProcessTools.appleScriptExecutable, "/usr/bin/osacompile", "/usr/bin/open", ProcessTools.shortcutsExecutable,
        "/usr/bin/automator"
    ]

    static let terminalApps = [
        "/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app",
        "/Applications/iTerm.app", "/Applications/Warp.app", "/Applications/Ghostty.app", "/Applications/kitty.app",
        "/Applications/Alacritty.app", "/Applications/WezTerm.app", "/Applications/Hyper.app", "/Applications/Tabby.app"
    ]

    /// The profile for one run, or nil when a path cannot be expressed safely (the tool then
    /// refuses to run: fail closed).
    static func profile(paths: AgentPathContext, temporaryDirectory: URL) -> String? {
        let home = kernelPath(paths.home)
        let scratch = kernelPath(paths.scratch)
        let temp = (kernelPath(temporaryDirectory) as NSString).deletingLastPathComponent
        let denied = paths.denied.map(kernelPath)
        let all = [home, scratch, temp] + denied
        guard all.allSatisfy(isSafePath) else { return nil }
        let homeRegex = regexEscaped(home)
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(deny appleevent-send)",
            #"(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.coreservices.appleevents"))"#,
            "(deny process-exec " + (deniedExecutables.map { "(literal \"\($0)\")" }
                + terminalApps.map { "(subpath \"\($0)\")" }).joined(separator: " ") + ")",
            "(deny file-write*)",
            "(allow file-write* (subpath \"/private/tmp\") (subpath \"\(temp)\") (regex #\"^/dev/(null|zero|tty.*|fd/.*)$\"))",
            "(deny file-write* (subpath \"\(home)\"))",
            "(allow file-write* (subpath \"\(home)\"))",
            "(deny file-write* (subpath \"\(home)/Library\") (regex #\"^\(homeRegex)/(.*/)?\\.[^/]*\"))",
            "(allow file-write* (subpath \"\(scratch)\"))"
        ]
        var protected = protectedHomeFolders.map { "(subpath \"\(home)/\($0)\")" }
        protected += denied.map { "(subpath \"\($0)\")" }
        protected += CommandRiskScanner.protectedMarkers.filter { !$0.hasPrefix("/") }.map { marker in
            "(regex #\"^\(homeRegex)/.*\(caseInsensitive(marker))\")"
        }
        protected += ["(subpath \"/private/etc/sudoers\")", "(subpath \"/private/etc/sudoers.d\")", "(subpath \"/Library/Keychains\")"]
        lines.append("(deny file-read* file-write* " + protected.joined(separator: " ") + ")")
        return lines.joined(separator: "\n")
    }

    /// The path as the kernel sees it: `realpath(3)` of the deepest existing ancestor plus the
    /// rest. (Foundation's symlink resolution turns `/private/var/...` into `/var/...`, which a
    /// sandbox rule would never match.)
    static func kernelPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL.path
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing) && existing != "/" {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var resolved = existing
        if let real = realpath(existing, nil) {
            resolved = String(cString: real)
            free(real)
        }
        for component in tail {
            resolved = (resolved as NSString).appendingPathComponent(component)
        }
        return resolved
    }

    /// Only characters that need no quoting inside an SBPL string; anything else (quotes,
    /// backslashes, control characters, parentheses) refuses the profile instead of escaping it.
    static func isSafePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-@+~ ,"))
        return path.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// Escapes the only regex metacharacters `isSafePath` lets through (`.` and `+`).
    static func regexEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "+", with: "\\+")
    }

    /// `engagement` as `[eE][nN]...`, regex metacharacters escaped (SBPL has no case flag).
    static func caseInsensitive(_ marker: String) -> String {
        var out = ""
        for character in marker {
            let lower = Character(character.lowercased())
            let upper = Character(character.uppercased())
            if lower != upper {
                out += "[\(lower)\(upper)]"
            } else if ".+*?()[]{}|^$\\".contains(character) {
                out += "\\\(character)"
            } else {
                out.append(character)
            }
        }
        return out
    }
}
