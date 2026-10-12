import XCTest
@testable import DesnotchCore

final class HermesEventMapperTests: XCTestCase {
    func testChunkCoalescingUsesTheInjectedTime() {
        var mapper = HermesEventMapper()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = mapper.ingest(update: chunk("It is "), at: start)
        let second = mapper.ingest(update: chunk("sunny"), at: start.addingTimeInterval(0.05))
        let third = mapper.ingest(update: chunk(" today"), at: start.addingTimeInterval(0.1))
        XCTAssertEqual(first.events, [.partial("It is ")])
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(third.events, [.partial("It is sunny today")])
        let long = String(repeating: "a", count: 450)
        let bounded = mapper.ingest(update: chunk(long), at: start.addingTimeInterval(0.2))
        guard case .partial(let text) = bounded.events.first else {
            return XCTFail("missing partial")
        }
        XCTAssertEqual(text.count, 400)
        XCTAssertTrue(text.hasSuffix("a"))
    }

    func testToolKindIsBoundedAndSanitized() {
        XCTAssertEqual(HermesEventMapper.toolKind("terminal: ls -la"), "terminal")
        XCTAssertEqual(HermesEventMapper.toolKind("Clock"), "clock")
        XCTAssertEqual(HermesEventMapper.toolKind("no-colon"), "no-colon")
        XCTAssertEqual(HermesEventMapper.toolKind("Bad Kind: x"), "unknown_tool")
        XCTAssertEqual(HermesEventMapper.toolKind(""), "unknown_tool")
        XCTAssertEqual(HermesEventMapper.toolKind(nil), "unknown_tool")
        XCTAssertEqual(HermesEventMapper.toolKind(String(repeating: "a", count: 41)), "unknown_tool")
        XCTAssertEqual(HermesEventMapper.toolKind("ok_tool.1-name"), "ok_tool.1-name")
    }

    func testSeenIdsPersistAcrossPromptsOfOneSession() {
        var mapper = HermesEventMapper()
        let start = mapper.ingest(update: tool("tc1", title: "terminal: ls", kind: "tool_call"), at: Date())
        XCTAssertEqual(start.events, [.toolActivity(kind: "terminal")])
        mapper.beginPrompt()
        let again = mapper.ingest(update: tool("tc1", title: "terminal: ls", kind: "tool_call_update"), at: Date())
        XCTAssertTrue(again.events.isEmpty)
    }

    func testAccumulatedTextResetsPerPrompt() {
        var mapper = HermesEventMapper()
        _ = mapper.ingest(update: chunk("hello"), at: Date())
        mapper.beginPrompt()
        XCTAssertEqual(mapper.stopEvent(reason: "end_turn"), .finished(summary: ""))
    }

    func testUnrelatedUpdateKindsAreIgnored() {
        var mapper = HermesEventMapper()
        let lines = [
            HermesFixtures.usageUpdate, HermesFixtures.commandsUpdate, HermesFixtures.planUpdate,
            HermesFixtures.thoughtUpdate, HermesFixtures.infoUpdate
        ]
        for line in lines.dropFirst() {
            let ingested = mapper.ingest(update: update(line), at: Date())
            XCTAssertTrue(ingested.events.isEmpty)
        }
        let usage = mapper.ingest(update: update(HermesFixtures.usageUpdate), at: Date())
        XCTAssertEqual(usage.events, [.usage(inputTokens: 3, outputTokens: 4, costMicros: 0)])
        let unknown = mapper.ingest(update: ["sessionUpdate": "future_kind"], at: Date())
        XCTAssertTrue(unknown.events.isEmpty)
    }

    func testEditApprovalFallsBackToTheTitle() {
        var mapper = HermesEventMapper()
        let object = hermesObject(Data(HermesFixtures.editPermission.utf8))
        let params = object["params"] as? [String: Any] ?? [:]
        let ingested = mapper.ingestPermission(params: params, id: object["id"] ?? 0, nonce: "edit-1")
        guard case .approvalNeeded(let card) = ingested.events.first else {
            return XCTFail("missing card")
        }
        XCTAssertEqual(card.literal, "Approve edit: /tmp/note.txt")
        XCTAssertEqual(card.nonce, "edit-1")
        let reply = mapper.reply(nonce: "edit-1", allow: true)
        let outcome = (reply?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["optionId"] as? String, "allow_once")
    }

    func testUsageMapsToAUsageEvent() {
        var mapper = HermesEventMapper()
        let ingested = mapper.ingest(
            update: ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "x"],
                     "inputTokens": 8, "outputTokens": 9],
            at: Date()
        )
        XCTAssertEqual(ingested.events.first, .usage(inputTokens: 8, outputTokens: 9, costMicros: 0))
    }

    func testStopReasonsMapToFailures() {
        var mapper = HermesEventMapper()
        _ = mapper.ingest(update: chunk("It is sunny"), at: Date())
        XCTAssertEqual(mapper.stopEvent(reason: "end_turn"), .finished(summary: "It is sunny"))
        XCTAssertEqual(mapper.stopEvent(reason: "max_turn_requests"), .failed(.agentFailed("stop_max_turn_requests")))
        XCTAssertEqual(mapper.stopEvent(reason: "Nope!"), .failed(.agentFailed("stop_nope")))
        XCTAssertEqual(mapper.stopEvent(reason: "123"), .failed(.agentFailed("stop_unknown")))
        XCTAssertEqual(mapper.stopEvent(reason: "cancelled"), .failed(.agentFailed("stop_cancelled")))
    }

    private func chunk(_ text: String) -> [String: Any] {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]
    }

    private func tool(_ id: String, title: String, kind: String) -> [String: Any] {
        ["sessionUpdate": kind, "toolCallId": id, "title": title]
    }

    private func update(_ line: String) -> [String: Any] {
        let object = hermesObject(Data(line.utf8))
        return ((object["params"] as? [String: Any])?["update"] as? [String: Any]) ?? [:]
    }
}
