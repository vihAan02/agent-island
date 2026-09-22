import Foundation
import IslandCore
import Observation

/// User preferences, stored in the standard defaults for the app.
@MainActor
@Observable
final class IslandSettings {
    enum Visibility: String, CaseIterable, Identifiable {
        /// The circle stays out for as long as the agent is working. The default.
        case stayWhileWorking
        /// The circle pops out on a change, then tucks back into the notch.
        case popThenTuck

        var id: String { rawValue }
        var label: String {
            switch self {
            case .stayWhileWorking: "Stay out while working"
            case .popThenTuck: "Pop, then tuck back"
            }
        }
    }

    private let defaults = UserDefaults.standard

    var watchClaude: Bool {
        didSet { defaults.set(watchClaude, forKey: "watchClaude") }
    }
    var watchCodex: Bool {
        didSet { defaults.set(watchCodex, forKey: "watchCodex") }
    }
    var visibility: Visibility {
        didSet { defaults.set(visibility.rawValue, forKey: "visibility") }
    }
    /// How long a circle waits before tucking back, in "pop, then tuck" mode.
    var tuckAfter: TimeInterval {
        didSet { defaults.set(tuckAfter, forKey: "tuckAfter") }
    }
    var codexPetID: String {
        didSet { defaults.set(codexPetID, forKey: "codexPetID") }
    }

    init() {
        defaults.register(defaults: [
            "watchClaude": true,
            "watchCodex": true,
            "visibility": Visibility.stayWhileWorking.rawValue,
            "tuckAfter": 5.0,
        ])
        watchClaude = defaults.bool(forKey: "watchClaude")
        watchCodex = defaults.bool(forKey: "watchCodex")
        visibility = Visibility(rawValue: defaults.string(forKey: "visibility") ?? "")
            ?? .stayWhileWorking
        tuckAfter = defaults.double(forKey: "tuckAfter")
        codexPetID = defaults.string(forKey: "codexPetID") ?? PetCatalog.preferredPetID()
    }

    // MARK: - Hooks

    /// Path to the hook forwarder inside this bundle, or beside the executable when
    /// running straight out of `swift build`.
    static var hookBinaryPath: String {
        let executable = Bundle.main.executableURL?.deletingLastPathComponent()
        let sibling = executable?.appendingPathComponent("agent-island-hook").path
        if let sibling, FileManager.default.fileExists(atPath: sibling) { return sibling }
        return sibling ?? "agent-island-hook"
    }

    var claudeHooksInstalled: Bool {
        HookInstaller.isInstalled(settingsPath: IslandPaths.claudeSettings)
    }

    var codexHooksInstalled: Bool {
        HookInstaller.isInstalled(settingsPath: IslandPaths.codexHooks)
    }

    func installClaudeHooks() throws {
        try HookInstaller.install(
            settingsPath: IslandPaths.claudeSettings,
            binaryPath: Self.hookBinaryPath,
            agent: .claude
        )
    }

    func uninstallClaudeHooks() throws {
        try HookInstaller.uninstall(settingsPath: IslandPaths.claudeSettings)
    }

    func installCodexHooks() throws {
        try HookInstaller.install(
            settingsPath: IslandPaths.codexHooks,
            binaryPath: Self.hookBinaryPath,
            agent: .codex
        )
    }

    func uninstallCodexHooks() throws {
        try HookInstaller.uninstall(settingsPath: IslandPaths.codexHooks)
    }
}
