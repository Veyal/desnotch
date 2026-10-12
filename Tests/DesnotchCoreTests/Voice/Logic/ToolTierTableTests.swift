import XCTest
@testable import DesnotchCore

final class ToolTierTableTests: XCTestCase {
    func testT1_clock() { XCTAssertEqual(ToolTierTable.tier(forTool: "clock"), .t0) }

    func testT2_calculatorCaseInsensitive() {
        XCTAssertEqual(ToolTierTable.tier(forTool: "Calculator"), .t0)
    }

    func testT3_getTime() { XCTAssertEqual(ToolTierTable.tier(forTool: "get_time"), .t0) }

    func testT4_nowPlaying() { XCTAssertEqual(ToolTierTable.tier(forTool: "now_playing"), .t0) }

    func testT5_timeUppercase() { XCTAssertEqual(ToolTierTable.tier(forTool: "TIME"), .t0) }

    func testT6_readFile() { XCTAssertEqual(ToolTierTable.tier(forTool: "read_file"), .t2) }

    func testT7_listFiles() { XCTAssertEqual(ToolTierTable.tier(forTool: "list_files"), .t2) }

    func testT8_writeFile() { XCTAssertEqual(ToolTierTable.tier(forTool: "write_file"), .t2) }

    func testT9_patch() { XCTAssertEqual(ToolTierTable.tier(forTool: "patch"), .t2) }

    func testT10_deleteFile() { XCTAssertEqual(ToolTierTable.tier(forTool: "delete_file"), .t2) }

    func testT11_createNote() { XCTAssertEqual(ToolTierTable.tier(forTool: "create_note"), .t2) }

    func testT12_killProcess() { XCTAssertEqual(ToolTierTable.tier(forTool: "kill_process"), .t2) }

    func testT13_terminal() { XCTAssertEqual(ToolTierTable.tier(forTool: "terminal"), .t3) }

    func testT14_executeCode() { XCTAssertEqual(ToolTierTable.tier(forTool: "execute_code"), .t3) }

    func testT15_webSearch() { XCTAssertEqual(ToolTierTable.tier(forTool: "web_search"), .t3) }

    func testT16_browserNavigate() {
        XCTAssertEqual(ToolTierTable.tier(forTool: "browser_navigate"), .t3)
    }

    func testT17_computerUse() { XCTAssertEqual(ToolTierTable.tier(forTool: "computer_use"), .t3) }

    func testT18_sendMessage() { XCTAssertEqual(ToolTierTable.tier(forTool: "send_message"), .t3) }

    func testT19_cronCreate() { XCTAssertEqual(ToolTierTable.tier(forTool: "cron_create"), .t3) }

    func testT20_mcpNotionSearch() {
        XCTAssertEqual(ToolTierTable.tier(forTool: "mcp__notion__notion-search"), .t3)
    }

    func testT21_interseptorSendRequest() {
        XCTAssertEqual(ToolTierTable.tier(forTool: "interseptor_send_request"), .t4)
    }

    func testT22_vaultRead() { XCTAssertEqual(ToolTierTable.tier(forTool: "vault_read"), .t4) }

    func testT23_sshExec() { XCTAssertEqual(ToolTierTable.tier(forTool: "ssh_exec"), .t4) }

    func testT24_keychainGet() { XCTAssertEqual(ToolTierTable.tier(forTool: "keychain_get"), .t4) }

    func testT25_readEnvToken() { XCTAssertEqual(ToolTierTable.tier(forTool: "read_env_token"), .t4) }

    func testT26_hermesConfigEdit() {
        XCTAssertEqual(ToolTierTable.tier(forTool: "hermes_config_edit"), .t4)
    }

    func testT27_findingCreate() { XCTAssertEqual(ToolTierTable.tier(forTool: "finding_create"), .t4) }

    func testT28_unknownTool() { XCTAssertEqual(ToolTierTable.tier(forTool: "unknown_tool_xyz"), .t3) }

    func testT29_empty() { XCTAssertEqual(ToolTierTable.tier(forTool: ""), .t3) }

    func testT30_spacesOnly() { XCTAssertEqual(ToolTierTable.tier(forTool: "   "), .t3) }

    func testT31_timeTravelIsNotTime() {
        XCTAssertEqual(ToolTierTable.tier(forTool: "time_travel"), .t3)
    }

    func testT32_trailingSpaceIsNotTrimmed() {
        XCTAssertEqual(ToolTierTable.tier(forTool: "Clock "), .t3)
    }
}
