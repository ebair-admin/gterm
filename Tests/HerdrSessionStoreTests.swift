import XCTest

/// Store tests run on the MainActor (the store is @MainActor) against the
/// shared MockHerdrTransport — no NIO, no network (spec §5.5/§5.6).
@MainActor
final class HerdrSessionStoreTests: XCTestCase {
    /// Three panes across two workspaces, deliberately unordered, to prove the
    /// stable sort (workspace, then display name): Alpha (w1:p1, blocked,
    /// focused) → Bravo (w1:p2, working) → zeta (w2:p1, idle).
    private let agentsFixture = #"[{"pane_id":"w2:p1","agent":"zeta","agent_status":"idle","workspace_id":"w2","tab_id":"w2:t1","focused":false},{"pane_id":"w1:p2","agent":"beta","name":"Bravo","agent_status":"working","workspace_id":"w1","tab_id":"w1:t2","focused":false},{"pane_id":"w1:p1","agent":"alpha","name":"Alpha","agent_status":"blocked","workspace_id":"w1","tab_id":"w1:t1","focused":true}]"#

    private func statusEvent(_ paneID: String, _ workspaceID: String, _ status: String, extra: String = "") -> String {
        #"{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"\#(paneID)","workspace_id":"\#(workspaceID)","agent_status":"\#(status)"\#(extra)}}"#
    }

    private func listCallCount(_ transport: MockHerdrTransport) -> Int {
        transport.sent.filter { MockHerdrTransport.method(of: $0.line) == "agent.list" }.count
    }

    private func pingCallCount(_ transport: MockHerdrTransport) -> Int {
        transport.sent.filter { MockHerdrTransport.method(of: $0.line) == "ping" }.count
    }

