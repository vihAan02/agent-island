import AppKit
import IslandCore
import SwiftUI

/// Whether each agent's hooks are in place, and the buttons to change that.
struct HooksPane: View {
    let hooks: HookManager

    var body: some View {
        Form {
            HookSection(
                kind: .claude,
                title: "Claude Code",
                summary: "Reports prompts, questions, permission prompts, plans, errors, and the end of each turn. Without hooks a permission prompt looks just like a long-running tool.",
                hooks: hooks
            )
            HookSection(
                kind: .codex,
                title: "Codex",
                summary: "Optional: Codex's session files already report most of this. Add hooks if approval requests never turn a circle amber. Codex may ask you to trust them the first time.",
                hooks: hooks
            )
            Section {
                Text("Every hook runs in the background, prints nothing, and gives up after 300 ms, so it never slows an agent down. Each settings file is backed up to `.agent-island.bak` before it changes. If you move the app, repair the hooks so they point at the new copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hooks")
        .onAppear { hooks.refresh() }
    }
}

private struct HookSection: View {
    let kind: AgentKind
    let title: String
    let summary: String
    let hooks: HookManager

    var body: some View {
        let state = hooks.state(for: kind)
        let path = HookManager.settingsPath(for: kind)

        Section {
            LabeledContent("Status") {
                Label(statusText(state), systemImage: symbol(state))
                    .foregroundStyle(color(state))
            }

            if case .elsewhere(let commands) = state {
                Text("They run \(commands.map(Self.abbreviated).joined(separator: ", ")), not this copy of the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let error = hooks.errors[kind] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(IslandStyle.error)
                    .textSelection(.enabled)
            }

            HStack {
                switch state {
                case .notInstalled:
                    Button("Add Hooks") { hooks.install(kind) }
                        .buttonStyle(.borderedProminent)
                case .installed:
                    Button("Remove Hooks") { hooks.uninstall(kind) }
                case .elsewhere:
                    Button("Repair") { hooks.install(kind) }
                        .buttonStyle(.borderedProminent)
                    Button("Remove") { hooks.uninstall(kind) }
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .disabled(!FileManager.default.fileExists(atPath: path))
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                Text(Self.abbreviated(path)).monospaced()
            }
        }
    }

    private func statusText(_ state: HookManager.State) -> String {
        switch state {
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case .elsewhere: "Installed for another copy of the app"
        }
    }

    private func symbol(_ state: HookManager.State) -> String {
        switch state {
        case .notInstalled: "circle.dashed"
        case .installed: "checkmark.circle.fill"
        case .elsewhere: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ state: HookManager.State) -> Color {
        switch state {
        case .notInstalled: .secondary
        case .installed: IslandStyle.complete
        case .elsewhere: IslandStyle.question
        }
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
