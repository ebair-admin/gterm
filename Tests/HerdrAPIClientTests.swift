import XCTest

/// In-memory HerdrTransport (spec §5.5: no NIO in tests). Records outbound
/// lines and lets each test script the wire: `onSend` auto-responders,
/// `emitLine` for server pushes, `emitState` for bridge lifecycle.
final class MockHerdrTransport: HerdrTransport, @unchecked Sendable {
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<HerdrTransportState>.Continuation
    private let inboundStream: AsyncStream<Data>
    private let stateStream: AsyncStream<HerdrTransportState>

    private(set) var sent: [(line: String, pipe: HerdrPipe)] = []
    private(set) var connectCalls = 0
    private(set) var restartEventsCalls = 0
    private(set) var disconnectCalls = 0

    /// Test hook: called on the send path; use `emitLine` inside to respond.
    var onSend: ((String, HerdrPipe) -> Void)?

    init() {
        (inboundStream, inboundContinuation) = AsyncStream.makeStream()
        (stateStream, stateContinuation) = AsyncStream.makeStream()
    }

    func connect() async throws { connectCalls += 1 }

    func send(_ data: Data, to pipe: HerdrPipe) async throws {
        let line = String(decoding: data, as: UTF8.self)
        sent.append((line, pipe))
        onSend?(line, pipe)
    }

    func restartEvents() async throws { restartEventsCalls += 1 }
    func disconnect() async { disconnectCalls += 1 }

    var inbound: AsyncStream<Data> { inboundStream }
    var stateChanges: AsyncStream<HerdrTransportState> { stateStream }

    // MARK: scripting helpers

    func emitLine(_ line: String) { inboundContinuation.yield(Data(line.utf8)) }
    func emitState(_ state: HerdrTransportState) { stateContinuation.yield(state) }

    /// Respond to a request line, keyed off its JSON id.
    func respond(to requestLine: String, result: String) {
        let id = Self.requestID(of: requestLine) ?? ""
        emitLine("{\"id\":\"\(id)\",\"result\":\(result)}")
    }

    static func requestID(of line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["id"] as? String
    }

    static func method(of line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["method"] as? String
    }
}

final class HerdrAPIClientTests: XCTestCase {
    private let agentsFixture = #"[{"pane_id":"w5:p1","agent":"kimi","agent_status":"idle","workspace_id":"w5","tab_id":"w5:t1","focused":true},{"pane_id":"w5:p2","agent":"hermes","agent_status":"working","workspace_id":"w5","tab_id":"w5:t2","focused":false}]"#

    // MARK: request/response correlation

    func testRequestResponseCorrelation() async throws {
        let transport = MockHerdrTransport()
        transport.onSend = { line, _ in transport.respond(to: line, result: #"{"type":"pong","version":"0.7.3","protocol":16}"#) }
        let client = HerdrAPIClient(transport: transport)

        let pong: HerdrPong = try await client.request("ping", params: EmptyParams())
        XCTAssertEqual(pong.proto, 16)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].pipe, .requests)
    }

