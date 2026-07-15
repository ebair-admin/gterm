import Foundation
import os

/// Which logical bridge pipe carries an outbound line. herdr v0.7.3 serves
/// one-shot request/response connections and subscribe-only event streams
/// (verified live — see docs/ground-truth.md discrepancy #9), so the bridge
/// runs two pipes and the client must route each line to the right one.
enum HerdrPipe: Sendable {
    /// Persistent remote pump: opens a fresh one-shot server connection per line.
    case requests
    /// Subscribe-only event stream: one events.subscribe per server connection.
    case events
}

/// Lifecycle of the bridge's underlying channel(s).
enum HerdrTransportState: Sendable, Equatable {
    /// Channel(s) (re)opened. The client must (re)run the ping version gate.
    case connected
    /// Channel dropped, reconnect backoff in flight. In-flight requests failed.
    case retrying
    /// Gave up (max attempts) or closed deliberately.
    case disconnected
}

/// Transport abstraction the API client depends on (spec §5.5). The app
/// implements it over SSH exec child channels
/// (`Sources/SSH/HerdrBridgeChannel.swift`); tests inject a mock — no NIO in
/// the client or its tests.
protocol HerdrTransport: Sendable {
    /// Open the transport (both pipes). Called once per (re)connect cycle.
    func connect() async throws
    /// Send one NDJSON-framed line (the encoder appends `\n` at the bridge).
    func send(_ data: Data, to pipe: HerdrPipe) async throws
    /// NDJSON lines from BOTH pipes, merged. Responses carry request ids,
    /// events don't — `HerdrInboundClassifier` separates them.
    var inbound: AsyncStream<Data> { get }
    var stateChanges: AsyncStream<HerdrTransportState> { get }
    /// Re-open the events pipe on a virgin server connection. herdr 0.7.3
    /// serves exactly ONE events.subscribe per connection (any further request
    /// resets it), so every (re)subscription needs a fresh events channel.
    func restartEvents() async throws
    func disconnect() async
}