    /// A store wired to a mock that auto-answers the whole connect + resync
    /// flow; already past the gate and the first resync when returned.
    private func makeConnectedStore(proto: Int = 16) async throws -> (HerdrSessionStore, MockHerdrTransport) {
        let transport = MockHerdrTransport()
        transport.onSend = { [agentsFixture] line, _ in
            switch MockHerdrTransport.method(of: line) {
            case "ping":
                transport.respond(to: line, result: "{\"type\":\"pong\",\"version\":\"0.7.3\",\"protocol\":\(proto)}")
            case "agent.list":
                transport.respond(to: line, result: "{\"type\":\"agent_list\",\"agents\":\(agentsFixture)}")
            case "events.subscribe":
                transport.respond(to: line, result: #"{"type":"subscription_started"}"#)
            default:
                break
            }
        }
        let store = HerdrSessionStore(client: HerdrAPIClient(transport: transport))
        store.start()
        try await Task.sleep(for: .milliseconds(50))
        transport.emitState(.connected)
        try await Task.sleep(for: .milliseconds(200))
        return (store, transport)
    }

    func testStartConnectsSortsAndTracksBlocked() async throws {
        let (store, transport) = try await makeConnectedStore()
        XCTAssertEqual(store.phase, .connected)
        XCTAssertEqual(store.agents.map(\.displayName), ["Alpha", "Bravo", "zeta"])
        XCTAssertEqual(store.blockedAgent?.paneID, "w1:p1")
        XCTAssertEqual(transport.restartEventsCalls, 1)
        store.stop()
    }

    func testStatusDeltaMergesWithoutWipingListFields() async throws {
        let (store, transport) = try await makeConnectedStore()
        // The event carries status + title only (live schema: never focused,
        // terminal_id, tab_id, cwd) — the list values must survive the merge.
        transport.emitLine(statusEvent("w1:p2", "w1", "done", extra: #", "title":"New title""#))
        try await Task.sleep(for: .milliseconds(100))
        let bravo = try XCTUnwrap(store.agents.first { $0.paneID == "w1:p2" })
        XCTAssertEqual(bravo.status, .done)
        XCTAssertEqual(bravo.title, "New title")
        XCTAssertEqual(bravo.agent, "beta")   // not in the event → preserved
        XCTAssertEqual(bravo.name, "Bravo")   // not in the event → preserved
        XCTAssertEqual(store.blockedAgent?.paneID, "w1:p1")
        store.stop()
    }

    func testBlockedAgentFollowsStatusFlaps() async throws {
        let (store, transport) = try await makeConnectedStore()
        transport.emitLine(statusEvent("w1:p1", "w1", "idle"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.blockedAgent)
        transport.emitLine(statusEvent("w1:p2", "w1", "blocked"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.blockedAgent?.paneID, "w1:p2")
        store.stop()
    }

    func testPaneClosedRemovesAgent() async throws {
        let (store, transport) = try await makeConnectedStore()
        transport.emitLine(#"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w1:p1","workspace_id":"w1"}}"#)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.agents.map(\.paneID), ["w1:p2", "w2:p1"])
        XCTAssertNil(store.blockedAgent) // the closed pane was the blocked one
        store.stop()
    }

    func testPaneFocusedMovesFocusFlag() async throws {
        let (store, transport) = try await makeConnectedStore()
        XCTAssertEqual(store.agents.first { $0.focused }?.paneID, "w1:p1")
        transport.emitLine(#"{"event":"pane_focused","data":{"type":"pane_focused","pane_id":"w2:p1","workspace_id":"w2"}}"#)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.agents.filter { $0.focused }.map(\.paneID), ["w2:p1"])
        store.stop()
    }

    func testPaneCreatedTriggersResubscribeAndResync() async throws {
        let (store, transport) = try await makeConnectedStore()
        let listsBefore = listCallCount(transport)
        transport.emitLine(#"{"event":"pane_created","data":{"type":"pane_created","pane":{"pane_id":"w1:p9","workspace_id":"w1","tab_id":"w1:t9"}}}"#)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(transport.restartEventsCalls, 2) // fresh subscribe incl. new pane
        XCTAssertGreaterThan(listCallCount(transport), listsBefore)
        store.stop()
    }

    func testStatusDeltaForUnknownPaneResyncs() async throws {
        let (store, transport) = try await makeConnectedStore()
        let listsBefore = listCallCount(transport)
        transport.emitLine(statusEvent("w9:pZ", "w9", "working"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(listCallCount(transport), listsBefore)
        store.stop()
    }

    func testReconnectReGatesAndResyncs() async throws {
        let (store, transport) = try await makeConnectedStore()
        let listsBefore = listCallCount(transport)
        transport.emitState(.retrying)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.phase, .disconnected(retrying: true))
        transport.emitState(.connected)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.phase, .connected)
        XCTAssertEqual(pingCallCount(transport), 2) // gate re-ran after reconnect
        XCTAssertGreaterThan(listCallCount(transport), listsBefore)
        store.stop()
    }

    func testUnsupportedProtocolDisablesWithMessage() async throws {
        let (store, _) = try await makeConnectedStore(proto: 17)
        guard case .unsupported(let details) = store.phase else {
            return XCTFail("expected .unsupported, got \(store.phase)")
        }
        XCTAssertTrue(details.contains("17"))
        XCTAssertTrue(store.agents.isEmpty) // sidebar never renders unverified
        store.stop()
    }

    func testFocusSendsAgentFocusWithPaneTarget() async throws {
        let (store, transport) = try await makeConnectedStore()
        let alpha = try XCTUnwrap(store.agents.first { $0.paneID == "w1:p1" })
        store.focus(agent: alpha)
        try await Task.sleep(for: .milliseconds(100))
        let focusLine = transport.sent.first { MockHerdrTransport.method(of: $0.line) == "agent.focus" }?.line
        let line = try XCTUnwrap(focusLine)
        XCTAssertTrue(line.contains("\"target\":\"w1:p1\""))
        store.stop()
    }
}
