import Combine
import Foundation
import os

/// The UI-facing source of truth for the Herd view (spec §5.6).
///
/// One `@MainActor` ObservableObject sits between `HerdrAPIClient` (actor) and
/// SwiftUI: it consumes the client's state + event streams, applies deltas to a
/// stably sorted agent list, and re-runs `subscribeAndResync()` after EVERY
/// (re)connect — events are deltas, so a resync after every subscribe is
/// mandatory (spec §3). All herdr failures are non-fatal by design (spec §2):
/// they land in `phase`, never in the terminal's way.
@MainActor
final class HerdrSessionStore: ObservableObject {
    /// Lifecycle surfaced to the UI (sidebar affordance, banners, sheet).
    enum Phase: Equatable {
        /// Not started (or stopped).
        case idle
        /// Bridge opening / version gate in flight.
        case probing
        /// ping answered but the protocol is outside `HerdrProtocol.supportedRange`
        /// — the feature stays disabled with an actionable message (spec §2).
        case unsupported(String)
        case connected
        case disconnected(retrying: Bool)
    }

    @Published private(set) var phase: Phase = .idle
    /// Stable sort (spec §5.6): workspace, then display name.
    @Published private(set) var agents: [AgentInfo] = []
    /// First agent awaiting a permission decision — drives the approval sheet
    /// (Phase 3). Recomputed on every list mutation.
    @Published private(set) var blockedAgent: AgentInfo?

    private let client: HerdrAPIClient
    private let log = Logger(subsystem: "io.github.madeye.gterm", category: "HerdrStore")

    private var eventTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    /// Serializes resyncs: a `.connected` arriving mid-resync must not
    /// interleave subscribe/list round trips with the in-flight one — it sets
    /// `resyncNeeded` so the loop runs once more with a fresh snapshot.
    private var resyncTask: Task<Void, Never>?
    private var resyncNeeded = false
    /// Hysteresis for screen-scraped states: herdr's per-frame detection flips
    /// working↔idle as spinner frames (un)match the manifest rules, which
    /// makes the sidebar blink. `idle` must be stable for 1 s before it
    /// applies; every other state applies immediately and cancels the wait.
    private var pendingIdleTask: [String: Task<Void, Never>] = [:]
    private var pendingIdleDelta: [String: AgentInfo] = [:]

    init(client: HerdrAPIClient) {
        self.client = client
    }

