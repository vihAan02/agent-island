import Foundation

/// Everything the watchers and the hook socket feed into the store.
public enum AgentEvent: Sendable {
    case hook(HookEvent)
    /// The full contents of `~/.claude/sessions`, after each change.
    case claudeRegistry([ClaudeRegistryEntry])
    case claudeTranscript(sessionID: String, signal: TranscriptSignal)
    case codex(CodexEvent)

    /// Which agent the event is about.
    public var kind: AgentKind {
        switch self {
        case .hook(let hook): hook.kind
        case .claudeRegistry, .claudeTranscript: .claude
        case .codex: .codex
        }
    }
}

/// A signal read out of a Claude transcript. Used when hooks are not installed,
/// and for the per-turn effort level, which the registry does not carry.
public enum TranscriptSignal: Sendable, Equatable {
    case effort(EffortTier)
    case askingQuestion(String?)
    case planReady
    case apiError(String?)
    case assistantActivity
    /// Claude's permission mode, which every user line in the transcript carries.
    case permissionMode(String)
}

/// One decoded hook payload, from Claude Code or from Codex. Both use the same schema.
public struct HookEvent: Sendable, Equatable {
    public enum Name: String, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case permissionRequest = "PermissionRequest"
        case permissionDenied = "PermissionDenied"
        case notification = "Notification"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case interrupt = "Interrupt"
        case sessionEnd = "SessionEnd"
    }

    public var kind: AgentKind
    public var name: Name
    public var sessionID: String
    public var cwd: String
    public var transcriptPath: String?
    public var permissionMode: String?
    public var effort: EffortTier?
    public var toolName: String?
    /// A short, human readable summary of the tool call, e.g. `Bash(npm test)`.
    public var toolSummary: String?
    public var message: String?
    public var notificationType: String?
    public var errorText: String?
    public var isInterrupt: Bool
    /// Present only when the hook fires inside a subagent.
    public var agentID: String?
    public var env: [String: String]
    public var receivedAt: Date

    public init(
        kind: AgentKind,
        name: Name,
        sessionID: String,
        cwd: String = "",
        transcriptPath: String? = nil,
        permissionMode: String? = nil,
        effort: EffortTier? = nil,
        toolName: String? = nil,
        toolSummary: String? = nil,
        message: String? = nil,
        notificationType: String? = nil,
        errorText: String? = nil,
        isInterrupt: Bool = false,
        agentID: String? = nil,
        env: [String: String] = [:],
        receivedAt: Date = Date()
    ) {
        self.kind = kind
        self.name = name
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.permissionMode = permissionMode
        self.effort = effort
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.message = message
        self.notificationType = notificationType
        self.errorText = errorText
        self.isInterrupt = isInterrupt
        self.agentID = agentID
        self.env = env
        self.receivedAt = receivedAt
    }

    /// Decodes the envelope written by `agent-island-hook`:
    /// `{"agent":"claude","env":{...},"payload":{...hook input...}}`
    public static func decode(envelope data: Data, now: Date = Date()) -> HookEvent? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let payload = root["payload"] as? [String: Any],
            let rawName = payload["hook_event_name"] as? String,
            let name = Name(rawValue: rawName)
        else { return nil }

        let kind = AgentKind(rawValue: (root["agent"] as? String) ?? "claude") ?? .claude
        let env = (root["env"] as? [String: String]) ?? [:]
        let sessionID = (payload["session_id"] as? String) ?? ""
        guard !sessionID.isEmpty else { return nil }

        var effort = EffortTier.parse((payload["effort"] as? [String: Any])?["level"] as? String)
        // Only Claude sets this. A Codex run started from a Claude Code shell inherits it,
        // and it says nothing about Codex's own effort.
        if effort == nil, kind == .claude { effort = EffortTier.parse(env["CLAUDE_EFFORT"]) }

        let toolName = payload["tool_name"] as? String
        let toolSummary = ToolSummary.describe(toolName: toolName, toolInput: payload["tool_input"])

        return HookEvent(
            kind: kind,
            name: name,
            sessionID: sessionID,
            cwd: (payload["cwd"] as? String) ?? "",
            transcriptPath: payload["transcript_path"] as? String,
            permissionMode: payload["permission_mode"] as? String,
            effort: effort,
            toolName: toolName,
            toolSummary: toolSummary,
            message: payload["message"] as? String,
            notificationType: payload["notification_type"] as? String,
            errorText: (payload["error"] as? String) ?? (payload["error_details"] as? String),
            isInterrupt: (payload["is_interrupt"] as? Bool) ?? false,
            agentID: payload["agent_id"] as? String,
            env: env,
            receivedAt: now
        )
    }
}

/// Turns a tool call into a short line for the hover pill.
public enum ToolSummary {
    public static func describe(toolName: String?, toolInput: Any?) -> String? {
        guard let toolName, !toolName.isEmpty else { return nil }
        let input = toolInput as? [String: Any] ?? [:]

        func trim(_ text: String, _ limit: Int = 48) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "\u{2026}" : flat
        }

        switch toolName {
        case "Bash":
            if let command = input["command"] as? String { return "Bash(\(trim(command)))" }
        case "Read", "Edit", "Write", "NotebookEdit":
            if let path = input["file_path"] as? String {
                return "\(toolName)(\((path as NSString).lastPathComponent))"
            }
        case "Glob", "Grep":
            if let pattern = input["pattern"] as? String { return "\(toolName)(\(trim(pattern, 28)))" }
        case "WebFetch":
            if let url = input["url"] as? String { return "WebFetch(\(trim(url, 32)))" }
        case "Task", "Agent":
            if let description = input["description"] as? String { return trim(description) }
        case "AskUserQuestion":
            if let questions = input["questions"] as? [[String: Any]],
               let first = questions.first,
               let question = (first["question"] as? String) ?? (first["header"] as? String) {
                return trim(question, 60)
            }
        case "ExitPlanMode":
            return "Plan ready for review"
        default:
            break
        }

        // Codex tool calls, and anything else with a command-ish field.
        for key in ["command", "cmd", "input", "prompt", "path"] {
            if let value = input[key] as? String { return "\(toolName)(\(trim(value)))" }
        }
        return toolName
    }
}
