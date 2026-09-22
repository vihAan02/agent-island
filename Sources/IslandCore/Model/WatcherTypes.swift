import Foundation

/// One entry of `~/.claude/sessions/<pid>.json`, plus what the process arguments tell us.
public struct ClaudeRegistryEntry: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var sessionID: String
    public var cwd: String
    public var name: String?
    /// `busy`, `idle`, and whatever else the CLI writes.
    public var status: String
    /// `claude-desktop`, `cli`, and so on.
    public var entrypoint: String?
    public var kind: String?
    public var statusUpdatedAt: Date?
    public var effort: EffortTier?
    public var isUltra: Bool
    public var isAlive: Bool

    public var id: String { sessionID }

    public init(
        pid: Int32,
        sessionID: String,
        cwd: String,
        name: String? = nil,
        status: String = "",
        entrypoint: String? = nil,
        kind: String? = nil,
        statusUpdatedAt: Date? = nil,
        effort: EffortTier? = nil,
        isUltra: Bool = false,
        isAlive: Bool = true
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.status = status
        self.entrypoint = entrypoint
        self.kind = kind
        self.statusUpdatedAt = statusUpdatedAt
        self.effort = effort
        self.isUltra = isUltra
        self.isAlive = isAlive
    }

    public var host: AgentHost {
        switch entrypoint {
        case "claude-desktop": .claudeDesktop
        case .some(let value) where value.contains("cli"): .terminal
        default: .terminal
        }
    }

    /// Decodes one registry file. Returns nil for the `.key` files and anything malformed.
    public static func decode(_ data: Data) -> ClaudeRegistryEntry? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let sessionID = object["sessionId"] as? String,
            let pid = object["pid"] as? Int
        else { return nil }

        let statusMillis = object["statusUpdatedAt"] as? Double
        return ClaudeRegistryEntry(
            pid: Int32(pid),
            sessionID: sessionID,
            cwd: (object["cwd"] as? String) ?? "",
            name: object["name"] as? String,
            status: (object["status"] as? String) ?? "",
            entrypoint: object["entrypoint"] as? String,
            kind: object["kind"] as? String,
            statusUpdatedAt: statusMillis.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}

/// Something that happened in a Codex thread, read out of its rollout file.
public struct CodexEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case discovered(cwd: String, title: String?)
        case turnContext(effort: EffortTier?, planMode: Bool)
        case taskStarted
        case taskComplete
        case turnAborted
        /// An exec or patch approval the user has to answer.
        case approvalRequest(String?)
        /// The `request_user_input` tool.
        case userInputRequest(String?)
        case streamError(String?)
        case activity
    }

    public var threadID: String
    public var kind: Kind
    public var at: Date

    public init(threadID: String, kind: Kind, at: Date = Date()) {
        self.threadID = threadID
        self.kind = kind
        self.at = at
    }
}
