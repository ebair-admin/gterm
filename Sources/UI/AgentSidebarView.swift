import SwiftUI

/// The Herd view's agent list (spec Phase 2.2): every pane herdr reports,
/// grouped by workspace, with a status indicator that is distinguishable by
/// SHAPE as well as color (the four agent states must not rely on color
/// alone) plus an accessibility label. Tap → `agent.focus` via the store;
/// herdr moves focus server-side and the TUI in the terminal follows.
///
/// The view itself is presentation-agnostic: TerminalScreen embeds it as a
/// slide-over drawer (compact width / iPhone) or a persistent column
/// (regular width / iPad) and passes `onClose` only in drawer mode.
struct AgentSidebarView: View {
    @ObservedObject var store: HerdrSessionStore
    /// Present only in drawer mode — shows the close button.
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.phase != .connected {
                phaseBanner
            }
            if store.agents.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "square.grid.2x2",
                    description: Text("herdr is connected but no panes are running.")
                )
                Spacer()
            } else {
                List {
                    ForEach(workspaceGroups, id: \.workspaceID) { group in
                        Section(group.workspaceID) {
                            ForEach(group.agents, id: \.paneID) { agent in
                                row(for: agent)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header + phase banner

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.body.weight(.semibold))
            Text("Herd")
                .font(.subheadline.weight(.semibold))
            Text("\(store.agents.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Close sidebar")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
    }

    /// Every bridge condition is a DESIGNED state with its own remediation
    /// (spec Phase 4.2 builds on this) — never a bare spinner.
    @ViewBuilder private var phaseBanner: some View {
        HStack(spacing: 8) {
            switch store.phase {
            case .idle, .probing:
                ProgressView().controlSize(.small).tint(.white)
                Text("detecting herdr…")
            case .unsupported(let details):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(details)
            case .disconnected(let retrying):
                Image(systemName: "bolt.slash.fill").foregroundStyle(.red)
                Text(retrying ? "herdr disconnected — reconnecting…" : "herdr disconnected")
            case .connected:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
    }

    // MARK: - Rows

    @ViewBuilder private func row(for agent: AgentInfo) -> some View {
        Button {
            store.focus(agent: agent)
        } label: {
            HStack(spacing: 10) {
                statusIndicator(agent.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(.subheadline.weight(agent.focused ? .semibold : .regular))
                        .lineLimit(1)
                    Text(statusText(agent.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if agent.focused {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(agent.displayName), \(statusText(agent.status))\(agent.focused ? ", focused" : "")")
        .accessibilityHint("Double-tap to focus this agent in the terminal")
    }

    /// Shape + color + text — never color alone (spec Phase 2.2).
    @ViewBuilder private func statusIndicator(_ status: AgentStatus) -> some View {
        switch status {
        case .idle:
            Image(systemName: "circle.fill").foregroundStyle(.green)
        case .working:
            Image(systemName: "triangle.fill").foregroundStyle(.blue)
        case .blocked:
            Image(systemName: "octagon.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.square.fill").foregroundStyle(.gray)
        case .unknown:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.gray)
        }
    }

    private func statusText(_ status: AgentStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .blocked: return "blocked"
        case .done: return "done"
        case .unknown: return "unknown"
        }
    }

    // MARK: - Grouping

    private struct WorkspaceGroup {
        let workspaceID: String
        var agents: [AgentInfo]
    }

    /// Groups the store's (already sorted) list by workspace, preserving first-
    /// appearance order so the UI order matches the store's stable sort.
    private var workspaceGroups: [WorkspaceGroup] {
        var groups: [WorkspaceGroup] = []
        for agent in store.agents {
            if let idx = groups.firstIndex(where: { $0.workspaceID == agent.workspaceID }) {
                groups[idx].agents.append(agent)
            } else {
                groups.append(WorkspaceGroup(workspaceID: agent.workspaceID, agents: [agent]))
            }
        }
        return groups
    }
}
