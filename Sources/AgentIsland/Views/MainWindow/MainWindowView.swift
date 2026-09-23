import IslandCore
import SwiftUI

/// The main window: a sidebar of pages, and the page on the right.
struct MainWindowView: View {
    @Bindable var state: MainWindowState
    let model: IslandModel
    let hooks: HookManager

    var body: some View {
        NavigationSplitView {
            List(selection: $state.section) {
                ForEach(MainSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(section == .agents ? model.liveSessions.count : 0)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch state.section ?? .agents {
            case .agents:
                AgentsPane(model: model, hooks: hooks) { state.section = .hooks }
            case .island:
                IslandPane(settings: model.settings)
            case .hooks:
                HooksPane(hooks: hooks)
            }
        }
    }
}

// MARK: - Agents

/// Every live session, with what it is doing and a way to jump to it.
struct AgentsPane: View {
    let model: IslandModel
    let hooks: HookManager
    let showHooks: () -> Void

    var body: some View {
        let sessions = model.liveSessions

        VStack(spacing: 0) {
            if model.settings.watchClaude, hooks.state(for: .claude) != .installed {
                HooksBanner(state: hooks.state(for: .claude), action: showHooks)
            }

            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Agents Running", systemImage: "circle.dashed")
                } description: {
                    Text("Start a Claude Code session or a Codex thread. On its first prompt it shows up here, and as a circle beside the notch.")
                }
            } else {
                List(sessions) { session in
                    AgentRow(
                        session: session,
                        petID: model.settings.codexPetID,
                        open: { model.open(id: session.id) },
                        hide: { model.dismiss(id: session.id) }
                    )
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Agents")
        .navigationSubtitle(model.summary)
    }
}

/// One session: its mascot in its ring, what it is up to, and how long for.
private struct AgentRow: View {
    let session: AgentSession
    let petID: String
    let open: () -> Void
    let hide: () -> Void

    var body: some View {
        let accent = IslandStyle.ring(for: session)

        HStack(spacing: 12) {
            MascotBadge(session: session, petID: petID)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(location)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(session.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(session.effortLabel)
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.15), in: Capsule())
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(session.elapsedText(now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button("Open", action: open)
                .help("Open this chat")
            Button(action: hide) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide this circle until the agent has something new")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
    }

    /// Repo, branch, and where the chat runs, whichever are known.
    private var location: String {
        var parts: [String] = []
        if !session.repo.isEmpty { parts.append(session.repo) }
        if let branch = session.branch, !branch.isEmpty { parts.append(branch) }
        if let host = session.hostLabel { parts.append(host) }
        return parts.isEmpty ? session.kind.rawValue.capitalized : parts.joined(separator: " \u{00b7} ")
    }
}

/// The mascot in its status ring, the way the island draws it, at a gentle frame rate.
private struct MascotBadge: View {
    let session: AgentSession
    let petID: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
            let clock = context.date.timeIntervalSinceReferenceDate
            let secondsInStatus = context.date.timeIntervalSince(session.statusChangedAt)

            ZStack {
                Circle().fill(.black)
                switch session.kind {
                case .claude:
                    ClawdView(
                        status: session.status,
                        color: session.status == .error ? IslandStyle.error : IslandStyle.claude,
                        clock: clock,
                        secondsInStatus: secondsInStatus
                    )
                    .padding(9)
                case .codex:
                    CodexPetView(
                        petID: petID,
                        status: session.status,
                        clock: clock,
                        secondsInStatus: secondsInStatus,
                        fallbackColor: IslandStyle.codex
                    )
                    .padding(5)
                }
                Circle().strokeBorder(IslandStyle.ring(for: session), lineWidth: 2.5)
            }
            .opacity(session.status == .idle ? 0.6 : 1)
        }
    }
}

/// Nudges toward the hooks when Claude sessions are being watched without them.
private struct HooksBanner: View {
    let state: HookManager.State
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.title3)
                .foregroundStyle(IslandStyle.question)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(state == .notInstalled ? "Set Up\u{2026}" : "Repair\u{2026}", action: action)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding([.horizontal, .top], 12)
    }

    private var title: String {
        state == .notInstalled ? "Claude hooks are off" : "Claude hooks point at another copy of the app"
    }

    private var message: String {
        state == .notInstalled
            ? "Without them a permission prompt looks just like a long-running tool."
            : "The app moved since they were added, so Claude sessions report nothing."
    }
}