/// Request/response + event-stream client for herdr's JSON socket API.
///
/// An actor (spec §3): responses are correlated to requests by UUID id via
/// stored continuations; a per-request timeout cancels the continuation with
/// `HerdrError.timeout`; a bridge drop fails all in-flight continuations with
/// `.disconnected`. The version gate (spec §2) runs on EVERY (re)connect:
/// ping is always the first request, and an unsupported protocol publishes
/// `.unsupported` instead of `.connected` — the sidebar is never rendered
/// against an unverified protocol.
actor HerdrAPIClient {
    /// Client lifecycle, consumed by HerdrSessionStore (Phase 2).
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case retrying
        case connected(HerdrPong)
        /// ping answered but protocol is outside `HerdrProtocol.supportedRange`.
        case unsupported(found: Int)
    }

    private let transport: any HerdrTransport
    private let log = Logger(subsystem: "io.github.madeye.gterm", category: "Herdr")

    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var readerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    /// Continuation for the first gate attempt inside `connect()`.
    private var firstGate: CheckedContinuation<HerdrPong, Error>?

    private let eventStream: AsyncStream<HerdrEvent>
    private let eventContinuation: AsyncStream<HerdrEvent>.Continuation
    private let stateStream: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation

    /// The pong from the latest successful gate.
    private(set) var pong: HerdrPong?

    nonisolated var events: AsyncStream<HerdrEvent> { eventStream }
    nonisolated var states: AsyncStream<State> { stateStream }

    init(transport: any HerdrTransport) {
        self.transport = transport
        (eventStream, eventContinuation) = AsyncStream.makeStream()
        (stateStream, stateContinuation) = AsyncStream.makeStream()
    }

    /// Open the bridge and run the first version gate. On gate failure this
    /// throws, but the transport's reconnect loop keeps cycling in the
    /// background — later successful gates are published on `states`, so a
    /// caller can treat an early throw as "still probing" rather than fatal.
    @discardableResult
    func connect() async throws -> HerdrPong {
        startTasksIfNeeded()
        stateContinuation.yield(.connecting)
        try await transport.connect()
        return try await withCheckedThrowingContinuation { cont in
            firstGate = cont
        }
    }

    /// One request/response round trip, correlated by UUID id. Decoding of the
    /// result is delegated to R; an error envelope maps to `HerdrError.remote`.
    func request<R: Decodable>(
        _ method: String,
        params: (any Encodable)? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> R {
        let request: HerdrRequest
        if let params {
            request = HerdrRequest(method: method, params: params)
        } else {
            request = HerdrRequest(method: method, params: EmptyParams())
        }
        let line: Data
        do {
            line = try JSONEncoder().encode(request)
        } catch {
            throw HerdrError.badResponse("encode \(method)")
        }
        // Routing is derived from the method: 0.7.3 serves events.subscribe only
        // on a fresh, subscribe-only connection (see HerdrTransport.restartEvents).
        let pipe: HerdrPipe = method == "events.subscribe" ? .events : .requests

        // The reader must be running before the response can arrive, or the
        // continuation below would wait until the timeout (tasks also start in
        // connect(); this covers request-without-connect callers).
        startTasksIfNeeded()
        let raw: Data = try await withCheckedThrowingContinuation { cont in
            pending[request.id] = cont
            timeoutTasks[request.id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id: request.id)
            }
            Task { [transport] in
                do {
                    try await transport.send(line, to: pipe)
                } catch {
                    self.fail(id: request.id, error: HerdrError.disconnected)
                }
            }
        }
        if let ok = try? JSONDecoder().decode(HerdrSuccessEnvelope<R>.self, from: raw) {
            return ok.result
        }
        if let err = try? JSONDecoder().decode(HerdrErrorEnvelope.self, from: raw) {
            throw HerdrError.remote(code: err.error.code, message: err.error.message)
        }
        throw HerdrError.badResponse(method)
    }

    /// events.subscribe + agent.list, atomically ordered (spec §5.5).
    ///
    /// Ordering on 0.7.3: pane.agent_status_changed is a PER-PANE subscription,
    /// so the set is built from a first agent.list; the subscribe ack must land
    /// before the second list is taken, so no status change can slip between
    /// snapshot and stream. A pane created in between is caught by the second
    /// list, and the caller resyncs again on the paneCreated event.
    @discardableResult
    func subscribeAndResync() async throws -> [AgentInfo] {
        let first: AgentListResult = try await request("agent.list", params: EmptyParams())
        let paneIDs = first.agents.map(\.paneID).filter { !$0.isEmpty }
        try await transport.restartEvents()
        let _: HerdrAckResult = try await request(
            "events.subscribe",
            params: EventsSubscribeParams(subscriptions: HerdrSubscription.standardSet(agentPaneIDs: paneIDs))
        )
        let second: AgentListResult = try await request("agent.list", params: EmptyParams())
        return second.agents
    }

    func disconnect() async {
        readerTask?.cancel()
        stateTask?.cancel()
        readerTask = nil
        stateTask = nil
        await transport.disconnect()
        failAll(HerdrError.disconnected)
        if let gate = firstGate {
            firstGate = nil
            gate.resume(throwing: HerdrError.disconnected)
        }
        stateContinuation.yield(.disconnected)
    }

    // MARK: - Internals

    private func startTasksIfNeeded() {
        if readerTask == nil {
            readerTask = Task { await self.runReader() }
        }
        if stateTask == nil {
            stateTask = Task { await self.runState() }
        }
    }

    /// Merged inbound stream → resolve pending requests, publish events,
    /// log+skip garbage (never throws the stream down, spec §5.1).
    private func runReader() async {
        for await line in transport.inbound {
            switch HerdrInboundClassifier.classify(line: line, log: log) {
            case .response(let id, let raw):
                if let cont = pending.removeValue(forKey: id) {
                    timeoutTasks.removeValue(forKey: id)?.cancel()
                    cont.resume(returning: raw)
                } else {
                    log.debug("response for unknown/expired id — dropped (metadata only)")
                }
            case .event(let event):
                eventContinuation.yield(event)
            case .garbage(let reason):
                log.notice("skipping non-protocol line (\(reason, privacy: .public))")
            }
        }
        failAll(HerdrError.disconnected)
    }

    private func runState() async {
        for await transportState in transport.stateChanges {
            switch transportState {
            case .connected:
                await performGate()
            case .retrying:
                failAll(HerdrError.disconnected)
                stateContinuation.yield(.retrying)
            case .disconnected:
                failAll(HerdrError.disconnected)
                stateContinuation.yield(.disconnected)
            }
        }
    }

    /// The version gate: ping is the FIRST request on every bridge connect
    /// (spec §2). Unsupported protocol → `.unsupported`, never `.connected`.
    private func performGate() async {
        do {
            let pong: HerdrPong = try await request("ping", params: EmptyParams())
            guard HerdrProtocol.isSupported(pong.proto) else {
                log.error("unsupported herdr protocol \(pong.proto, privacy: .public) — feature disabled")
                stateContinuation.yield(.unsupported(found: pong.proto))
                if let gate = firstGate {
                    firstGate = nil
                    gate.resume(throwing: HerdrError.unsupportedProtocol(found: pong.proto))
                }
                return
            }
            self.pong = pong
            log.info("herdr gate ok: protocol \(pong.proto, privacy: .public)")
            stateContinuation.yield(.connected(pong))
            if let gate = firstGate {
                firstGate = nil
                gate.resume(returning: pong)
            }
        } catch {
            log.notice("gate ping failed: \(String(describing: error), privacy: .public)")
            if let gate = firstGate {
                firstGate = nil
                gate.resume(throwing: error)
            }
        }
    }

    private func expire(id: String) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)
        cont.resume(throwing: HerdrError.timeout)
    }

    private func fail(id: String, error: Error) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        cont.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        all.values.forEach { $0.resume(throwing: error) }
    }
}
