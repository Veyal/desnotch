import XCTest
@testable import DesnotchCore

/// The shell sandbox is the enforcement boundary of `run_shell`. These tests call the tool's
/// `execute` DIRECTLY (the static classification is skipped on purpose) with a temporary HOME
/// that holds a fake `.ssh/id_rsa` and an engagement folder, and prove the kernel refuses the
/// reads, the network and the writes however the command is spelled. Nothing outside the
/// temporary folder is read or written.
final class AgentShellSandboxTests: XCTestCase {
    private let fixture = ToolsFixture("agent-sandbox")

    override func setUp() {
        super.setUp()
        let home = fixture.paths.home
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("Documents/engagement"), withIntermediateDirectories: true)
        try? Data("SECRET-KEY-123".utf8).write(to: home.appendingPathComponent(".ssh/id_rsa"))
        try? Data("EVIDENCE-456".utf8).write(to: home.appendingPathComponent("Documents/engagement/notes.txt"))
    }

    override func tearDown() {
        fixture.remove()
        super.tearDown()
    }

    private var home: String { AgentToolPaths.canonical(fixture.paths.home).path }

    private func shell(_ command: String) async -> ChatToolOutcome {
        await RunShellTool(paths: fixture.paths, runner: LiveAgentProcessRunner())
            .execute(AgentToolArgs(["command": .string(command)]))
    }

    func testTheSandboxIsAvailableAndOrdinaryCommandsWork() async {
        XCTAssertTrue(AgentShellSandbox.isAvailable)
        let hello = await shell("echo hello; echo ~")
        XCTAssertFalse(hello.isError, hello.content)
        XCTAssertTrue(hello.content.contains("hello"))
        XCTAssertTrue(hello.content.contains(home), "HOME is the temporary home")
        let read = await shell("cat \(home)/Documents/notes.txt")
        XCTAssertTrue(read.content.contains("hello"), read.content)
    }

    func testObfuscatedReadsOfProtectedFilesFail() async {
        let probes = [
            "printf '\(home)/\\x2essh/id_\\x72sa' | xargs cat",
            "python3 -c \"print(open('\(home)/.'+'ss'+'h/id_'+'rsa').read())\"",
            "sqlite3 :memory: \"select readfile('\(home)/.ssh/id_rsa')\"",
            "cat ~/.ssh/id_rsa",
            "X=ssh; cat ~/.$X/id_rsa",
            "cat \(home)/Documents/engagement/notes.txt",
            "cp \(home)/.ssh/id_rsa \(home)/Documents/copy.txt; cat \(home)/Documents/copy.txt"
        ]
        for probe in probes {
            let outcome = await shell(probe)
            XCTAssertFalse(outcome.content.contains("SECRET-KEY-123"), probe)
            XCTAssertFalse(outcome.content.contains("EVIDENCE-456"), probe)
        }
        // The refusals come from the sandbox, not from a broken interpreter: the same reads of
        // an ordinary file work, and the protected ones fail with a permission error.
        let control = await shell("python3 -c \"print(open('\(home)/Documents/'+'notes.txt').read())\"")
        XCTAssertTrue(control.content.contains("hello"), control.content)
        let denied = await shell("python3 -c \"print(open('\(home)/.'+'ss'+'h/id_'+'rsa').read())\"")
        XCTAssertTrue(denied.content.contains("PermissionError"), denied.content)
        let cat = await shell("cat ~/.ssh/id_rsa")
        XCTAssertTrue(cat.content.contains("not permitted"), cat.content)
    }

    func testNetworkIsRefused() async {
        let socket = await shell("python3 -c \"import socket; s=socket.socket(); s.connect(('127.0.0.1', 9))\"")
        XCTAssertTrue(socket.isError)
        XCTAssertTrue(socket.content.contains("PermissionError") || socket.content.contains("not permitted"), socket.content)
        let urllib = await shell("python3 -c \"import urllib.request as u; u.urlopen('http://127.0.0.1:9', timeout=3)\"")
        XCTAssertTrue(urllib.isError)
        XCTAssertTrue(urllib.content.lowercased().contains("not permitted"), urllib.content)
        let curl = await shell("curl -sS -m 3 http://127.0.0.1:9")
        XCTAssertTrue(curl.isError, curl.content)
    }

    func testWritesStayInsideTheAllowedScope() async {
        let hidden = await shell("touch \(home)/.zshrc")
        XCTAssertTrue(hidden.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(home)/.zshrc"))
        let agent = await shell("touch \(home)/Library/LaunchAgents/x.plist")
        XCTAssertTrue(agent.isError)
        let ordinary = await shell("echo ok > \(home)/Documents/out.txt")
        XCTAssertFalse(ordinary.isError, ordinary.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(home)/Documents/out.txt"))
        let scratch = await shell("echo ok > here.txt")
        XCTAssertFalse(scratch.isError, scratch.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.scratch.appendingPathComponent("here.txt").path))
    }

    func testAppleEventRunnersCannotStart() async {
        let outcome = await shell("/usr/bin/osascript -e 'return 1'")
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.content.contains("not permitted"), outcome.content)
    }

    func testProfileShapeAndFailClosedOnUnsafePaths() throws {
        let profile = try XCTUnwrap(AgentShellSandbox.profile(paths: fixture.paths, temporaryDirectory: FileManager.default.temporaryDirectory))
        for line in ["(allow default)", "(deny network*)", "(deny appleevent-send)", "(deny file-write*)", "(literal \"/usr/bin/osascript\")"] {
            XCTAssertTrue(profile.contains(line), line)
        }
        XCTAssertTrue(profile.contains("(subpath \"\(AgentShellSandbox.kernelPath(fixture.paths.home))/.ssh\")"))
        XCTAssertTrue(AgentShellSandbox.kernelPath(FileManager.default.temporaryDirectory).hasPrefix("/private/"))
        XCTAssertTrue(profile.contains("[eE][nN][gG][aA][gG][eE][mM][eE][nN][tT]"))
        var unsafe = fixture.paths
        unsafe.home = URL(fileURLWithPath: "/tmp/evil\") (allow file-read*")
        XCTAssertNil(AgentShellSandbox.profile(paths: unsafe, temporaryDirectory: FileManager.default.temporaryDirectory))
        XCTAssertFalse(AgentShellSandbox.isSafePath("/Users/a\"b"))
        XCTAssertFalse(AgentShellSandbox.isSafePath("/Users/a\\b"))
        XCTAssertTrue(AgentShellSandbox.isSafePath("/Users/des/Library/Application Support/desnotch"))
    }

    func testAShellCallWithoutASafeProfileIsRefused() async {
        var unsafe = fixture.paths
        unsafe.home = URL(fileURLWithPath: "/tmp/evil\")")
        let tool = RunShellTool(paths: unsafe, runner: ToolsScriptedRunner())
        let proposal = await tool.propose(AgentToolArgs(["command": .string("ls")]))
        XCTAssertEqual(proposal.tier, .t3)
        let outcome = await tool.execute(AgentToolArgs(["command": .string("ls")]))
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.content.contains("sandbox"))
    }
}
