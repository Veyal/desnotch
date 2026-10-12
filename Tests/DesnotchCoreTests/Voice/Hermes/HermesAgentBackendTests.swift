import Darwin
import XCTest
@testable import DesnotchCore

@MainActor
final class HermesAgentBackendTests: XCTestCase {
    private var directory: URL?
    private var backends: [HermesAgentBackend] = []

    nonisolated override func tearDown() {
        MainActor.assumeIsolated {
            for backend in backends { backend.terminateNow() }
            backends.removeAll()
            if let directory { try? FileManager.default.removeItem(at: directory) }
            self.directory = nil
        }
        super.tearDown()
    }

    func testBackendSpawnsTheResolvedPathAfterHermesAppearsLater() async {
        let world = makeWorld(executable: false)
        XCTAssertTrue(world.transports.items.isEmpty)
        let refused = await collectBounded(world.backend.submit("hello"))
        XCTAssertEqual(refused, [.failed(.preflightRefused(.binaryMissing))])
        XCTAssertTrue(world.transports.items.isEmpty)
        world.executable.value = true
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await untilPrompt(world)
        let arguments = world.transports.launches.last?.arguments ?? []
        XCTAssertEqual(Array(arguments.suffix(4)), ["/test/hermes", "-p", "voice", "acp"])
        world.transports.items.last?.emit(line: stop(3))
        let events = await collecting.value
        XCTAssertEqual(events?.first, .status("started"))
        XCTAssertEqual(events?.last, .finished(summary: ""))
    }

    func testStopDuringSpawnNeverSendsPrompt() async {
        let world = makeWorld()
        world.recipe.onStart = { _ in world.box.backend?.terminateNow() }
        let events = await collectBounded(world.backend.submit("hello"))
        XCTAssertEqual(events, [.failed(.agentFailed("stop_cancelled"))])
        XCTAssertFalse(world.transports.items.last?.sentMethods().contains("session/prompt") == true)
        XCTAssertGreaterThanOrEqual(world.transports.items.last?.terminateCount ?? 0, 1)
    }

    func testStopDuringHandshakeNeverSendsLaterRequests() async {
        await assertStopped(at: "initialize") { await $0.cancelTurn() }
        await assertStopped(at: "initialize") { _ = await $0.emergencyStop() }
        await assertStopped(at: "initialize") { $0.terminateNow() }
    }

    func testStopDuringSessionNewNeverSendsPrompt() async {
        await assertStopped(at: "session/new") { await $0.cancelTurn() }
        await assertStopped(at: "session/new") { _ = await $0.emergencyStop() }
        await assertStopped(at: "session/new") { $0.terminateNow() }
    }

    func testTerminateNowFromTheSendHookNeverSendsPrompt() async {
        let world = makeWorld()
        world.recipe.onSend = { _, data in
            let method = hermesObject(data)["method"] as? String
            if method == "session/new" { world.box.backend?.terminateNow() }
        }
        let events = await collectBounded(world.backend.submit("hello"))
        XCTAssertEqual(events, [.failed(.agentFailed("stop_cancelled"))])
        XCTAssertFalse(world.transports.methods.contains("session/prompt"))
        XCTAssertGreaterThanOrEqual(world.transports.items.last?.terminateCount ?? 0, 1)
    }

    func testCancelEscalatesToKillWhenAgentIgnoresIt() async {
        let world = makeWorld()
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await untilPrompt(world)
        let first = world.transports.items[0]
        await world.backend.cancelTurn()
        XCTAssertTrue(first.sentMethods().contains("session/cancel"))
        XCTAssertEqual(first.terminateCount, 0)
        let events = await collecting.value
        XCTAssertEqual(events?.last, .failed(.agentFailed("stop_cancelled")))
        fire(world, delay: VoiceTiming.hardStopGrace)
        XCTAssertEqual(first.terminateCount, 1)
        let next = world.backend.submit("again")
        let again = Task { await collectBounded(next) }
        await untilTransport(world, index: 1)
        XCTAssertEqual(world.transports.items.count, 2)
        XCTAssertTrue(world.transports.items[1].sentMethods().contains("session/prompt"))
        world.transports.items[1].emit(line: stop(3))
        _ = await again.value
    }

