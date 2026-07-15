import Combine
import XCTest

/// Store tests run on the MainActor (the store is @MainActor) against the
/// shared MockHerdrTransport — no NIO, no network (spec §5.5/§5.6).
@MainActor
final class HerdrSessionStoreTests: XCTestCase {
    /// Three panes across two workspaces, deliberately unordered, to prove the
    /// stable sort (workspace, then display name): Alpha (w1:p1, blocked,
    /// focused) → Bravo (w1:p2, working) → zeta (w2:p1, idle).
    private let agentsFixture = #"[{"pane_id":"w2:p1","agent":"zeta","agent_status":"idle","workspace_id":"w2","tab_id":"w2:t1","focused":false},{"pane_id":"w1:p2","agent":"beta","name":"Bravo","agent_status":"working","workspace_id":"w1","tab_id":"w1:t2","focused":false},{"pane_id":"w1:p1","agent":"claude","name":"Alpha","agent_status":"blocked","workspace_id":"w1","tab_id":"w1:t1","focused":true}]"#

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
        // Idle must prove itself stable for ~1 s first (screen-scrape
        // hysteresis) — a 100 ms peek still shows the old state.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.blockedAgent?.paneID, "w1:p1")
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertNil(store.blockedAgent)
        transport.emitLine(statusEvent("w1:p2", "w1", "blocked"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.blockedAgent?.paneID, "w1:p2")
        store.stop()
    }

    func testIdleAppliesOnlyAfterStabilityWindow() async throws {
        let (store, transport) = try await makeConnectedStore()
        // w1:p2 starts `working`; a lone idle flicker must not stick.
        transport.emitLine(statusEvent("w1:p2", "w1", "idle"))
        try await Task.sleep(for: .milliseconds(150))
        transport.emitLine(statusEvent("w1:p2", "w1", "working"))
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(store.agents.first { $0.paneID == "w1:p2" }?.status, .working)
        // A stable idle does land — just ~1 s late.
        transport.emitLine(statusEvent("w1:p2", "w1", "idle"))
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(store.agents.first { $0.paneID == "w1:p2" }?.status, .idle)
        store.stop()
    }

