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

    /// Called when a Watch toggle flips, so the model can start or stop that agent's
    /// watchers without a relaunch.
    @ObservationIgnored var onWatchChanged: ((AgentKind, Bool) -> Void)?

    var watchClaude: Bool {
        didSet {
            defaults.set(watchClaude, forKey: "watchClaude")
            if watchClaude != oldValue { onWatchChanged?(.claude, watchClaude) }
        }
    }
    var watchCodex: Bool {
        didSet {
            defaults.set(watchCodex, forKey: "watchCodex")
            if watchCodex != oldValue { onWatchChanged?(.codex, watchCodex) }
        }
    }

    func isWatching(_ kind: AgentKind) -> Bool {
        switch kind {
        case .claude: watchClaude
        case .codex: watchCodex
        }
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
    /// Which side of the notch new circles appear on. Any circle can be dragged across.
    var newCircleSide: IslandSide {
        didSet { defaults.set(newCircleSide.rawValue, forKey: "newCircleSide") }
    }
    /// A message typed on a card is pasted into its chat in the Claude app, then sent
    /// with Return. Off, it is only pasted, to send from there.
    var pasteSends: Bool {
        didSet { defaults.set(pasteSends, forKey: "pasteSends") }
    }

    init() {
        defaults.register(defaults: [
            "watchClaude": true,
            "watchCodex": true,
            "visibility": Visibility.stayWhileWorking.rawValue,
            "tuckAfter": 5.0,
            "newCircleSide": IslandSide.left.rawValue,
            "pasteSends": true,
        ])
        watchClaude = defaults.bool(forKey: "watchClaude")
        watchCodex = defaults.bool(forKey: "watchCodex")
        visibility = Visibility(rawValue: defaults.string(forKey: "visibility") ?? "")
            ?? .stayWhileWorking
        tuckAfter = defaults.double(forKey: "tuckAfter")
        codexPetID = defaults.string(forKey: "codexPetID") ?? PetCatalog.preferredPetID()
        newCircleSide = IslandSide(rawValue: defaults.string(forKey: "newCircleSide") ?? "") ?? .left
        pasteSends = defaults.bool(forKey: "pasteSends")
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
}