    func testCancelTurnDeniesAnOpenPermissionRequest() async {
        let world = makeWorld()
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await untilPrompt(world)
        world.transports.items[0].emit(line: HermesFixtures.permissionRequest)
        await CoordTestSupport.settle(self, until: { world.scheduler.scheduledDelays.contains(60) })
        await world.backend.cancelTurn()
        let objects = world.transports.items[0].sentObjects()
        let deny = objects.firstIndex { object in
            let outcome = (object["result"] as? [String: Any])?["outcome"] as? [String: Any]
            return outcome?["optionId"] as? String == "deny"
        }
        let cancel = objects.firstIndex { ($0["method"] as? String) == "session/cancel" }
        XCTAssertNotNil(deny)
        XCTAssertNotNil(cancel)
        XCTAssertLessThan(deny ?? 0, cancel ?? 0)
        XCTAssertFalse(objects.contains { object in
            let outcome = (object["result"] as? [String: Any])?["outcome"] as? [String: Any]
            return outcome?["optionId"] as? String == "allow_once"
        })
        _ = await collecting.value
    }

    func testCancelWithPromptResponseBeforeGraceDoesNotKill() async {
        let world = makeWorld()
        _ = world.backend.submit("hello")
        await untilPrompt(world)
        await world.backend.cancelTurn()
        let before = world.scheduler.cancelledCount
        world.transports.items[0].emit(line: stop(3))
        await CoordTestSupport.settle(self, until: { world.scheduler.cancelledCount > before })
        fire(world, delay: VoiceTiming.hardStopGrace)
        XCTAssertEqual(world.transports.items[0].terminateCount, 0)
    }

    func testLateToolStartAfterCancelKills() async {
        let killing = makeWorld()
        _ = killing.backend.submit("hello")
        await untilPrompt(killing)
        await killing.backend.cancelTurn()
        killing.transports.items[0].emit(line: tool("tc-late", update: "tool_call", title: "terminal: ls"))
        await CoordTestSupport.settle(self, until: { killing.transports.items[0].terminateCount >= 1 })
        XCTAssertEqual(killing.transports.items[0].terminateCount, 1)

        let permission = makeWorld()
        let snap = IntBox()
        _ = permission.backend.submit("hello")
        await untilPrompt(permission)
        await permission.backend.cancelTurn()
        permission.recipe.onSend = { transport, data in
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("\"optionId\":\"deny\"") { snap.set(transport.terminateCount) }
        }
        permission.transports.items[0].emit(line: HermesFixtures.permissionRequest)
        await CoordTestSupport.settle(self, until: { permission.transports.items[0].terminateCount >= 1 })
        XCTAssertEqual(snap.value, 0)
        XCTAssertEqual(permission.transports.items[0].terminateCount, 1)

        let seen = makeWorld()
        let noticed = Bit()
        let stream = seen.backend.submit("hello")
        let collecting = Task {
            for await event in stream {
                if case .toolActivity = event { noticed.setTrue() }
            }
        }
        await untilPrompt(seen)
        seen.transports.items[0].emit(line: tool("tc1", update: "tool_call", title: "terminal: ls"))
        await CoordTestSupport.settle(self, until: { noticed.value })
        await seen.backend.cancelTurn()
        seen.transports.items[0].emit(line: tool("tc1", update: "tool_call_update", title: "terminal: ls"))
        for _ in 0..<40 { await CoordTestSupport.drainMainRound() }
        XCTAssertEqual(seen.transports.items[0].terminateCount, 0)
        _ = await collecting.value
    }

    func testSubmitWhileCancelledProcessAliveCompletesTheKillFirst() async {
        let world = makeWorld()
        _ = world.backend.submit("hello")
        await untilPrompt(world)
        await world.backend.cancelTurn()
        XCTAssertEqual(world.transports.items[0].terminateCount, 0)
        let next = world.backend.submit("again")
        let collecting = Task { await collectBounded(next) }
        await untilTransport(world, index: 1)
        XCTAssertGreaterThanOrEqual(world.recordedKills.value, 1)
        XCTAssertEqual(world.transports.items[0].terminateCount, 1)
        XCTAssertTrue(world.transports.items[1].sentMethods().contains("session/prompt"))
        world.transports.items[1].emit(line: stop(3))
        _ = await collecting.value
    }

    func testSubmitWhilePromptInFlightIsRefusedBusy() async {
        let world = makeWorld()
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await untilPrompt(world)
        let before = world.transports.items[0].sentLines.count
        let busy = await collectBounded(world.backend.submit("again"))
        XCTAssertEqual(busy, [.failed(.agentFailed("busy"))])
        XCTAssertEqual(world.transports.items[0].sentLines.count, before)
        world.transports.items[0].emit(line: stop(3))
        _ = await collecting.value
    }

