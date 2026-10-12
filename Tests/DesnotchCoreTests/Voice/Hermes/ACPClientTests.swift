import XCTest
@testable import DesnotchCore

final class ACPClientTests: XCTestCase {
    func testHandshakeSendsTheLiteralRequests() async throws {
        let (client, transport, _) = makeClient()
        _ = try await client.initialize()
        let session = try await client.newSession()
        XCTAssertEqual(session, "s1")
        let objects = transport.sentObjects()
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["method"] as? String, "initialize")
        XCTAssertEqual(objects[0]["id"] as? Int, 1)
        let initParams = objects[0]["params"] as? [String: Any]
        XCTAssertEqual(initParams?["protocolVersion"] as? Int, 1)
        XCTAssertEqual((initParams?["clientCapabilities"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual(objects[1]["method"] as? String, "session/new")
        XCTAssertEqual(objects[1]["id"] as? Int, 2)
        let newParams = objects[1]["params"] as? [String: Any]
        XCTAssertEqual(newParams?["cwd"] as? String, transport.workingDirectory.path)
        XCTAssertEqual((newParams?["mcpServers"] as? [Any])?.isEmpty, true)
    }

    func testToolStartWithoutStatusEmitsOneToolActivity() async throws {
        let (client, transport, _) = makeClient()
        try await handshake(client)
        let stream = try client.prompt("hello")
        let collecting = Task { await collectBounded(stream) }
        transport.emit(line: HermesFixtures.toolStart)
        transport.emit(line: HermesFixtures.toolStart)
        transport.emit(line: toolLine(id: "tc2", title: "!!!", update: "tool_call"))
        transport.emit(line: toolLine(id: "tc3", title: "clock", update: "tool_call_update"))
        transport.emit(line: HermesFixtures.permissionRequest)
        transport.emit(line: toolLine(id: "perm-check-1", title: "terminal: ls", update: "tool_call_update"))
        transport.emit(line: stopLine(3, reason: "end_turn"))
        let collected = await collecting.value
        let events = try XCTUnwrap(collected)
        let tools = events.compactMap { event -> String? in
            if case .toolActivity(let kind) = event { return kind }
            return nil
        }
        XCTAssertEqual(tools, ["terminal", "unknown_tool", "clock"])
    }

    func testPermissionRequestBuildsACardWithRiskAndTier() async throws {
        let (client, transport, _) = makeClient()
        try await handshake(client)
        let stream = try client.prompt("hello")
        let collecting = Task { await collectBounded(stream) }
        transport.emit(line: HermesFixtures.permissionRequest)
        transport.emit(line: HermesFixtures.pipePermission)
        transport.emit(line: stopLine(3, reason: "end_turn"))
        let collected = await collecting.value
        let events = try XCTUnwrap(collected)
        let cards = events.compactMap { event -> ConfirmationRequest? in
            if case .approvalNeeded(let card) = event { return card }
            return nil
        }
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].risk, [.destructive])
        XCTAssertEqual(cards[0].tier, .t2)
        XCTAssertTrue(cards[0].canApprove)
        XCTAssertEqual(cards[0].summary, "Agent wants to run a command")
        XCTAssertEqual(cards[0].source, .hermes)
        XCTAssertTrue(cards[1].risk.contains(.pipeToInterpreter))
        XCTAssertFalse(cards[1].canApprove)
        XCTAssertTrue(cards[1].requiresSecondFactor)
    }

