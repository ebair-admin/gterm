import Foundation
import os

/// Hand-written Swift models for herdr's JSON socket API (NDJSON, protocol 16).
///
/// CLEAN-ROOM: gterm is MIT, herdr is AGPL. These models are written against the
/// *published JSON schema* (`herdr api schema --json`, kept in the workspace
/// scratch folder, never committed). No herdr source code is copied, ported, or
/// transformed into this file.
///
/// LENIENT DECODING (spec §2): unknown enum values degrade to `.unknown`, unknown
/// fields are ignored, missing fields fall back to defaults. A protocol bump must
/// degrade the feature, never crash it.
///
/// WIRE FACTS verified against herdr v0.7.3 (see docs/ground-truth.md):
///   * success:  {"id": "...", "result": {...}}
///   * error:    {"id": "...", "error": {"code": "...", "message": "..."}}
///   * event:    {"event": "<kind>", "data": {...}}   (no request id)

// MARK: - Protocol gate

/// herdr protocol versions this build can talk to. Pinned to exactly 16: the API
/// is pre-stabilization (docs/next), so a version bump must disable the feature
/// with an actionable message rather than wander into changed semantics.
enum HerdrProtocol {
    static let supportedRange = 16...16

    static func isSupported(_ proto: Int) -> Bool {
        supportedRange.contains(proto)
    }
}

// MARK: - Errors

/// Typed errors surfaced by the bridge/client. `remote` carries herdr's own
/// error envelope; the rest are local conditions the UI can phrase remediations
/// around (spec Phase 4.2 distinguishes them).
enum HerdrError: Error, Equatable {
    case timeout
    case disconnected
    case remote(code: String, message: String)
    case unsupportedProtocol(found: Int)
    /// A line that looked like a response but failed to decode as the expected
    /// result type — e.g. a protocol drift the lenient decoder couldn't absorb.
    case badResponse(String)
    /// The bridge channel itself failed (exec channel, missing tool, socket
    /// absent). The associated string is a short machine-readable reason.
    case bridgeUnavailable(String)
}

// MARK: - Type erasure for outbound params

/// Type-erased Encodable so one request envelope can carry any per-method params.
struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init<T: Encodable>(_ wrapped: T) {
        encodeClosure = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

// MARK: - Outbound request envelope + params

/// Request envelope: {"id": "<uuid>", "method": "<name>", "params": {...}}
struct HerdrRequest: Encodable {
    let id: String
    let method: String
    let params: AnyEncodable

    init<P: Encodable>(method: String, params: P) {
        self.id = UUID().uuidString
        self.method = method
        self.params = AnyEncodable(params)
    }
}

struct EmptyParams: Encodable {}

struct AgentTargetParams: Encodable {
    let target: String
}

/// agent.read params. `stripANSI` defaults to true on the server; we send it
/// explicitly because pane content is shown verbatim in the approval sheet and
/// must never carry escape sequences into SwiftUI.
struct AgentReadParams: Encodable {
    let target: String
    let source: String
    let lines: Int?
    let format: String?
    let stripANSI: Bool

    enum CodingKeys: String, CodingKey {
        case target, source, lines, format
        case stripANSI = "strip_ansi"
    }

    init(target: String, source: String = "recent", lines: Int? = 20, format: String? = "text", stripANSI: Bool = true) {
        self.target = target
        self.source = source
        self.lines = lines
        self.format = format
        self.stripANSI = stripANSI
    }
}

struct AgentSendParams: Encodable {
    let target: String
    let text: String
}

struct PaneSendKeysParams: Encodable {
    let paneID: String
    let keys: [String]

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case keys
    }
}

struct PaneSendTextParams: Encodable {
    let paneID: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case text
    }
}

/// One entry of an events.subscribe request. `type` is the dotted subscription
/// name ("pane.agent_status_changed"); lifecycle subscriptions are global, but
/// pane.agent_status_changed is PER-PANE and requires `paneID` (verified against
/// the live schema — a missing pane_id is an invalid_request, and "*" is rejected).
struct HerdrSubscription: Encodable {
    let type: String
    let paneID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
    }

    static func global(_ type: String) -> HerdrSubscription {
        HerdrSubscription(type: type, paneID: nil)
    }

    static func paneAgentStatusChanged(paneID: String) -> HerdrSubscription {
        HerdrSubscription(type: "pane.agent_status_changed", paneID: paneID)
    }

    /// Global lifecycle set plus a per-pane agent-status subscription for every
    /// known pane. Rebuilt from the full agent list on every resync; new panes
    /// learned via pane.created are subscribed individually by the caller.
    static func standardSet(agentPaneIDs: [String]) -> [HerdrSubscription] {
        var subs: [HerdrSubscription] = [
            .global("pane.created"),
            .global("pane.closed"),
            .global("pane.focused"),
            .global("workspace.created"),
            .global("workspace.updated"),
            .global("workspace.renamed"),
            .global("workspace.closed"),
            .global("tab.created"),
            .global("tab.closed"),
            .global("tab.renamed"),
        ]
        subs.append(contentsOf: agentPaneIDs.map { .paneAgentStatusChanged(paneID: $0) })
        return subs
    }
}