    func testAppCompositionConstructsTheHermesBackendOnlyInsideTheNotSmokeTestBranch() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<12 {
            let candidate = directory.appendingPathComponent("Sources/DesnotchCore/App/AppComposition.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            directory.deleteLastPathComponent()
        }
        let url = try XCTUnwrap(found)
        let text = try String(contentsOf: url, encoding: .utf8)
        let sourceLines = text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let backendLines = sourceLines.enumerated().filter { $0.element.contains("HermesAgentBackend(") }
        let guardLines = sourceLines.enumerated().filter { $0.element.contains("if !smokeTestMode {") }
        XCTAssertEqual(backendLines.count, 1)
        XCTAssertEqual(guardLines.count, 1)
        let guardIndex = guardLines[0].offset
        let backendIndex = backendLines[0].offset
        XCTAssertLessThan(guardIndex, backendIndex)
        var balance = 0
        for line in sourceLines[guardIndex...backendIndex] {
            balance += line.filter { $0 == "{" }.count
            balance -= line.filter { $0 == "}" }.count
        }
        XCTAssertGreaterThanOrEqual(balance, 1)
    }

    func testSlashPrefixedUtteranceIsRefusedWithoutSpawning() async {
        let world = makeWorld()
        let command = await collectBounded(world.backend.submit("/model gpt"))
        let compress = await collectBounded(world.backend.submit("  /compress"))
        XCTAssertEqual(command, [.failed(.agentFailed("slash_prefix"))])
        XCTAssertEqual(compress, [.failed(.agentFailed("slash_prefix"))])
        XCTAssertEqual(world.config.readCount, 0)
        XCTAssertTrue(world.transports.items.isEmpty)
        _ = world.backend.submit("what is 1/2")
        await CoordTestSupport.settle(self, until: { world.config.readCount > 0 })
        XCTAssertGreaterThan(world.config.readCount, 0)
    }

    func testBackoffAfterProcessExitFailsFast() async {
        let world = makeWorld()
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await untilPrompt(world)
        world.transports.items[0].simulateExit(uptime: 0.1)
        let exited = await collecting.value
        XCTAssertEqual(exited?.last, .failed(.agentFailed("process_exited")))
        let again = await collectBounded(world.backend.submit("again"))
        XCTAssertEqual(again, [.failed(.agentFailed("backoff"))])
        XCTAssertEqual(world.transports.items.count, 1)
        world.clock.advance(1)
        let third = world.backend.submit("third")
        let thirdEvents = Task { await collectBounded(third) }
        await untilTransport(world, index: 1)
        XCTAssertEqual(world.transports.items.count, 2)
        world.transports.items[1].emit(line: stop(3))
        _ = await thirdEvents.value
    }

    func testSpawnFailureMapsToSpawnFailed() async {
        let world = makeWorld(failStart: true)
        let events = await collectBounded(world.backend.submit("hello"))
        XCTAssertEqual(events, [.failed(.agentFailed("spawn_failed"))])
        XCTAssertEqual(world.backendEpoch, world.epochAtInit)
    }

    func testProcessExitMidTurnYieldsProcessExited() async {
        let world = makeWorld()
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await untilPrompt(world)
        world.transports.items[0].simulateExit(uptime: 1)
        let events = await collecting.value
        XCTAssertEqual(events?.first, .status("started"))
        XCTAssertEqual(events?.last, .failed(.agentFailed("process_exited")))
    }

    func testHandshakeTimeoutKillsTheChild() async {
        let world = makeWorld(autoReply: false)
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await CoordTestSupport.settle(self, until: { world.scheduler.scheduledDelays.contains(20) })
        fire(world, delay: 20)
        let events = await collecting.value
        XCTAssertEqual(events, [.failed(.agentFailed("handshake_timeout"))])
        XCTAssertEqual(world.transports.items.last?.terminateCount, 1)
    }

    func testProtocolMismatchDuringHandshakeIsRefusedAndKills() async {
        let world = makeWorld(version: 2)
        let events = await collectBounded(world.backend.submit("hello"))
        XCTAssertEqual(events, [.failed(.preflightRefused(.protocolMismatch))])
        XCTAssertEqual(world.transports.items.last?.terminateCount, 1)
    }