    func testRespondWritesOnlyAllowOnceOrDeny() async throws {
        let (client, transport, _) = makeClient()
        try await handshake(client)
        let stream = try client.prompt("hello")
        var iterator = stream.makeAsyncIterator()
        transport.emit(line: HermesFixtures.permissionRequest)
        let first = await iterator.next()
        guard case .approvalNeeded(let allowCard) = first else {
            return XCTFail("missing allow card")
        }
        let beforeUnknown = transport.sentLines.count
        client.respond(nonce: "missing", allow: true)
        XCTAssertEqual(transport.sentLines.count, beforeUnknown)
        client.respond(nonce: allowCard.nonce, allow: true)
        let allowLine = String(decoding: transport.sentLines.last ?? Data(), as: UTF8.self)
        XCTAssertTrue(allowLine.contains("allow_once"))
        XCTAssertFalse(allowLine.contains("allow_session"))
        XCTAssertFalse(allowLine.contains("allow_always"))
        XCTAssertFalse(allowLine.contains("deny_always"))
        transport.emit(line: HermesFixtures.permissionRequest.replacingOccurrences(
            of: "perm-check-1", with: "perm-check-3"
        ))
        let second = await iterator.next()
        guard case .approvalNeeded(let denyCard) = second else {
            return XCTFail("missing deny card")
        }
        client.respond(nonce: denyCard.nonce, allow: false)
        let denyLine = String(decoding: transport.sentLines.last ?? Data(), as: UTF8.self)
        XCTAssertTrue(denyLine.contains("\"optionId\":\"deny\"") || denyLine.contains("\"optionId\" : \"deny\""))
        XCTAssertFalse(denyLine.contains("allow_once"))
        let unknown = transport.sentLines.count
        client.respond(nonce: "still-missing", allow: false)
        XCTAssertEqual(transport.sentLines.count, unknown)
    }

    func testUnknownServerRequestGetsMethodNotFound() async throws {
        let (client, transport, _) = makeClient()
        try await handshake(client)
        let before = transport.sentLines.count
        transport.emit(line: #"{"jsonrpc":"2.0","id":"abc","method":"session/foo","params":{}}"#)
        for _ in 0..<500 where transport.sentLines.count <= before {
            await Task.yield()
        }
        let error = transport.sentObjects().last?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
        XCTAssertEqual(transport.sentObjects().last?["id"] as? String, "abc")
    }

    func testCancelIsANotificationWithoutAnId() async throws {
        let (client, transport, _) = makeClient()
        try await handshake(client)
        try client.cancel()
        let object = try XCTUnwrap(transport.sentObjects().last)
        XCTAssertEqual(object["method"] as? String, "session/cancel")
        XCTAssertNil(object["id"])
        let params = object["params"] as? [String: Any]
        XCTAssertEqual(params?["sessionId"] as? String, "s1")
    }

    func testProtocolMismatchMapsToProtocolMismatch() async {
        let (client, _, _) = makeClient(version: 2)
        do {
            try await client.initialize()
            XCTFail("expected mismatch")
        } catch let error as ACPClientError {
            XCTAssertEqual(error, .protocolMismatch)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStopReasonsMapToFailures() async throws {
        let (client, transport, _) = makeClient()
        try await handshake(client)
        let first = try client.prompt("hello")
        let collecting = Task { await collectBounded(first) }
        transport.emit(line: chunk("It is sunny"))
        transport.emit(line: stopLine(3, reason: "max_turn_requests"))
        let collected = await collecting.value
        let events = try XCTUnwrap(collected)
        XCTAssertEqual(events.last, .failed(.agentFailed("stop_max_turn_requests")))
        let second = try client.prompt("again")
        let again = Task { await collectBounded(second) }
        transport.emit(line: stopLine(4, reason: "Whatever"))
        let moreCollected = await again.value
        let more = try XCTUnwrap(moreCollected)
        XCTAssertEqual(more.last, .failed(.agentFailed("stop_whatever")))
    }

    private func makeClient(version: Int = 1) -> (ACPClient, HermesFakeTransport, HermesManualScheduler) {
        let transport = HermesFakeTransport()
        transport.protocolVersion = version
        let scheduler = HermesManualScheduler()
        let client = ACPClient(transport: transport, now: { Date() }, scheduler: scheduler, onLateEvent: { _ in })
        return (client, transport, scheduler)
    }

    private func handshake(_ client: ACPClient) async throws {
        try await client.initialize()
        _ = try await client.newSession()
    }

    private func toolLine(id: String, title: String, update: String) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"\#(update)","toolCallId":"\#(id)","title":"\#(title)"}}}"#
    }

    private func stopLine(_ id: Int, reason: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"\#(reason)"}}"#
    }

    private func chunk(_ text: String) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}}}"#
    }
}