struct EventsSubscribeParams: Encodable {
    let subscriptions: [HerdrSubscription]
}

// MARK: - Inbound envelopes

/// Success envelope; the result payload is decoded per request method.
struct HerdrSuccessEnvelope<R: Decodable>: Decodable {
    let id: String
    let result: R
}

struct HerdrErrorBody: Decodable, Equatable {
    let code: String
    let message: String
}

struct HerdrErrorEnvelope: Decodable {
    let id: String
    let error: HerdrErrorBody
}

// MARK: - ping / version gate

/// ping result. `protocol` is the gate; everything else is informational.
/// Decoding is deliberately defensive: a missing/renamed field yields defaults
/// that fail the version gate (feature disables) instead of crashing.
struct HerdrPong: Decodable, Equatable {
    let version: String?
    let proto: Int
    /// Capabilities are opaque to the app — kept for logging/diagnostics only.
    let capabilities: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case version
        case proto = "protocol"
        case capabilities
    }

    init(version: String?, proto: Int, capabilities: [String: Bool]) {
        self.version = version
        self.proto = proto
        self.capabilities = capabilities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decode(String.self, forKey: .version)
        // An absent or non-int protocol number decodes as -1 → fails the gate.
        proto = (try? c.decode(Int.self, forKey: .proto)) ?? -1
        capabilities = (try? c.decode([String: Bool].self, forKey: .capabilities)) ?? [:]
    }
}

// MARK: - AgentStatus

/// Per-agent state detected by herdr's (regex, screen-scraped) rules.
/// Unknown raw values — e.g. a status added by a newer herdr — decode to
/// `.unknown`, never throw (spec §2).
enum AgentStatus: String, Codable, Sendable {
    case idle
    case working
    case blocked
    case done
    case unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - AgentInfo

/// One pane's agent record, as returned by agent.list/agent.get and carried
/// (partially) by pane_agent_status_changed events.
///
/// KEYING: `paneID` is the stable identifier — `terminal_id` CHURNS across
/// herdr restarts/live-handoffs (verified on 0.7.3). The event variant of this
/// payload omits terminal_id/tab_id/focused/cwd entirely, so every field
/// decodes leniently and the store merges deltas by paneID.
struct AgentInfo: Decodable, Equatable, Sendable {
    let terminalID: String
    let name: String?
    let agent: String?
    let title: String?
    let status: AgentStatus
    let workspaceID: String
    let tabID: String
    let paneID: String
    let focused: Bool
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case name, agent, title
        case status = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused, cwd
    }

    init(
        terminalID: String, name: String?, agent: String?, title: String?,
        status: AgentStatus, workspaceID: String, tabID: String, paneID: String,
        focused: Bool, cwd: String?
    ) {
        self.terminalID = terminalID
        self.name = name
        self.agent = agent
        self.title = title
        self.status = status
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.focused = focused
        self.cwd = cwd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalID = (try? c.decode(String.self, forKey: .terminalID)) ?? ""
        name = try? c.decode(String.self, forKey: .name)
        agent = try? c.decode(String.self, forKey: .agent)
        title = try? c.decode(String.self, forKey: .title)
        status = (try? c.decode(AgentStatus.self, forKey: .status)) ?? .unknown
        workspaceID = (try? c.decode(String.self, forKey: .workspaceID)) ?? ""
        tabID = (try? c.decode(String.self, forKey: .tabID)) ?? ""
        paneID = (try? c.decode(String.self, forKey: .paneID)) ?? ""
        focused = (try? c.decode(Bool.self, forKey: .focused)) ?? false
        cwd = try? c.decode(String.self, forKey: .cwd)
    }

    /// Row label per spec §4 Phase 2.2: name ?? agent ?? title, then pane id.
    var displayName: String {
        name ?? agent ?? title ?? paneID
    }
}

// MARK: - Per-method result payloads

struct AgentListResult: Decodable {
    let agents: [AgentInfo]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = (try? c.decode([AgentInfo].self, forKey: .agents)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case agents
    }
}

struct AgentGetResult: Decodable {
    let agent: AgentInfo?
}

/// agent.read result. Only `text` is used by the UI (approval sheet body);
/// the rest is metadata we may log — never the text itself (secrets, spec §2).
struct PaneReadResult: Decodable {
    let text: String
    let truncated: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case text, truncated
    }
}