    func testStopRightAfterSubmitNeverSendsPrompt() async {
        let world = makeWorld(gated: ["initialize"])
        let stream = world.backend.submit("hello")
        _ = await world.backend.emergencyStop()
        for transport in world.transports.items { transport.releaseGated("initialize") }
        let events = await collectBounded(stream)
        XCTAssertEqual(events?.last, .failed(.agentFailed("stop_cancelled")))
        XCTAssertFalse(world.transports.methods.contains("session/prompt"))
        XCTAssertTrue(world.transports.items.allSatisfy { $0.terminateCount >= 1 })
    }

    func testEmergencyStopDuringPreflightLeavesNothingRunning() async {
        let box = HermesBackendBox()
        let world = makeWorld(reader: HermesHookConfig(box: box, text: HermesFixtures.goldenConfig))
        box.backend = world.backend
        let events = await collectBounded(world.backend.submit("hello"))
        XCTAssertEqual(events, [.failed(.agentFailed("stop_cancelled"))])
        XCTAssertTrue(world.transports.items.isEmpty)
    }

    func testSessionIsReusedAndPreflightRunsOnEverySubmit() async {
        let world = makeWorld()
        let first = world.backend.submit("hello")
        let firstEvents = Task { await collectBounded(first) }
        await untilPrompt(world)
        world.transports.items[0].emit(line: stop(3, reason: "end_turn"))
        let finished = await firstEvents.value
        XCTAssertEqual(finished?.last, .finished(summary: ""))
        let reads = world.config.readCount
        let second = world.backend.submit("again")
        let secondEvents = Task { await collectBounded(second) }
        await untilPromptCount(world, 2)
        XCTAssertGreaterThan(world.config.readCount, reads)
        XCTAssertEqual(world.transports.items.count, 1)
        XCTAssertEqual(world.transports.methods.filter { $0 == "session/new" }.count, 1)
        XCTAssertEqual(world.transports.methods.filter { $0 == "session/prompt" }.count, 2)
        world.transports.items[0].emit(line: stop(4))
        _ = await secondEvents.value
    }

    func testIdleWindowShutsDownAndApprovalAutoDenies() async {
        let world = makeWorld()
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await untilPrompt(world)
        world.transports.items[0].emit(line: HermesFixtures.permissionRequest)
        await CoordTestSupport.settle(self, until: { world.scheduler.scheduledDelays.contains(60) })
        fire(world, delay: 60)
        await CoordTestSupport.settle(self, until: {
            world.transports.items[0].sentLines.contains { String(decoding: $0, as: UTF8.self).contains("\"optionId\":\"deny\"") }
        })
        world.transports.items[0].emit(line: stop(3))
        _ = await collecting.value
        await CoordTestSupport.settle(self, until: { world.scheduler.scheduledDelays.contains(600) })
        fire(world, delay: 600)
        XCTAssertGreaterThanOrEqual(world.transports.items[0].terminateCount, 1)
        let next = world.backend.submit("later")
        let again = Task { await collectBounded(next) }
        await untilTransport(world, index: 1)
        XCTAssertEqual(world.transports.items.count, 2)
        world.transports.items[1].emit(line: stop(3))
        _ = await again.value
    }

    private func assertStopped(
        at method: String,
        using action: (HermesAgentBackend) async -> Void
    ) async {
        let world = makeWorld(gated: [method])
        let stream = world.backend.submit("hello")
        let collecting = Task { await collectBounded(stream) }
        await until(world, method: method)
        await action(world.backend)
        for transport in world.transports.items { transport.releaseGated(method) }
        let events = await collecting.value
        XCTAssertEqual(events?.last, .failed(.agentFailed("stop_cancelled")))
        let methods = world.transports.items.last?.sentMethods() ?? []
        if method == "initialize" {
            XCTAssertEqual(methods, ["initialize"])
        } else {
            XCTAssertEqual(methods, ["initialize", "session/new"])
        }
        XCTAssertFalse(methods.contains("session/cancel"))
        XCTAssertGreaterThanOrEqual(world.transports.items.last?.terminateCount ?? 0, 1)
    }

    private func untilPrompt(_ world: World) async {
        await until(world, method: "session/prompt")
    }

    private func untilPromptCount(_ world: World, _ count: Int) async {
        await CoordTestSupport.settle(self, until: {
            world.transports.methods.filter { $0 == "session/prompt" }.count >= count
        })
    }

    private func untilTransport(_ world: World, index: Int) async {
        await CoordTestSupport.settle(self, until: {
            let items = world.transports.items
            return items.count > index && items[index].sentMethods().contains("session/prompt")
        })
    }

    private func until(_ world: World, method: String) async {
        await CoordTestSupport.settle(self, until: {
            world.transports.items.contains { $0.sentMethods().contains(method) }
        })
    }