    func testOutOfOrderResponsesResolveCorrectly() async throws {
        let transport = MockHerdrTransport()
        let client = HerdrAPIClient(transport: transport)
        // No auto-responder: capture ids, answer in reverse order.
        async let first: HerdrPong = client.request("ping", params: EmptyParams())
        async let second: AgentListResult = client.request("agent.list", params: EmptyParams())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.sent.count, 2)
        transport.respond(to: transport.sent[1].line, result: #"{"type":"agent_list","agents":[]}"#)
        transport.respond(to: transport.sent[0].line, result: #"{"type":"pong","protocol":16}"#)
        let (pong, list) = try await (first, second)
        XCTAssertEqual(pong.proto, 16)
        XCTAssertTrue(list.agents.isEmpty)
    }

    func testErrorEnvelopeMapsToRemoteError() async {
        let transport = MockHerdrTransport()
        transport.onSend = { line, _ in
            let id = MockHerdrTransport.requestID(of: line) ?? ""
            transport.emitLine("{\"id\":\"\(id)\",\"error\":{\"code\":\"invalid_request\",\"message\":\"missing field `pane_id`\"}}")
        }
        let client = HerdrAPIClient(transport: transport)
        do {
            let _: HerdrAckResult = try await client.request("events.subscribe", params: EmptyParams())
            XCTFail("expected remote error")
        } catch let HerdrError.remote(code, message) {
            XCTAssertEqual(code, "invalid_request")
            XCTAssertTrue(message.contains("pane_id"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTimeoutCancelsContinuation() async {
        let transport = MockHerdrTransport() // never responds
        let client = HerdrAPIClient(transport: transport)
        do {
            let _: HerdrPong = try await client.request("ping", params: EmptyParams(), timeout: .milliseconds(100))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? HerdrError, .timeout)
        }
    }

    func testBridgeDropFailsInFlight() async throws {
        let transport = MockHerdrTransport()
        let client = HerdrAPIClient(transport: transport)
        async let pending: HerdrPong = client.request("ping", params: EmptyParams())
        try await Task.sleep(for: .milliseconds(50))
        transport.emitState(.retrying)
        do {
            _ = try await pending
            XCTFail("expected disconnected")
        } catch {
            XCTAssertEqual(error as? HerdrError, .disconnected)
        }
    }

    // MARK: events

    func testInterleavedEventsAreRoutedToStream() async throws {
        let transport = MockHerdrTransport()
        transport.onSend = { line, _ in
            transport.emitLine(#"{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"w5:p1","workspace_id":"w5","agent_status":"blocked"}}"#)
            transport.respond(to: line, result: #"{"type":"pong","protocol":16}"#)
        }
        let client = HerdrAPIClient(transport: transport)
        var iterator = client.events.makeAsyncIterator()
        let _: HerdrPong = try await client.request("ping", params: EmptyParams())
        let event = await iterator.next()
        guard case .agentStatusChanged(let info) = event else {
            return XCTFail("expected agentStatusChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(info.status, .blocked)
        XCTAssertEqual(info.paneID, "w5:p1")
    }

    func testGarbageLinesDoNotKillTheStream() async throws {
        let transport = MockHerdrTransport()
        transport.onSend = { line, _ in transport.respond(to: line, result: #"{"type":"pong","protocol":16}"#) }
        let client = HerdrAPIClient(transport: transport)
        // A round trip first so the reader task is running (it starts on first
        // request/connect), then garbage must not take the stream down.
        let _: HerdrPong = try await client.request("ping", params: EmptyParams())
        transport.emitLine("this is not json")
        transport.emitLine(#"{"no_id_no_event":true}"#)
        transport.emitLine(#"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w5:p9","workspace_id":"w5"}}"#)
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event, .paneClosed(paneID: "w5:p9", workspaceID: "w5"))
    }

    // MARK: connect + version gate

    private func autoGate(_ transport: MockHerdrTransport, proto: Int = 16) {
        transport.onSend = { line, _ in
            if MockHerdrTransport.method(of: line) == "ping" {
                transport.respond(to: line, result: "{\"type\":\"pong\",\"version\":\"0.7.3\",\"protocol\":\(proto)}")
            }
        }
    }

    func testConnectGatesProtocol() async throws {
        let transport = MockHerdrTransport()
        autoGate(transport)
        let client = HerdrAPIClient(transport: transport)
        async let connecting = client.connect()
        try await Task.sleep(for: .milliseconds(50))
        transport.emitState(.connected)
        let pong = try await connecting
        XCTAssertEqual(pong.proto, 16)
        XCTAssertEqual(transport.connectCalls, 1)
        // ping must have been the FIRST request (spec §2).
        XCTAssertEqual(MockHerdrTransport.method(of: transport.sent[0].line), "ping")
    }

    func testConnectUnsupportedProtocol() async throws {
        let transport = MockHerdrTransport()
        autoGate(transport, proto: 17)
        let client = HerdrAPIClient(transport: transport)
        async let connecting = client.connect()
        try await Task.sleep(for: .milliseconds(50))
        transport.emitState(.connected)
        do {
            _ = try await connecting
            XCTFail("expected unsupportedProtocol")
        } catch {
            XCTAssertEqual(error as? HerdrError, .unsupportedProtocol(found: 17))
        }
    }

    // MARK: subscribeAndResync

    func testSubscribeAndResyncOrdersAndRoutes() async throws {
        let transport = MockHerdrTransport()
        transport.onSend = { line, pipe in
            switch MockHerdrTransport.method(of: line) {
            case "agent.list":
                transport.respond(to: line, result: "{\"type\":\"agent_list\",\"agents\":\(self.agentsFixture)}")
            case "events.subscribe":
                XCTAssertEqual(pipe, .events) // subscribe rides the events pipe
                transport.respond(to: line, result: #"{"type":"subscription_started"}"#)
            default:
                break
            }
        }
        let client = HerdrAPIClient(transport: transport)
        let agents = try await client.subscribeAndResync()

        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(agents[0].paneID, "w5:p1")
        XCTAssertEqual(transport.restartEventsCalls, 1)

        // Order: list → subscribe → list (atomically ordered, spec §5.5).
        let methods = transport.sent.map { MockHerdrTransport.method(of: $0.line) }
        XCTAssertEqual(methods, ["agent.list", "events.subscribe", "agent.list"])

        // The subscription set must include a per-pane status sub for each pane.
        let subscribeLine = transport.sent[1].line
        XCTAssertTrue(subscribeLine.contains("\"pane.agent_status_changed\""))
        XCTAssertTrue(subscribeLine.contains("\"pane_id\":\"w5:p1\""))
        XCTAssertTrue(subscribeLine.contains("\"pane_id\":\"w5:p2\""))
    }

    // MARK: reconnect → re-gate → resubscribe

    func testReconnectReGatesBeforeResubscribe() async throws {
        let transport = MockHerdrTransport()
        var pingCount = 0
        transport.onSend = { line, pipe in
            switch MockHerdrTransport.method(of: line) {
            case "ping":
                pingCount += 1
                transport.respond(to: line, result: #"{"type":"pong","protocol":16}"#)
            case "agent.list":
                transport.respond(to: line, result: "{\"type\":\"agent_list\",\"agents\":\(self.agentsFixture)}")
            case "events.subscribe":
                transport.respond(to: line, result: #"{"type":"subscription_started"}"#)
            default:
                break
            }
        }
        let client = HerdrAPIClient(transport: transport)
        var states = client.states.makeAsyncIterator()

        async let connecting = client.connect()
        try await Task.sleep(for: .milliseconds(50))
        transport.emitState(.connected)
        _ = try await connecting
        XCTAssertEqual(pingCount, 1)

        // Initial resync, then a bridge drop + reopen.
        _ = try await client.subscribeAndResync()
        transport.emitState(.retrying)
        transport.emitState(.connected)
        try await Task.sleep(for: .milliseconds(100))

        // The reconnect must have triggered a SECOND gate ping before anything
        // else could be trusted (spec §3: ping gate after every reconnect).
        XCTAssertEqual(pingCount, 2)
        guard pingCount == 2 else { return } // don't await states that never come

        // And the state stream surfaced the full cycle: connecting → connected
        // → retrying → connected (buffered, so draining cannot hang).
        var sequence: [String] = []
        while sequence.count < 4, let state = await states.next() {
            switch state {
            case .connecting: sequence.append("connecting")
            case .connected: sequence.append("connected")
            case .retrying: sequence.append("retrying")
            case .disconnected: sequence.append("disconnected")
            case .unsupported: sequence.append("unsupported")
            }
        }
        XCTAssertEqual(sequence, ["connecting", "connected", "retrying", "connected"])

        // A resubscribe after the reconnect works on the reopened pipes.
        _ = try await client.subscribeAndResync()
        XCTAssertEqual(transport.restartEventsCalls, 2)
    }
}
