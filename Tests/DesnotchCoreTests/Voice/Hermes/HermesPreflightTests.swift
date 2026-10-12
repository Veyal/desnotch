import Darwin
import XCTest
@testable import DesnotchCore

final class HermesPreflightTests: XCTestCase {
    private let binary = URL(fileURLWithPath: "/test/hermes")

    func testP1BinaryMissingRefuses() {
        let locator = HermesLocator(candidates: [binary], isExecutable: { _ in false })
        let result = HermesPreflight.run(
            locator: locator, configReader: HermesMemoryConfig(HermesFixtures.goldenConfig),
            fileFlags: HermesMemoryFlags()
        )
        XCTAssertEqual(result, .refused(.binaryMissing))
    }

    func testP2ProfileMissingRefuses() {
        let result = HermesPreflight.run(
            locator: HermesLocator(candidates: [binary], isExecutable: { _ in true }),
            configReader: HermesMemoryConfig(nil),
            fileFlags: HermesMemoryFlags()
        )
        XCTAssertEqual(result, .refused(.profileMissing))
    }

    func testP3ApprovalsOffRefuses() {
        XCTAssertEqual(run(config: "approvals:\n  mode: off\n"), .refused(.approvalsOff))
        XCTAssertEqual(run(config: "approvals:\n  mode: OFF\n"), .refused(.approvalsOff))
        XCTAssertEqual(run(config: "approvals:\n  other: 1\n"), .refused(.approvalsOff))
        XCTAssertEqual(run(config: "model:\n  name: demo\n"), .refused(.approvalsOff))
        XCTAssertEqual(run(config: "approvals:\n  mode: manual\n  mode: off\n"), .refused(.approvalsOff))
        XCTAssertEqual(run(config: "approvals:\n  mode: *wild\n"), .refused(.approvalsOff))
        XCTAssertEqual(run(config: "approvals:\n  mode:\n"), .refused(.approvalsOff))
    }

    func testP4AllowlistNotEmptyRefuses() {
        XCTAssertEqual(
            run(config: base(allowlist: "\n- rm")),
            .refused(.allowlistNotEmpty)
        )
        XCTAssertEqual(run(config: base(allowlist: "\"rm\"")), .refused(.allowlistNotEmpty))
        XCTAssertEqual(run(config: base(allowlist: "{a: 1}")), .refused(.allowlistNotEmpty))
        XCTAssertEqual(run(config: base(allowlist: "\"\"")), .refused(.allowlistNotEmpty))
        XCTAssertEqual(run(config: goldenWithout("command_allowlist: []")), .ready(profile: "voice"))
    }

    func testP5McpConfiguredRefuses() {
        XCTAssertEqual(run(config: base(mcp: "{demo: {}}")), .refused(.mcpConfigured))
        XCTAssertEqual(run(config: base(mcp: "- demo")), .refused(.mcpConfigured))
        XCTAssertEqual(run(config: base(mcp: "demo")), .refused(.mcpConfigured))
        XCTAssertEqual(run(config: goldenWithout("mcp_servers: {}")), .ready(profile: "voice"))
    }

    func testP6ToolsetOutsideAllowlistRefuses() {
        XCTAssertEqual(run(config: base(tools: "acp:\n    - terminal")), .refused(.toolsetOutsideAllowlist))
        XCTAssertEqual(run(config: base(tools: "other: []")), .refused(.toolsetOutsideAllowlist))
        XCTAssertEqual(run(config: goldenWithout("platform_toolsets:\n  acp: []")), .refused(.toolsetOutsideAllowlist))
    }

    func testP7ConfigNotLockedRefuses() {
        XCTAssertEqual(run(flags: 0), .refused(.configNotLocked))
        XCTAssertEqual(run(flags: nil), .refused(.configNotLocked))
    }

    func testAllGoodFixtureIsReady() {
        XCTAssertEqual(run(config: HermesFixtures.goldenConfig), .ready(profile: "voice"))
        XCTAssertEqual(run(config: HermesFixtures.realisticConfig), .ready(profile: "voice"))
        XCTAssertEqual(run(config: "approvals:\n  mode: SMART\n" + tail), .ready(profile: "voice"))
    }

    func testCheckProtocol() {
        XCTAssertNil(HermesPreflight.checkProtocol(1))
        XCTAssertEqual(HermesPreflight.checkProtocol(2), .refused(.protocolMismatch))
    }

    private var tail: String {
        "command_allowlist: []\nmcp_servers: {}\nplatform_toolsets:\n  acp: []\n"
    }

    private func base(allowlist: String = "[]", mcp: String = "{}", tools: String = "acp: []") -> String {
        """
        approvals:
          mode: manual
        command_allowlist: \(allowlist)
        mcp_servers: \(mcp)
        platform_toolsets:
          \(tools)
        """
    }

    private func goldenWithout(_ section: String) -> String {
        HermesFixtures.goldenConfig.replacingOccurrences(of: section, with: "")
    }

    private func run(config: String? = nil, flags: UInt32? = UInt32(UF_IMMUTABLE)) -> AgentPreflightResult {
        let text = config ?? HermesFixtures.goldenConfig
        return HermesPreflight.run(
            locator: HermesLocator(candidates: [binary], isExecutable: { _ in true }),
            configReader: HermesMemoryConfig(text),
            fileFlags: HermesMemoryFlags(flags)
        )
    }
}
