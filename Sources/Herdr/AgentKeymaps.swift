import Foundation

/// Per-agent approval key sequences (spec §3.1).
///
/// These are DATA, not code — herdr's "blocked" detection is regex
/// screen-scraping and agent TUIs change their prompt layouts weekly (spec §7
/// risk #2), so a mapping update must never require a logic change. Keys in
/// `defaults` mirror herdr's agent-detection manifest ids (the same string
/// `AgentInfo.agent` carries).
struct AgentKeymap: Sendable, Equatable {
    /// Key names as herdr's pane.send_keys expects them (e.g. "Enter",
    /// "Escape", "y"). Sent in order.
    let approve: [String]
    let deny: [String]
}

enum AgentKeymaps {
    /// Conservative defaults: an agent is only listed once its real prompt
    /// flow has been verified end to end. Deliberately NOT exhaustive — a
    /// wrong keypress into a prompt we didn't verify is worse than no button
    /// (the user can always answer in the terminal instead).
    static let defaults: [String: AgentKeymap] = [
        // Claude Code permission prompt: Enter accepts the highlighted
        // default (Yes), Escape rejects.
        "claude": AgentKeymap(approve: ["Enter"], deny: ["Escape"]),
    ]

    /// The keymap for an agent id (case-insensitive). nil means "we don't
    /// know how this agent takes answers": the approval sheet hides the
    /// Approve/Deny buttons and shows the "open terminal to respond" hint
    /// instead (spec §3.1). Never guess.
    static func keymap(for agent: String?) -> AgentKeymap? {
        guard let agent, !agent.isEmpty else { return nil }
        return defaults[agent.lowercased()]
    }
}
