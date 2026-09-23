import Foundation

/// One of the questions Claude asks with AskUserQuestion.
public struct AgentQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The questions in an AskUserQuestion call's input, or nil if it has none.
    public static func parse(toolInput: Any?) -> [AgentQuestion]? {
        guard let entries = (toolInput as? [String: Any])?["questions"] as? [[String: Any]] else { return nil }
        let questions = entries.compactMap { entry -> AgentQuestion? in
            guard let text = entry["question"] as? String, !text.isEmpty else { return nil }
            let options = ((entry["options"] as? [[String: Any]]) ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String else { return nil }
                return Option(label: label, description: option["description"] as? String)
            }
            return AgentQuestion(
                question: text,
                header: entry["header"] as? String,
                options: options,
                multiSelect: (entry["multiSelect"] as? Bool) ?? false
            )
        }
        return questions.isEmpty ? nil : questions
    }
}

/// Something Claude is holding a turn for, which can be answered from the island.
public enum PendingAsk: Sendable, Equatable {
    /// AskUserQuestion: one to four questions, each with its options.
    case questions([AgentQuestion])
    /// ExitPlanMode: the plan, in Markdown, waiting to be approved.
    case plan(String)

    /// The ask a tool call makes, for the two tools that wait on the user.
    public static func parse(toolName: String?, toolInput: Any?) -> PendingAsk? {
        switch toolName {
        case "AskUserQuestion":
            return AgentQuestion.parse(toolInput: toolInput).map(PendingAsk.questions)
        case "ExitPlanMode":
            let plan = (toolInput as? [String: Any])?["plan"] as? String
            return .plan(plan ?? "")
        default:
            return nil
        }
    }
}

/// One line in a session's timeline: what was asked, what the agent said, and what
/// it did.
public struct ActivityItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Something the user typed.
        case prompt
        /// Something the agent wrote back.
        case reply
        /// A tool call.
        case tool
        /// A tool call that failed.
        case error
        /// Bookkeeping, like a compaction.
        case note
        /// Something sent from the island itself.
        case sent
    }

    public var kind: Kind
    public var text: String
    public var at: Date?

    public init(kind: Kind, text: String, at: Date? = nil) {
        self.kind = kind
        self.text = text
        self.at = at
    }

    /// Flattens and trims text for a one- or two-line row.
    public static func clip(_ text: String, _ limit: Int = 240) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "\u{2026}" : flat
    }
}

/// What the app sends back down a waiting hook's connection.
///
/// The helper prints the body and exits: a PermissionRequest decision goes to
/// stdout with status 0, and a message for the model goes to stderr with status 2,
/// which is what wakes an `asyncRewake` hook's session.
public enum HookReply: Sendable, Equatable {
    /// JSON for stdout.
    case decision(String)
    /// Text for stderr, with exit status 2.
    case wake(String)

    /// The first byte the app sends on a waiting connection, to say it will answer.
    /// A helper that does not hear it quickly gives up, so an app that is busy or
    /// not interested never holds an agent up.
    public static let holdByte = UInt8(ascii: "K")

    public var wire: Data {
        switch self {
        case .decision(let json): Data("O".utf8) + Data(json.utf8)
        case .wake(let text): Data("W".utf8) + Data(text.utf8)
        }
    }

    // MARK: Answers

    /// Answers AskUserQuestion: the call goes ahead with the user's answers filled
    /// in, keyed by question text, the way Claude's own question form does it.
    public static func answer(toolInput: Data, answers: [String: String]) -> HookReply? {
        guard var input = (try? JSONSerialization.jsonObject(with: toolInput)) as? [String: Any] else { return nil }
        input["answers"] = answers
        return allow(updatedInput: input)
    }

    /// Approves a plan. Claude then leaves plan mode for whatever mode it was in
    /// before, or for accept-edits when asked.
    public static func approvePlan(toolInput: Data, acceptEdits: Bool) -> HookReply? {
        guard let input = (try? JSONSerialization.jsonObject(with: toolInput)) as? [String: Any] else { return nil }
        let permissions: [[String: Any]]? = acceptEdits
            ? [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]
            : nil
        return allow(updatedInput: input, permissions: permissions)
    }

    /// Sends a plan back with the user's notes; Claude stays in plan mode.
    public static func revisePlan(feedback: String) -> HookReply {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "The user wants to keep planning before you start."
            : "The user wants changes to the plan before you start: \(trimmed)"
        return decision(["behavior": "deny", "message": message])
    }

    /// The user's next message, for a session that has finished its turn.
    public static func prompt(_ text: String) -> HookReply {
        .wake(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func allow(updatedInput: [String: Any], permissions: [[String: Any]]? = nil) -> HookReply {
        var decision: [String: Any] = ["behavior": "allow", "updatedInput": updatedInput]
        if let permissions { decision["updatedPermissions"] = permissions }
        return Self.decision(decision)
    }

    private static func decision(_ decision: [String: Any]) -> HookReply {
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return .decision(String(decoding: data, as: UTF8.self))
    }
}