    private func fire(_ world: World, delay: Double) {
        guard let index = world.scheduler.scheduledDelays.lastIndex(of: delay) else {
            return XCTFail("missing timer \(delay)")
        }
        world.scheduler.fire(index: index)
    }

    private func stop(_ id: Int, reason: String = "end_turn") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"\#(reason)"}}"#
    }

    private func tool(_ id: String, update: String, title: String) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"\#(update)","toolCallId":"\#(id)","title":"\#(title)"}}}"#
    }

    private func ensureDirectory() -> URL {
        if let directory { return directory }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "desnotch-hermes-b-\(UUID().uuidString)", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        return url
    }

    private func makeWorld(
        executable: Bool = true,
        reader: ConfigReading? = nil,
        gated: Set<String> = [],
        failStart: Bool = false,
        autoReply: Bool = true,
        version: Int = 1
    ) -> World {
        let root = ensureDirectory()
        let flag = HermesFlag(executable)
        let locator = HermesLocator(
            candidates: [URL(fileURLWithPath: "/test/hermes")],
            isExecutable: { _ in flag.value }
        )
        let config = HermesMemoryConfig(HermesFixtures.goldenConfig)
        let clock = HermesClock()
        let scheduler = HermesManualScheduler()
        let transports = TransportList()
        let recipe = Recipe()
        recipe.gated = gated
        recipe.failStart = failStart
        recipe.autoReply = autoReply
        recipe.version = version
        let kills = IntBox()
        let box = HermesBackendBox()
        let backend = HermesFixtures.makeBackend(
            locator: locator,
            configReader: reader ?? config,
            fileFlags: HermesMemoryFlags(UInt32(UF_IMMUTABLE)),
            launch: nil,
            pidFileDirectory: root,
            transportFactory: { launch, _ in
                let previous = transports.items.last
                let transport = HermesFakeTransport()
                if previous != nil { kills.set(previous?.terminateCount ?? 0) }
                transport.gatedMethods = recipe.gated
                transport.failStart = recipe.failStart
                transport.autoReply = recipe.autoReply
                transport.protocolVersion = recipe.version
                transport.onStart = { recipe.onStart?(transport) }
                transport.onSend = { data in recipe.onSend?(transport, data) }
                transports.add(transport, launch: launch)
                return transport
            },
            scheduler: scheduler,
            now: { clock.now() }
        )
        box.backend = backend
        backends.append(backend)
        return World(
            backend: backend, transports: transports, scheduler: scheduler, config: config,
            clock: clock, executable: flag, recipe: recipe, box: box, recordedKills: kills,
            epochAtInit: 0
        )
    }

    private final class World {
        let backend: HermesAgentBackend
        let transports: TransportList
        let scheduler: HermesManualScheduler
        let config: HermesMemoryConfig
        let clock: HermesClock
        let executable: HermesFlag
        let recipe: Recipe
        let box: HermesBackendBox
        let recordedKills: IntBox
        let epochAtInit: Int
        var backendEpoch: Int { epochAtInit }

        init(
            backend: HermesAgentBackend, transports: TransportList, scheduler: HermesManualScheduler,
            config: HermesMemoryConfig, clock: HermesClock, executable: HermesFlag, recipe: Recipe,
            box: HermesBackendBox, recordedKills: IntBox, epochAtInit: Int
        ) {
            self.backend = backend
            self.transports = transports
            self.scheduler = scheduler
            self.config = config
            self.clock = clock
            self.executable = executable
            self.recipe = recipe
            self.box = box
            self.recordedKills = recordedKills
            self.epochAtInit = epochAtInit
        }
    }

    private final class Recipe: @unchecked Sendable {
        var gated: Set<String> = []
        var failStart = false
        var autoReply = true
        var version = 1
        var onStart: (@Sendable (HermesFakeTransport) -> Void)?
        var onSend: (@Sendable (HermesFakeTransport, Data) -> Void)?
    }

    private final class TransportList: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HermesFakeTransport] = []
        private var seen: [ACPLaunch] = []

        func add(_ transport: HermesFakeTransport, launch: ACPLaunch) {
            lock.lock()
            stored.append(transport)
            seen.append(launch)
            lock.unlock()
        }

        var items: [HermesFakeTransport] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var launches: [ACPLaunch] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        var methods: [String] {
            items.flatMap { $0.sentMethods() }
        }
    }

    private final class IntBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = -1

        func set(_ value: Int) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class Bit: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false

        func setTrue() {
            lock.lock()
            stored = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
