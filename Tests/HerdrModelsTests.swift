import os
import XCTest

final class HerdrModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: AgentStatus

    func testAgentStatusKnownValues() throws {
        XCTAssertEqual(try decode(AgentStatus.self, "\"idle\""), .idle)
        XCTAssertEqual(try decode(AgentStatus.self, "\"working\""), .working)
        XCTAssertEqual(try decode(AgentStatus.self, "\"blocked\""), .blocked)
        XCTAssertEqual(try decode(AgentStatus.self, "\"done\""), .done)
        XCTAssertEqual(try decode(AgentStatus.self, "\"unknown\""), .unknown)
    }

    func testAgentStatusUnknownRawValueDecodesToUnknown() throws {
        // A status added by a newer herdr must degrade, not throw (spec §2).
        XCTAssertEqual(try decode(AgentStatus.self, "\"waiting_for_user\""), .unknown)
        XCTAssertEqual(try decode(AgentStatus.self, "\"anything-else\""), .unknown)
    }

    // MARK: AgentInfo

    func testAgentInfoFullFixture() throws {
        // Shape captured from live agent.list on herdr v0.7.3.
        let json = #"{"terminal_id":"term_6565d2a40753310","agent":"hermes","agent_status":"idle","workspace_id":"w5","tab_id":"w5:t7","pane_id":"w5:p8","focused":false,"cwd":"/home/ubuntu","foreground_cwd":"/home/ubuntu","revision":0}"#
        let a = try decode(AgentInfo.self, json)
        XCTAssertEqual(a.terminalID, "term_6565d2a40753310")
        XCTAssertEqual(a.agent, "hermes")
        XCTAssertEqual(a.status, .idle)
        XCTAssertEqual(a.workspaceID, "w5")
        XCTAssertEqual(a.tabID, "w5:t7")
        XCTAssertEqual(a.paneID, "w5:p8")
        XCTAssertFalse(a.focused)
        XCTAssertEqual(a.cwd, "/home/ubuntu")
        XCTAssertEqual(a.displayName, "hermes")
    }

    func testAgentInfoLenientOnEmptyObject() throws {
        // Missing everything → defaults, never a throw (spec §2).
        let a = try decode(AgentInfo.self, "{}")
        XCTAssertEqual(a.paneID, "")
        XCTAssertEqual(a.status, .unknown)
        XCTAssertNil(a.agent)
        XCTAssertFalse(a.focused)
    }

    func testAgentInfoIgnoresUnknownFields() throws {
        let a = try decode(AgentInfo.self, #"{"pane_id":"w5:p1","agent_status":"blocked","brand_new_field":{"nested":[1,2,3]}}"#)
        XCTAssertEqual(a.paneID, "w5:p1")
        XCTAssertEqual(a.status, .blocked)
    }

    func testAgentInfoDisplayNameFallbackOrder() {
        func info(name: String?, agent: String?, title: String?) -> AgentInfo {
            AgentInfo(terminalID: "", name: name, agent: agent, title: title,
                      status: .idle, workspaceID: "", tabID: "", paneID: "w5:p9",
                      focused: false, cwd: nil)
        }
        // spec Phase 2.2: name ?? agent ?? title, then pane id.
        XCTAssertEqual(info(name: "n", agent: "a", title: "t").displayName, "n")
        XCTAssertEqual(info(name: nil, agent: "a", title: "t").displayName, "a")
        XCTAssertEqual(info(name: nil, agent: nil, title: "t").displayName, "t")
        XCTAssertEqual(info(name: nil, agent: nil, title: nil).displayName, "w5:p9")
    }

    // MARK: HerdrPong

    func testPongFixture() throws {
        let pong = try decode(HerdrPong.self, #"{"type":"pong","version":"0.7.3","protocol":16,"capabilities":{"live_handoff":true}}"#)
        XCTAssertEqual(pong.version, "0.7.3")
        XCTAssertEqual(pong.proto, 16)
        XCTAssertEqual(pong.capabilities["live_handoff"], true)
        XCTAssertTrue(HerdrProtocol.isSupported(pong.proto))
    }

    func testPongMissingProtocolFailsGate() throws {
        let pong = try decode(HerdrPong.self, #"{"type":"pong"}"#)
        XCTAssertEqual(pong.proto, -1)
        XCTAssertFalse(HerdrProtocol.isSupported(pong.proto))
    }

    func testProtocolPinIsExactly16() {
        XCTAssertTrue(HerdrProtocol.isSupported(16))
        XCTAssertFalse(HerdrProtocol.isSupported(15))
        XCTAssertFalse(HerdrProtocol.isSupported(17))
    }

    // MARK: Envelopes

    func testSuccessEnvelopeWithAgentList() throws {
        let json = #"{"id":"abc","result":{"type":"agent_list","agents":[{"pane_id":"w5:p1","agent":"kimi","agent_status":"working"}]}}"#
        let env = try decode(HerdrSuccessEnvelope<AgentListResult>.self, json)
        XCTAssertEqual(env.id, "abc")
        XCTAssertEqual(env.result.agents.count, 1)
        XCTAssertEqual(env.result.agents[0].status, .working)
    }

    func testErrorEnvelope() throws {
        let env = try decode(HerdrErrorEnvelope.self, #"{"id":"x1","error":{"code":"invalid_request","message":"missing field `pane_id`"}}"#)
        XCTAssertEqual(env.id, "x1")
        XCTAssertEqual(env.error.code, "invalid_request")
        XCTAssertTrue(env.error.message.contains("pane_id"))
    }

    func testAgentListResultEmptyWhenMissing() throws {
        let r = try decode(AgentListResult.self, #"{"type":"agent_list"}"#)
        XCTAssertTrue(r.agents.isEmpty)
    }

    // MARK: Events

    func testEventAgentStatusChanged() throws {
        // Shape from the live schema's PaneAgentStatusChangedEvent.
        let json = #"{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"w5:pB","workspace_id":"w5","agent":"kimi","agent_status":"blocked","title":null}}"#
        guard case .agentStatusChanged(let info) = try decode(HerdrEventEnvelope.self, json).event else {
            return XCTFail("expected agentStatusChanged")
        }
        XCTAssertEqual(info.paneID, "w5:pB")
        XCTAssertEqual(info.status, .blocked)
        XCTAssertEqual(info.agent, "kimi")
    }

    func testEventPaneCreatedNested() throws {
        let json = #"{"event":"pane_created","data":{"type":"pane_created","pane":{"pane_id":"w5:pC","workspace_id":"w5","tab_id":"w5:tB"}}}"#
        XCTAssertEqual(try decode(HerdrEventEnvelope.self, json).event,
                       .paneCreated(paneID: "w5:pC", workspaceID: "w5"))
    }

    func testEventPaneClosed() throws {
        let json = #"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w5:pC","workspace_id":"w5"}}"#
        XCTAssertEqual(try decode(HerdrEventEnvelope.self, json).event,
                       .paneClosed(paneID: "w5:pC", workspaceID: "w5"))
    }

    func testEventWorkspaceLifecycle() throws {
        let json = #"{"event":"workspace.renamed","data":{"type":"workspace_renamed","workspace_id":"w5","label":"ops"}}"#
        XCTAssertEqual(try decode(HerdrEventEnvelope.self, json).event,
                       .workspaceChanged(kind: "workspace.renamed"))
    }

    func testEventUnknownKindDegrades() throws {
        let json = #"{"event":"pane_brand_new","data":{"type":"pane_brand_new","x":1}}"#
        XCTAssertEqual(try decode(HerdrEventEnvelope.self, json).event,
                       .unknown(type: "pane_brand_new"))
    }

    func testEventKnownKindBadDataDegradesNotThrows() throws {
        // pane_agent_status_changed without a pane_id → .unknown, not a throw.
        let json = #"{"event":"pane_agent_status_changed","data":{"agent_status":"blocked"}}"#
        XCTAssertEqual(try decode(HerdrEventEnvelope.self, json).event,
                       .unknown(type: "pane_agent_status_changed"))
    }

    // MARK: Classifier

    private let log = Logger(subsystem: "io.github.madeye.gterm", category: "HerdrTests")

    func testClassifierResponse() {
        let line = Data(#"{"id":"r1","result":{"type":"pong"}}"#.utf8)
        guard case .response(let id, _) = HerdrInboundClassifier.classify(line: line, log: log) else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(id, "r1")
    }

    func testClassifierEventWithoutId() {
        let line = Data(#"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w5:p1","workspace_id":"w5"}}"#.utf8)
        guard case .event(let event) = HerdrInboundClassifier.classify(line: line, log: log) else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(event, .paneClosed(paneID: "w5:p1", workspaceID: "w5"))
    }

    func testClassifierGarbageLines() {
        for raw in ["not json at all", "{}", "[1,2,3]", "\"plain string\"", "{\"foo\":\"bar\"}"] {
            guard case .garbage = HerdrInboundClassifier.classify(line: Data(raw.utf8), log: log) else {
                return XCTFail("expected garbage for: \(raw)")
            }
        }
    }

    // MARK: Outbound encoding

    func testRequestEnvelopeEncoding() throws {
        let req = HerdrRequest(method: "agent.focus", params: AgentTargetParams(target: "w5:pB"))
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any]
        XCTAssertEqual(obj?["method"] as? String, "agent.focus")
        XCTAssertNotNil(obj?["id"] as? String)
        XCTAssertEqual((obj?["params"] as? [String: Any])?["target"] as? String, "w5:pB")
    }

    func testAgentReadParamsSnakeCase() throws {
        let params = AgentReadParams(target: "w5:pB", source: "recent", lines: 20, format: "text", stripANSI: true)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any]
        XCTAssertEqual(obj?["strip_ansi"] as? Bool, true)
        XCTAssertEqual(obj?["lines"] as? Int, 20)
    }

    func testSubscriptionStandardSetIncludesPerPaneStatus() throws {
        let subs = HerdrSubscription.standardSet(agentPaneIDs: ["w5:p1", "w5:p2"])
        let data = try JSONEncoder().encode(EventsSubscribeParams(subscriptions: subs))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = obj?["subscriptions"] as? [[String: Any]]
        let statusSubs = array?.filter { $0["type"] as? String == "pane.agent_status_changed" }
        XCTAssertEqual(statusSubs?.count, 2)
        XCTAssertEqual(statusSubs?.first?["pane_id"] as? String, "w5:p1")
        // Global lifecycle entries carry no pane_id.
        let lifecycle = array?.filter { $0["type"] as? String == "pane.created" }
        XCTAssertEqual(lifecycle?.count, 1)
        XCTAssertNil(lifecycle?.first?["pane_id"])
    }
}
