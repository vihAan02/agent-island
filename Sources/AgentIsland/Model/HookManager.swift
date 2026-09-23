import Foundation
import IslandCore
import Observation

/// Adds and removes the agents' hooks, and says whether the ones in place still
/// point at this copy of the app.
///
/// The menu and the window both go through here, so a failure is kept and shown
/// rather than swallowed. The state is read from disk only on `refresh()` and after
/// a change: the menu re-renders on every model change and must never do I/O.
@MainActor
@Observable
final class HookManager {
    enum State: Equatable {
        case notInstalled
        case installed
        /// Hooks are in place but run a helper somewhere else, usually because the app
        /// was moved or renamed after they were added.
        case elsewhere([String])
    }

    private var states: [AgentKind: State] = [:]
    private(set) var errors: [AgentKind: String] = [:]

    init() {
        refresh()
    }

    func state(for kind: AgentKind) -> State {
        states[kind] ?? .notInstalled
    }

    static func settingsPath(for kind: AgentKind) -> String {
        switch kind {
        case .claude: IslandPaths.claudeSettings
        case .codex: IslandPaths.codexHooks
        }
    }

    /// Adds the hooks, or repoints ones left behind by a moved app.
    @discardableResult
    func install(_ kind: AgentKind) -> Bool {
        perform(kind) {
            try HookInstaller.install(
                settingsPath: Self.settingsPath(for: kind),
                binaryPath: IslandSettings.hookBinaryPath,
                agent: kind
            )
        }
    }

    @discardableResult
    func uninstall(_ kind: AgentKind) -> Bool {
        perform(kind) {
            try HookInstaller.uninstall(settingsPath: Self.settingsPath(for: kind))
        }
    }

    /// Adds any events a newer version of the app listens for to hooks this copy
    /// already installed, so an update works without a trip to the Hooks pane. Hooks
    /// that were never added, or that run another copy of the app, are left alone.
    func updateInstalledHooks() {
        for kind in AgentKind.allCases where state(for: kind) == .installed {
            let missing = HookInstaller.missingEvents(settingsPath: Self.settingsPath(for: kind), agent: kind)
            guard !missing.isEmpty, install(kind) else { continue }
            NSLog("Agent Island: added \(kind.rawValue) hooks for \(missing.joined(separator: ", "))")
        }
    }

    /// Re-reads the settings files, which may have been edited by hand.
    func refresh() {
        for kind in AgentKind.allCases {
            let commands = HookInstaller.installedCommands(settingsPath: Self.settingsPath(for: kind))
            let state: State = if commands.isEmpty {
                .notInstalled
            } else if commands == [IslandSettings.hookBinaryPath] {
                .installed
            } else {
                .elsewhere(commands.sorted())
            }
            if states[kind] != state { states[kind] = state }
        }
    }

    private func perform(_ kind: AgentKind, _ change: () throws -> Void) -> Bool {
        defer { refresh() }
        do {
            try change()
            errors[kind] = nil
            return true
        } catch {
            errors[kind] = "\(error)"
            return false
        }
    }
}
