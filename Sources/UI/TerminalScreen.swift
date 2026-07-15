import Combine
import SwiftUI

/// A pending host-key trust decision surfaced to the UI, pairing the prompt
/// details with the callback that resumes the SSH handshake.
struct HostKeyPromptRequest {
    let prompt: HostKeyPrompt
    let decide: (Bool) -> Void
}

/// A URL tapped in the terminal. Wraps `URL` so it can drive a `fullScreenCover(item:)`.
struct TappedURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Full-screen terminal for an active SSH connection, with a slim status bar
/// and a close button.
struct TerminalScreen: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    let connection: SSHConnection
    /// The owning `SavedConnection.id`, used to resolve persisted port forwards.
    let savedConnectionID: UUID?
    @ObservedObject var forwardStore: PortForwardStore
    let onClose: () -> Void

    @State private var state: SSHSessionState = .idle
    @State private var hostKeyRequest: HostKeyPromptRequest?
    @State private var terminalView: TerminalSurfaceView?
    @State private var showingAICommands = false
    @State private var showingForwards = false
    @State private var forwardStates: [UUID: PortForwardStatus] = [:]
    @State private var session: SSHSession?
    @State private var browsing: PortForward?
    /// A URL tapped in the terminal, opened in the in-app browser.
    @State private var linkURL: TappedURL?
    /// Herd view: created only after SSH connects (the bridge needs the
    /// authenticated channel); the sidebar affordance appears only once the
    /// version gate passes (spec §2 — never render on an unverified protocol).
    @State private var herdStore: HerdrSessionStore?
    @State private var herdPhase: HerdrSessionStore.Phase = .idle
    @State private var herdSidebarOpen = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Persisted forward configs for this connection (empty if not a saved host).
    private var connectionForwards: [PortForward] {
        guard let id = savedConnectionID else { return [] }
        return forwardStore.forwards(for: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            HStack(spacing: 0) {
                // iPad (regular width): persistent sidebar column. Once open it
                // STAYS open across bridge drops — the sidebar shows the
                // disconnected banner; the terminal is unaffected (spec §2).
                if horizontalSizeClass == .regular, herdSidebarOpen, let store = herdStore {
                    AgentSidebarView(store: store)
                        .frame(width: 300)
                    Divider()
                }
                TerminalView(ghostty: ghostty, makeSession: { view in
                    SSHSession(
                        connection: connection,
                        view: view,
                        forwards: connectionForwards,
                        onHostKeyPrompt: { prompt, decide in
                            hostKeyRequest = HostKeyPromptRequest(prompt: prompt, decide: decide)
                        },
                        onForwardChange: { id, st in forwardStates[id] = st }
                    ) { newState in
                        state = newState
                        handleSessionState(newState)
                    }
                }, onCreate: { view in
                    view.onOpenURL = { url in linkURL = TappedURL(url: url) }
                    DispatchQueue.main.async { terminalView = view }
                }, onSession: { s in
                    DispatchQueue.main.async {
                        session = s
                        maybeStartHerdProbe()
                    }
                })
            }
        }
        .overlay(alignment: .leading) {
            // iPhone (compact width): slide-over drawer from the leading edge.
            if horizontalSizeClass == .compact, herdSidebarOpen, let store = herdStore {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation { herdSidebarOpen = false }
                        }
                    AgentSidebarView(store: store, onClose: {
                        withAnimation { herdSidebarOpen = false }
                    })
                    .frame(width: 300)
                }
                .transition(.move(edge: .leading))
            }
        }
        .onReceive((herdStore?.$phase)?.eraseToAnyPublisher() ?? Empty(completeImmediately: false).eraseToAnyPublisher()) { phase in
            herdPhase = phase
        }
        .onDisappear {
            herdStore?.stop()
        }
        .sheet(isPresented: $showingAICommands) {
            AICommandSheet(
                runCommand: { terminalView?.runCommand($0) },
                gatherContext: {
                    (terminalView?.readVisibleText() ?? "", CommandHistory.shared.recent(limit: 15))
                }
            )
        }
        .sheet(isPresented: $showingForwards) {
            PortForwardStatusSheet(
                forwards: connectionForwards,
                statuses: forwardStates,
                onToggle: { f, on in
                    if on { session?.startForward(f.id) } else { session?.stopForward(f.id) }
                },
                onOpenBrowser: { f in
                    showingForwards = false
                    browsing = f
                }
            )
        }
        .fullScreenCover(item: $browsing) { f in
            if let url = f.localURL {
                BrowserScreen(initialURL: url) { browsing = nil }
            }
        }
        .fullScreenCover(item: $linkURL) { tapped in
            BrowserScreen(initialURL: tapped.url) { linkURL = nil }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .alert(
            hostKeyRequest?.prompt.kind == .changed ? "Host Key Changed" : "Unknown Host",
            isPresented: Binding(
                get: { hostKeyRequest != nil },
                set: { if !$0 { hostKeyRequest?.decide(false); hostKeyRequest = nil } }
            ),
            presenting: hostKeyRequest
        ) { request in
            let isChanged = request.prompt.kind == .changed
            Button(isChanged ? "Accept New Key" : "Trust", role: isChanged ? .destructive : nil) {
                request.decide(true)
                hostKeyRequest = nil
            }
            Button("Cancel", role: .cancel) {
                request.decide(false)
                hostKeyRequest = nil
            }
        } message: { request in
            Text(hostKeyMessage(request.prompt))
        }
    }

    // MARK: - Herd view

    /// React to SSH lifecycle: start the bridge probe once connected; tear the
    /// store down with the session (spec Phase 2.3 — the bridge's lifecycle is
    /// the session's).
    private func handleSessionState(_ newState: SSHSessionState) {
        switch newState {
        case .connected:
            maybeStartHerdProbe()
        case .failed, .closed:
            herdStore?.stop()
            herdStore = nil
            herdSidebarOpen = false
        default:
            break
        }
    }

    /// Start the herdr bridge probe. Runs at most once per session; both the
    /// session-object delivery and the connected-state transition call it
    /// (order between the two is not guaranteed). If the probe never opens
    /// (no herdr on the host), nothing appears and the terminal is unchanged.
    private func maybeStartHerdProbe() {
        guard herdStore == nil, let session, state == .connected else { return }
        guard let transport = session.makeHerdrTransport(socketPath: connection.herdrSocketPath) else { return }
        let store = HerdrSessionStore(client: HerdrAPIClient(transport: transport))
        herdStore = store
        store.start()
    }

    private func hostKeyMessage(_ prompt: HostKeyPrompt) -> String {
        switch prompt.kind {
        case .firstUse:
            return """
            The authenticity of host \(prompt.host) can't be established.

            Key fingerprint:
            \(prompt.fingerprint)

            Trust this host and continue connecting?
            """
        case .changed:
            return """
            ⚠️ The host key for \(prompt.host) has changed. This may indicate a \
            man-in-the-middle attack, or the server may simply have been reinstalled.

            Previously trusted:
            \(prompt.previousFingerprint ?? "<unknown>")

            New fingerprint:
            \(prompt.fingerprint)

            Only accept if you expected this change.
            """
        }
    }

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            Text("\(connection.username)@\(connection.host)")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button { showingAICommands = true } label: {
                Image(systemName: "sparkles").font(.body.weight(.semibold))
            }
            .accessibilityLabel("AI commands")
            Button { showingForwards = true } label: {
                Image(systemName: "network").font(.body.weight(.semibold))
            }
            .accessibilityLabel("Port forwards")
            .disabled(state != .connected)
            // Herd affordance: only once the version gate has PASSED (spec §2 —
            // the sidebar is never rendered on an unverified protocol).
            if herdPhase == .connected, herdStore != nil {
                Button {
                    withAnimation { herdSidebarOpen.toggle() }
                } label: {
                    Image(systemName: "square.grid.2x2").font(.body.weight(.semibold))
                }
                .accessibilityLabel("Herd agents")
            }
            statusIndicator
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var statusIndicator: some View {
        switch state {
        case .idle, .connecting, .authenticating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.white)
                Text(label).font(.caption)
            }
        case .connected:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        case .closed:
            Text("disconnected").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch state {
        case .connecting: return "connecting…"
        case .authenticating: return "authenticating…"
        default: return ""
        }
    }
}
