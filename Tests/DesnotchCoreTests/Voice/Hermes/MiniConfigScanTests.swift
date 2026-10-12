import XCTest
@testable import DesnotchCore

final class MiniConfigScanTests: XCTestCase {
    func testScalarsAndNestedMaps() throws {
        let scan = try MiniConfigScan(parsing: """
        approvals:
          mode: manual # why
          note: man#ual
          quoted: "say \\"hi\\""
          single: 'it''s'
        platform_toolsets:
          acp: []
        """)
        XCTAssertEqual(scan.value(at: ["approvals", "mode"]), .string("manual"))
        XCTAssertEqual(scan.value(at: ["approvals", "note"]), .string("man#ual"))
        XCTAssertEqual(scan.value(at: ["approvals", "quoted"]), .string("say \"hi\""))
        XCTAssertEqual(scan.value(at: ["approvals", "single"]), .string("it's"))
        XCTAssertEqual(scan.value(at: ["platform_toolsets", "acp"]), .list([]))
        XCTAssertNil(scan.value(at: ["missing"]))

        let flow = try MiniConfigScan(parsing: "approvals: {mode: off}\n")
        XCTAssertEqual(flow.value(at: ["approvals", "mode"]), .string("off"))
        let listed = try MiniConfigScan(parsing: "command_allowlist: [rm]\n")
        XCTAssertEqual(listed.value(at: ["command_allowlist"]), .list([.string("rm")]))
        let empty = try MiniConfigScan(parsing: "command_allowlist:\napprovals:\n  mode: manual\n")
        XCTAssertEqual(empty.value(at: ["command_allowlist"]), .string(""))
    }

    func testBlockListsAndIndentlessSequences() throws {
        let scan = try MiniConfigScan(parsing: """
        command_allowlist:
        - rm
        platform_toolsets:
          acp:
          - terminal
        """)
        XCTAssertEqual(scan.value(at: ["command_allowlist"]), .list([.string("rm")]))
        XCTAssertEqual(scan.value(at: ["platform_toolsets", "acp"]), .list([.string("terminal")]))
    }

    func testAnchorsAliasesAndMergeKeysThrowAnywhere() {
        let samples = [
            "note: *wild\n",
            "x: &a 1\n",
            "y: *a\n",
            "<<: *base\n",
            "list: [&a 1]\n",
            "list: [a, *b]\n",
            "m: {k: &a v}\n",
            "- &a x\n",
            "skills:\n  name: *wild\n",
            "display:\n  <<: *base\n"
        ]
        for sample in samples {
            XCTAssertThrowsError(try MiniConfigScan(parsing: sample)) { error in
                XCTAssertEqual(error as? MiniConfigScanError, .unsupported)
            }
        }
        XCTAssertNoThrow(try MiniConfigScan(parsing: "url: http://h/?a=1&b=2\n"))
        XCTAssertNoThrow(try MiniConfigScan(parsing: "note: 2 * 3\n"))
        XCTAssertNoThrow(try MiniConfigScan(parsing: "q: \"&a\"\n"))
        XCTAssertNoThrow(try MiniConfigScan(parsing: "q: 'x *y'\n"))
        XCTAssertNoThrow(try MiniConfigScan(parsing: "a*b: 1\n"))
    }

    func testDuplicateKeysThrow() {
        XCTAssertThrowsError(try MiniConfigScan(parsing: "approvals:\n  mode: manual\n  mode: off\n"))
        XCTAssertThrowsError(try MiniConfigScan(parsing: "approvals:\n  mode: manual\napprovals:\n  mode: off\n"))
        XCTAssertThrowsError(try MiniConfigScan(parsing: "approvals:\n  \"mode\": off\n"))
        XCTAssertThrowsError(try MiniConfigScan(parsing: "\"approvals\":\n  mode: manual\n"))
        XCTAssertThrowsError(try MiniConfigScan(parsing: "approvals:\n\tmode: manual\n"))
        XCTAssertThrowsError(try MiniConfigScan(parsing: "approvals:\n  mode: manual\n---\n"))
        XCTAssertThrowsError(try MiniConfigScan(parsing: "approvals:\n  mode: manual\n...\n"))
        XCTAssertThrowsError(try MiniConfigScan(parsing: "approvals:\n  mode: |\n    folded\n"))
    }

    func testSkippedSectionsWithBlockScalarsDoNotThrow() throws {
        let scan = try MiniConfigScan(parsing: HermesFixtures.realisticConfig)
        XCTAssertEqual(scan.value(at: ["approvals", "mode"]), .string("manual"))
        XCTAssertEqual(scan.value(at: ["command_allowlist"]), .list([]))
        XCTAssertEqual(scan.value(at: ["mcp_servers"]), .map([:]))
        XCTAssertEqual(scan.value(at: ["platform_toolsets", "acp"]), .list([]))
        XCTAssertNil(scan.value(at: ["model"]))
        XCTAssertNil(scan.value(at: ["display"]))
        XCTAssertNil(scan.value(at: ["skills"]))
    }

    func testGoldenAndRealisticFixturesParse() throws {
        let golden = try MiniConfigScan(parsing: HermesFixtures.goldenConfig)
        XCTAssertEqual(golden.value(at: ["approvals", "mode"]), .string("manual"))
        XCTAssertEqual(golden.value(at: ["command_allowlist"]), .list([]))
        XCTAssertEqual(golden.value(at: ["mcp_servers"]), .map([:]))
        XCTAssertEqual(golden.value(at: ["platform_toolsets", "acp"]), .list([]))
        _ = try MiniConfigScan(parsing: HermesFixtures.realisticConfig)
    }
}