    func testBlockedAppliesImmediatelyAndCancelsPendingIdle() async throws {
        let (store, transport) = try await makeConnectedStore()
        transport.emitLine(statusEvent("w1:p2", "w1", "idle"))
        try await Task.sleep(for: .milliseconds(200))
        transport.emitLine(statusEvent("w1:p2", "w1", "blocked"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.agents.first { $0.paneID == "w1:p2" }?.status, .blocked)
        // The superseded pending idle must never overwrite the blocked state.
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(store.agents.first { $0.paneID == "w1:p2" }?.status, .blocked)
        store.stop()
    }

    func testIdenticalStatusDeltaDoesNotRepublish() async throws {
        let (store, transport) = try await makeConnectedStore()
        var blockedPublishes = 0
        var agentsPublishes = 0
        let c1 = store.$blockedAgent.sink { _ in blockedPublishes += 1 }
        let c2 = store.$agents.sink { _ in agentsPublishes += 1 }
        // Combine sinks fire once immediately with the current value — that
        // baseline is 1 for each.
        XCTAssertEqual(blockedPublishes, 1)
        XCTAssertEqual(agentsPublishes, 1)
        // w1:p1 is already blocked: an identical repeat must be swallowed.
        // herdr re-emits status on every screen-detection pass (~2.5 Hz while
        // an agent animates); publishing each one fans a render storm out to
        // the sidebar and re-triggers the approval sheet (smoke-test finding).
        transport.emitLine(statusEvent("w1:p1", "w1", "blocked"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(blockedPublishes, 1)
        XCTAssertEqual(agentsPublishes, 1)
        _ = (c1, c2)
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

    // MARK: - Approval intents (§2.7 safety sequence)

    /// Rewires the mock to answer the approval-path methods. `getStatus` is
    /// what agent.get reports for w1:p1 (the flap tests set it non-blocked).
    private func approvalResponder(_ transport: MockHerdrTransport, getStatus: String = "blocked") {
        transport.onSend = { line, _ in
            switch MockHerdrTransport.method(of: line) {
            case "agent.get":
                transport.respond(to: line, result: """
                {"type":"agent_info","agent":{"pane_id":"w1:p1","agent":"claude","agent_status":"\(getStatus)","workspace_id":"w1","tab_id":"w1:t1","focused":true}}
                """)
            case "pane.send_keys":
                transport.respond(to: line, result: #"{"type":"ok"}"#)
            case "agent.read":
                transport.respond(to: line, result: #"{"type":"pane_read","read":{"text":"Allow Bash tool?","truncated":false}}"#)
            default:
                break
            }
        }
    }

    private func sendKeysLines(_ transport: MockHerdrTransport) -> [String] {
        transport.sent.filter { MockHerdrTransport.method(of: $0.line) == "pane.send_keys" }.map(\.line)
    }

    func testApproveReVerifiesThenSendsApproveKeys() async throws {
        let (store, transport) = try await makeConnectedStore()
        approvalResponder(transport)
        let alpha = try XCTUnwrap(store.agents.first { $0.paneID == "w1:p1" })

        let outcome = await store.approve(agent: alpha)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(store.approvalPending, "w1:p1")
        let keys = try XCTUnwrap(sendKeysLines(transport).first)
        XCTAssertTrue(keys.contains("\"pane_id\":\"w1:p1\""))
        XCTAssertTrue(keys.contains("\"Enter\"")) // claude keymap approve

        // The optimistic pending clears on the confirming status event.
        transport.emitLine(statusEvent("w1:p1", "w1", "working"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.approvalPending)
        store.stop()
    }

    func testDenySendsDenyKeys() async throws {
        let (store, transport) = try await makeConnectedStore()
        approvalResponder(transport)
        let alpha = try XCTUnwrap(store.agents.first { $0.paneID == "w1:p1" })
        let outcome = await store.deny(agent: alpha)
        XCTAssertEqual(outcome, .sent)
        let keys = try XCTUnwrap(sendKeysLines(transport).first)
        XCTAssertTrue(keys.contains("\"Escape\"")) // claude keymap deny
        store.stop()
    }

    /// The §2.7 flap case: the agent un-blocked between sheet-open and tap —
    /// the re-fetch must catch it and NOTHING may be sent.
    func testStatusFlapBetweenOpenAndTapPreventsBlindSend() async throws {
        let (store, transport) = try await makeConnectedStore()
        approvalResponder(transport, getStatus: "working") // no longer blocked
        let alpha = try XCTUnwrap(store.agents.first { $0.paneID == "w1:p1" })
        let outcome = await store.approve(agent: alpha)
        XCTAssertEqual(outcome, .stateChanged)
        XCTAssertTrue(sendKeysLines(transport).isEmpty)
        XCTAssertNil(store.approvalPending)
        store.stop()
    }

    /// Unknown agent → no keymap → no buttons, nothing sent (§3.1).
    func testUnknownAgentHasNoKeymapAndSendsNothing() async throws {
        let (store, transport) = try await makeConnectedStore()
        approvalResponder(transport)
        let beta = try XCTUnwrap(store.agents.first { $0.paneID == "w1:p2" }) // agent "beta"
        let outcome = await store.approve(agent: beta)
        XCTAssertEqual(outcome, .noKeymap)
        XCTAssertTrue(sendKeysLines(transport).isEmpty)
        store.stop()
    }

    func testReadPromptReturnsNestedPaneReadText() async throws {
        let (store, transport) = try await makeConnectedStore()
        approvalResponder(transport)
        let alpha = try XCTUnwrap(store.agents.first { $0.paneID == "w1:p1" })
        let text = await store.readPrompt(agent: alpha)
        XCTAssertEqual(text, "Allow Bash tool?") // from result.read.text, not top level
        store.stop()
    }
}
