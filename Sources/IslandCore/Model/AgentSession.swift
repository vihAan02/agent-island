import Foundation

/// Which agent a session belongs to.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

/// Where the session is being driven from. Decides what a click on the circle opens.
public enum AgentHost: String, Codable, Sendable {
    case claudeDesktop
    case codexDesktop
    case terminal
    case unknown
}

/// The ring states from the plan.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    /// Discovered but has not run a turn yet. No circle is shown.
    case waiting
    case working
    /// Needs the user: AskUserQuestion, a permission prompt, an approval, request_user_input.
    case question
    /// Plan mode, or a plan is ready for review.
    case plan
    case error
    case complete
    /// Finished a while ago, or aborted. The circle dims before it retracts.
    case idle

    /// Statuses that are worth the user's attention, so the circle never auto-retracts.
    public var demandsAttention: Bool {
        self == .question || self == .error || self == .plan
    }

    /// Statuses that mean a circle belongs on screen.
    public var isOnStage: Bool {
        self != .waiting
    }
}

/// Effort tiers, unified across both agents.
///
/// Claude reports low/medium/high/xhigh/max, plus a separate ultracode flag that
/// means "xhigh + dynamic workflows". Codex reports minimal/low/medium/high/xhigh/ultra.
/// Both top tiers land on `.ultra`, which is the one that gets the aurora.
public enum EffortTier: String, Codable, Sendable, CaseIterable, Comparable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    public static func < (a: EffortTier, b: EffortTier) -> Bool {
        a.rank < b.rank
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .xhigh: 3
        case .max: 4
        case .ultra: 5
        }
    }

    /// Parses the level string either agent reports.
    public static func parse(_ raw: String?) -> EffortTier? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "minimal", "none", "low": return .low
        case "medium", "default": return .medium
        case "high": return .high
        case "xhigh", "extra_high", "extrahigh": return .xhigh
        case "max", "maximum": return .max
        case "ultra", "ultracode": return .ultra
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        case .max: "max"
        case .ultra: "ultra"
        }
    }
}

/// One live agent conversation.
public struct AgentSession: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: AgentKind
    public var host: AgentHost
    public var title: String
    public var cwd: String
    public var repo: String
    public var branch: String?
    public var pid: Int32?
    public var status: AgentStatus
    public var effort: EffortTier
    /// True for Claude ultracode and Codex ultra effort. Drives the aurora.
    public var isUltra: Bool
    /// The session is running in plan mode right now.
    public var planMode: Bool
    public var detail: String?
    public var transcriptPath: String?
    public var startedAt: Date
    public var statusChangedAt: Date
    public var lastActivity: Date
    /// Set when the session is gone and the circle should slide back into the notch.
    public var isRetiring: Bool
    /// When a one-off failure should stop tinting the ring red.
    public var flashRevertAt: Date?

    public init(
        id: String,
        kind: AgentKind,
        host: AgentHost = .unknown,
        title: String = "",
        cwd: String = "",
        branch: String? = nil,
        pid: Int32? = nil,
        status: AgentStatus = .waiting,
        effort: EffortTier = .medium,
        isUltra: Bool = false,
        planMode: Bool = false,
        detail: String? = nil,
        transcriptPath: String? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.host = host
        self.title = title
        self.cwd = cwd
        self.repo = AgentSession.repoName(for: cwd)
        self.branch = branch
        self.pid = pid
        self.status = status
        self.effort = effort
        self.isUltra = isUltra
        self.planMode = planMode
        self.detail = detail
        self.transcriptPath = transcriptPath
        self.startedAt = now
        self.statusChangedAt = now
        self.lastActivity = now
        self.isRetiring = false
        self.flashRevertAt = nil
    }

    public mutating func setCwd(_ path: String) {
        guard !path.isEmpty, path != cwd else { return }
        cwd = path
        repo = AgentSession.repoName(for: path)
    }

    /// The repository folder name, or the working directory's own name when it is not a repo.
    public static func repoName(for cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        let root = GitInfo.repositoryRoot(for: cwd) ?? cwd
        return (root as NSString).lastPathComponent
    }

    /// Title to show when the agent never named the chat.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if !repo.isEmpty { return repo }
        return kind == .claude ? "Claude Code" : "Codex"
    }

    /// The effort tier the ring should animate, folding the ultracode flag in.
    public var effectiveEffort: EffortTier {
        isUltra ? .ultra : effort
    }

    public var effortLabel: String {
        if isUltra { return kind == .claude ? "ultracode" : "ultra" }
        return effort.label
    }
}