/// Ack-shaped results (focus/send/send_keys/subscribe). We intentionally do not
/// model their payloads: an ack that decodes is enough, and ignoring the body
/// keeps us forward-compatible with added fields.
struct HerdrAckResult: Decodable {}

// MARK: - Events

/// Server-pushed events. Envelope: {"event": "<kind>", "data": {...}}.
/// Unknown kinds degrade to `.unknown(type:)` so a protocol bump keeps the
/// stream alive (spec §2).
enum HerdrEvent: Equatable, Sendable {
    /// pane_agent_status_changed — data is a PARTIAL AgentInfo keyed by paneID.
    case agentStatusChanged(AgentInfo)
    case paneCreated(paneID: String, workspaceID: String)
    case paneClosed(paneID: String, workspaceID: String)
    case paneFocused(paneID: String, workspaceID: String)
    /// workspace.* and tab.* lifecycle kinds we don't model individually.
    case workspaceChanged(kind: String)
    case tabChanged(kind: String)
    case unknown(type: String)
}

/// Minimal shape shared by the pane_created data's nested `pane` object and the
/// flat pane_closed/pane_focused payloads.
private struct PaneRef: Decodable {
    let paneID: String?
    let workspaceID: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
    }
}

/// pane_created's data nests the pane object next to a `type` string, so it
/// can't be decoded as a flat [String: PaneRef] map (live schema protocol 16:
/// EventData oneOf — data = { "type": "pane_created", "pane": PaneInfo }).
private struct PaneCreatedData: Decodable {
    let pane: PaneRef?
}

/// Decodes one event envelope. Two-stage: read `event` (the kind), then decode
/// `data` per kind. A kind we know whose data fails to decode degrades to
/// `.unknown(type:)` — the stream must survive a drifting payload shape.
struct HerdrEventEnvelope: Decodable {
    let event: HerdrEvent

    private enum CodingKeys: String, CodingKey {
        case event, data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .event)) ?? ""
        switch kind {
        case "pane_agent_status_changed":
            if let info = try? c.decode(AgentInfo.self, forKey: .data), !info.paneID.isEmpty {
                event = .agentStatusChanged(info)
            } else {
                event = .unknown(type: kind)
            }
        case "pane_created":
            // data nests the pane object: {"type": ..., "pane": {...}}
            if let payload = try? c.decode(PaneCreatedData.self, forKey: .data),
               let ref = payload.pane, let paneID = ref.paneID {
                event = .paneCreated(paneID: paneID, workspaceID: ref.workspaceID ?? "")
            } else {
                event = .unknown(type: kind)
            }
        case "pane_closed":
            if let ref = try? c.decode(PaneRef.self, forKey: .data), let paneID = ref.paneID {
                event = .paneClosed(paneID: paneID, workspaceID: ref.workspaceID ?? "")
            } else {
                event = .unknown(type: kind)
            }
        case "pane_focused":
            if let ref = try? c.decode(PaneRef.self, forKey: .data), let paneID = ref.paneID {
                event = .paneFocused(paneID: paneID, workspaceID: ref.workspaceID ?? "")
            } else {
                event = .unknown(type: kind)
            }
        case let k where k.hasPrefix("workspace."):
            event = .workspaceChanged(kind: k)
        case let k where k.hasPrefix("tab."):
            event = .tabChanged(kind: k)
        default:
            event = .unknown(type: kind)
        }
    }
}

// MARK: - Line discriminator

/// Classification of one inbound NDJSON line.
enum HerdrInbound {
    /// Carries a request id. The raw line is passed through because only the
    /// caller holding the pending request knows the expected result type.
    case response(id: String, line: Data)
    /// A server-pushed event (no request id).
    case event(HerdrEvent)
    /// Unparseable/unrecognized line. Log + skip — never throws the stream down.
    case garbage(String)
}

/// Splits the inbound stream into responses vs events vs garbage. herdr's wire
/// rule: responses carry `id`, events carry `event` (verified on 0.7.3).
enum HerdrInboundClassifier {
    private struct LineProbe: Decodable {
        let id: String?
        let event: String?
    }

    static func classify(line: Data, log: Logger) -> HerdrInbound {
        guard let probe = try? JSONDecoder().decode(LineProbe.self, from: line) else {
            return .garbage(String("not json"))
        }
        if let id = probe.id {
            return .response(id: id, line: line)
        }
        if probe.event != nil {
            if let envelope = try? JSONDecoder().decode(HerdrEventEnvelope.self, from: line) {
                return .event(envelope.event)
            }
            // Known to be an event but undecodable — degrade, don't drop the stream.
            return .event(.unknown(type: "undecodable"))
        }
        return .garbage("neither id nor event")
    }
}
