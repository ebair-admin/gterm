import SwiftUI
import UserNotifications

/// sheet(item:) needs Identifiable; paneID is the stable key (ground-truth #9).
extension AgentInfo: Identifiable {
    var id: String { paneID }
}

/// The native approval sheet (spec Phase 3.2): presented when an agent turns
/// `blocked`. Body shows the REAL prompt text (agent.read, ANSI-stripped,
/// verbatim, monospaced — pane content is never logged, spec §2.7). Buttons:
/// Approve / Deny / Open in Terminal — but only for agents with a known
/// keymap (§3.1); unknown agents get the "answer in the terminal" hint
/// instead of buttons we can't verify.
///
/// Every tap runs the §2.7 safety sequence in the store (re-fetch agent.get,
/// confirm STILL blocked, then send keys). A flap between sheet-open and tap
/// is caught and surfaced as "state changed, review again" — never a blind
/// send.
struct ApprovalSheet: View {
    let agent: AgentInfo
    @ObservedObject var store: HerdrSessionStore
    /// Focuses the agent's pane so the user can answer in the TUI.
    let onOpenInTerminal: (AgentInfo) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var promptText: String?
    @State private var loading = true
    @State private var busy = false
    @State private var outcomeMessage: String?

    private var keymap: AgentKeymap? { AgentKeymaps.keymap(for: agent.agent) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                promptBody
                if let outcomeMessage {
                    Label(outcomeMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                }
                Spacer(minLength: 0)
                buttons
            }
            .padding()
            .navigationTitle("Approval needed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(busy)
        .task { await loadPrompt() }
    }

    // MARK: - Prompt body (verbatim, monospaced — spec 3.2)

    @ViewBuilder private var promptBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(agent.displayName) · \(agent.workspaceID)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("reading the prompt…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ScrollView {
                    Text(promptText?.isEmpty == false ? promptText! : "(no prompt text could be read)")
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 320)
                .padding(8)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder private var buttons: some View {
        if keymap == nil {
            Label(
                "One-tap answers aren't available for this agent type yet.",
                systemImage: "keyboard"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Open in Terminal") { openInTerminal() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 12) {
                Button {
                    Task { await answer(approve: false) }
                } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await answer(approve: true) }
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(busy)
            Button("Open in Terminal") { openInTerminal() }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions

    private func loadPrompt() async {
        loading = true
        promptText = await store.readPrompt(agent: agent)
        loading = false
    }

    private func answer(approve: Bool) async {
        busy = true
        let outcome = approve ? await store.approve(agent: agent) : await store.deny(agent: agent)
        busy = false
        switch outcome {
        case .sent:
            // The store tracks the optimistic pending; the sidebar shows the
            // confirming status flip. Nothing more to do here.
            dismiss()
        case .stateChanged:
            // §2.7 flap: surface it and reload the CURRENT prompt for review.
            outcomeMessage = "State changed — review the prompt again."
            await loadPrompt()
        case .noKeymap:
            outcomeMessage = "No keymap for this agent — answer in the terminal."
        case .failed(let why):
            outcomeMessage = "Couldn't send the answer: \(why)"
        }
    }

    private func openInTerminal() {
        onOpenInTerminal(agent)
        dismiss()
    }
}

// MARK: - Local notifications (spec Phase 3.3)

/// Posts a local notification when a foreground resync finds a blocked agent.
///
/// WHY NOT REAL PUSH: iOS suspends sockets on lock/background, so without a
/// relay (§2 forbids one) the app CANNOT learn about a block while away — the
/// foreground resync is the design, not a bug to fix with background hacks
/// the App Store would reject. This notification therefore fires after the
/// resync on scenePhase → active: it leaves a record in Notification Center
/// and covers the case where the app is foreground but the terminal screen
/// isn't the visible tab.
final class ApprovalNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ApprovalNotifier()

    /// Set the delegate once (foreground banners) and pre-request permission.
    /// Called from TerminalScreen.onAppear — the earliest the feature exists.
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Metadata only — pane content (the prompt text) contains secrets and
    /// must never leave the app (spec §2.7).
    static func notifyBlocked(agent: AgentInfo) {
        let content = UNMutableNotificationContent()
        content.title = "\(agent.displayName) needs approval"
        content.body = "An agent in workspace \(agent.workspaceID) is waiting for a decision."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "herdr-blocked-\(agent.paneID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Show banners even while the app is foreground (the terminal may not be
    /// the visible screen).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