    /// Begin consuming the client streams and open the bridge. Idempotent.
    func start() {
        guard eventTask == nil else { return }
        phase = .probing
        eventTask = Task { [weak self] in
            guard let client = self?.client else { return }
            for await event in client.events {
                self?.apply(event)
            }
        }
        stateTask = Task { [weak self] in
            guard let client = self?.client else { return }
            for await state in client.states {
                self?.handle(state)
            }
        }
        Task { [weak self] in
            do {
                _ = try await self?.client.connect()
            } catch {
                // The states stream already published the precise phase
                // (.unsupported / .retrying) — the log line is for diagnostics.
                self?.log.notice("connect/gate ended early: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Tear down streams and the bridge. The terminal session is unaffected —
    /// the bridge's child channels close, the parent SSH connection stays up.
    func stop() {
        eventTask?.cancel()
        stateTask?.cancel()
        resyncTask?.cancel()
        eventTask = nil
        stateTask = nil
        resyncTask = nil
        for (_, task) in pendingIdleTask { task.cancel() }
        pendingIdleTask.removeAll()
        pendingIdleDelta.removeAll()
        Task { [client] in await client.disconnect() }
        phase = .idle
        agents = []
        blockedAgent = nil
        approvalPending = nil
    }

    // MARK: - Intents

    /// Tap → agent.focus (spec §3): herdr moves focus server-side and the TUI
    /// in the terminal surface follows. Failures are logged only — the next
    /// status event/resync shows the outcome.
    func focus(agent: AgentInfo) {
        Task { [client, log] in
            do {
                let _: HerdrAckResult = try await client.request(
                    "agent.focus", params: AgentTargetParams(target: agent.paneID))
            } catch {
                log.notice("agent.focus failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Approval intents (spec §2.7 safety sequence)

    /// Outcome of an approve/deny attempt.
    enum ApprovalOutcome: Equatable {
        /// Keys injected; awaiting the confirming status event.
        case sent
        /// The agent was no longer blocked when re-checked — the UI must say
        /// "state changed, review again", NEVER blind-send (spec §2.7).
        case stateChanged
        /// Unknown agent: no keymap, no buttons — "open terminal to respond".
        case noKeymap
        /// Transport/remote failure; metadata only, never pane content.
        case failed(String)
    }

    /// paneID with an answer in flight (sheet shows pending; cleared by the
    /// confirming status event or a resync).
    @Published private(set) var approvalPending: String?

    func approve(agent: AgentInfo) async -> ApprovalOutcome {
        await answer(agent) { $0.approve }
    }

    func deny(agent: AgentInfo) async -> ApprovalOutcome {
        await answer(agent) { $0.deny }
    }

    /// The §2.7 sequence: keymap lookup → RE-FETCH agent.get and confirm the
    /// status is STILL blocked → only then pane.send_keys → optimistic
    /// pending, confirmed by the next status event (see apply(_:)). No
    /// auto-approve logic of any kind.
    private func answer(_ agent: AgentInfo, keys: (AgentKeymap) -> [String]) async -> ApprovalOutcome {
        guard let keymap = AgentKeymaps.keymap(for: agent.agent) else {
            return .noKeymap
        }
        do {
            let fresh: AgentGetResult = try await client.request(
                "agent.get", params: AgentTargetParams(target: agent.paneID))
            guard fresh.agent?.status == .blocked else {
                return .stateChanged
            }
            let _: HerdrAckResult = try await client.request(
                "pane.send_keys",
                params: PaneSendKeysParams(paneID: agent.paneID, keys: keys(keymap)))
            approvalPending = agent.paneID
            return .sent
        } catch {
            log.notice("approval answer failed: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }

    /// The prompt text the user is being asked about (approval sheet body).
    /// agent.read with strip_ansi — the text is shown verbatim, never logged
    /// (pane content contains secrets, spec §2.7). nil on failure.
    func readPrompt(agent: AgentInfo) async -> String? {
        do {
            let result: AgentReadResult = try await client.request(
                "agent.read", params: AgentReadParams(target: agent.paneID))
            return result.read.text
        } catch {
            log.notice("agent.read failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Force a resync (spec Phase 3.3: foreground refresh). Awaits the round
    /// trip so callers can act on the fresh list (e.g. local notification).
    func resync() async {
        scheduleResync()
        await resyncTask?.value
    }

    // MARK: - Client state → phase

    private func handle(_ state: HerdrAPIClient.State) {
        switch state {
        case .connecting:
            phase = .probing
        case .connected:
            phase = .connected
            scheduleResync()
        case .retrying:
            phase = .disconnected(retrying: true)
        case .disconnected:
            phase = .disconnected(retrying: false)
        case .unsupported(let found):
            phase = .unsupported(
                "herdr speaks protocol \(found); this build supports \(HerdrProtocol.supportedRange). Update herdr or gterm.")
        }
    }

    // MARK: - Events → agent list

    private func apply(_ event: HerdrEvent) {
        switch event {
        case .agentStatusChanged(let delta):
            guard agents.contains(where: { $0.paneID == delta.paneID }) else {
                // A status delta for a pane we don't know: the list is stale
                // (its pane.created may predate our subscribe ack) — resync.
                scheduleResync()
                return
            }
            if delta.status == .idle {
                // Idle is the flickery half of screen-scraped states — apply
                // it only after it has been stable for a moment (latest wins).
                pendingIdleDelta[delta.paneID] = delta
                pendingIdleTask[delta.paneID]?.cancel()
                pendingIdleTask[delta.paneID] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1000))
                    guard let self, !Task.isCancelled,
                          let pending = self.pendingIdleDelta.removeValue(forKey: delta.paneID)
                    else { return }
                    self.pendingIdleTask.removeValue(forKey: delta.paneID)
                    self.applyStatusDelta(pending)
                }
                return
            }
            // Any non-idle state is significant on its own (blocked above
            // all): apply now and drop a pending idle so it can't overwrite.
            pendingIdleTask.removeValue(forKey: delta.paneID)?.cancel()
            pendingIdleDelta.removeValue(forKey: delta.paneID)
            applyStatusDelta(delta)
        case .paneCreated:
            // Also extends the PER-PANE subscription set to the new pane —
            // pane.agent_status_changed has no wildcard (ground-truth #9).
            scheduleResync()
        case .paneClosed(let paneID, _):
            pendingIdleTask.removeValue(forKey: paneID)?.cancel()
            pendingIdleDelta.removeValue(forKey: paneID)
            agents.removeAll { $0.paneID == paneID }
            if approvalPending == paneID { approvalPending = nil }
            recomputeBlocked()
        case .paneFocused(let paneID, _):
            agents = agents.map { $0.withFocus($0.paneID == paneID) }
        case .workspaceChanged, .tabChanged, .unknown:
            // List shape comes from resyncs; lifecycle kinds are metadata only.
            break
        }
    }

    private func applyStatusDelta(_ delta: AgentInfo) {
        guard let idx = agents.firstIndex(where: { $0.paneID == delta.paneID }) else { return }
        let merged = agents[idx].merging(delta)
        // herdr re-emits status on every screen-detection pass (~2.5 Hz
        // while an agent's UI animates); swallow no-change deltas so
        // @Published doesn't fan a render storm out to the sidebar/sheet.
        guard merged != agents[idx] else { return }
        agents[idx] = merged
        // The confirmation half of the optimistic pending (§3.2): any
        // status event for the answered pane ends the wait.
        if approvalPending == delta.paneID, delta.status != .blocked {
            approvalPending = nil
        }
        recomputeBlocked()
    }

    private func recomputeBlocked() {
        let next = agents.first { $0.status == .blocked }
        // Publish only real transitions: @Published fires on EVERY assignment
        // (equal values included), and each one re-renders the sidebar and
        // retriggers the approval sheet's presentation logic.
        guard next != blockedAgent else { return }
        let oldID = blockedAgent?.paneID, newID = next?.paneID
        log.notice("blockedAgent: \(oldID ?? "nil", privacy: .public) → \(newID ?? "nil", privacy: .public)")
        blockedAgent = next
    }

    // MARK: - Resync

    private func scheduleResync() {
        resyncNeeded = true
        guard resyncTask == nil else { return }
        resyncTask = Task { [weak self] in
            guard let self else { return }
            while self.resyncNeeded {
                self.resyncNeeded = false
                do {
                    let list = try await self.client.subscribeAndResync()
                    self.agents = Self.sorted(list)
                    self.recomputeBlocked()
                } catch {
                    // The state stream drives the next attempt (.retrying →
                    // .connected → scheduleResync); log metadata only.
                    self.log.notice("resync failed: \(String(describing: error), privacy: .public)")
                    break
                }
            }
            self.resyncTask = nil
        }
    }

    /// Stable UI order (spec §5.6): workspace, then display name.
    static func sorted(_ list: [AgentInfo]) -> [AgentInfo] {
        list.sorted {
            if $0.workspaceID != $1.workspaceID {
                return $0.workspaceID < $1.workspaceID
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
