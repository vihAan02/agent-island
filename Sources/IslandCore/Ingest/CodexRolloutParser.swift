import Foundation

/// Turns the lines of one Codex rollout file into events.
///
/// Kept separate from the watcher so the mapping can be tested against real
/// rollout lines without touching the file system.
public struct CodexRolloutParser: Sendable {
    /// Thread this file belongs to, once its `session_meta` line has been read.
    public private(set) var threadID: String?
    /// Subagent rollouts are ignored: their work rolls up into the parent thread.
    public private(set) var isSubagent = false
    private var pendingUserInput: Set<String> = []

    /// Filename fallback for the thread id, used when `session_meta` has none.
    private let fallbackThreadID: String?

    public init(fallbackThreadID: String? = nil) {
        self.fallbackThreadID = fallbackThreadID
    }

    /// Events for one JSONL line. Returns nothing for lines that do not matter.
    public mutating func events(for line: Data, now: Date = Date()) -> [CodexEvent] {
        guard
            !isSubagent,
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let type = object["type"] as? String,
            let payload = object["payload"] as? [String: Any]
        else { return [] }

        let at = Self.timestamp(object["timestamp"] as? String) ?? now

        switch type {
        case "session_meta":
            if payload["parent_thread_id"] as? String != nil {
                isSubagent = true
                return []
            }
            guard let id = (payload["id"] as? String) ?? fallbackThreadID else { return [] }
            threadID = id
            return [CodexEvent(
                threadID: id,
                kind: .discovered(cwd: (payload["cwd"] as? String) ?? "", title: nil),
                at: at
            )]

        case "turn_context":
            guard let threadID else { return [] }
            let mode = (payload["collaboration_mode"] as? [String: Any])?["mode"] as? String
            return [CodexEvent(
                threadID: threadID,
                kind: .turnContext(
                    effort: EffortTier.parse(payload["effort"] as? String),
                    planMode: mode?.lowercased() == "plan"
                ),
                at: at
            )]

        case "event_msg":
            guard let threadID, let kind = payload["type"] as? String else { return [] }
            switch kind {
            case "task_started":
                return [CodexEvent(threadID: threadID, kind: .taskStarted, at: at)]
            case "task_complete":
                return [CodexEvent(threadID: threadID, kind: .taskComplete, at: at)]
            case "turn_aborted":
                return [CodexEvent(threadID: threadID, kind: .turnAborted, at: at)]
            case "stream_error", "error":
                return [CodexEvent(
                    threadID: threadID,
                    kind: .streamError(payload["message"] as? String),
                    at: at
                )]
            case "exec_approval_request":
                let command = (payload["command"] as? [String])?.joined(separator: " ")
                    ?? (payload["command"] as? String)
                return [CodexEvent(threadID: threadID, kind: .approvalRequest(command), at: at)]
            case "apply_patch_approval_request":
                return [CodexEvent(threadID: threadID, kind: .approvalRequest("apply patch"), at: at)]
            case "item_completed":
                return [CodexEvent(threadID: threadID, kind: .activity, at: at)]
            default:
                return []
            }

        case "response_item":
            guard let threadID else { return [] }
            let itemType = payload["type"] as? String
            if itemType == "function_call", (payload["name"] as? String) == "request_user_input" {
                if let callID = payload["call_id"] as? String { pendingUserInput.insert(callID) }
                return [CodexEvent(
                    threadID: threadID,
                    kind: .userInputRequest("Waiting on your answer"),
                    at: at
                )]
            }
            if itemType == "function_call_output",
               let callID = payload["call_id"] as? String,
               pendingUserInput.remove(callID) != nil {
                return [CodexEvent(threadID: threadID, kind: .activity, at: at)]
            }
            return []

        default:
            return []
        }
    }

    /// `rollout-2026-09-17T11-47-51-<uuid>.jsonl`
    public static func threadID(fromFileName path: String) -> String? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let parts = name.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let uuid = parts.suffix(5).joined(separator: "-")
        return uuid.count == 36 ? uuid : nil
    }

    static func timestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
