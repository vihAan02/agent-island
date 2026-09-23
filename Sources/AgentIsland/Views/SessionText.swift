import Foundation
import IslandCore

/// The words the hover card and the window use for a session.
extension AgentSession {
    /// One line on what the agent is doing right now.
    var statusLine: String {
        if let detail, !detail.isEmpty { return detail }
        switch status {
        case .working: return "Working\u{2026}"
        case .question: return "Waiting for you"
        case .plan: return planMode ? "Planning" : "Plan ready for review"
        case .error: return "Something failed"
        case .complete: return "Done"
        case .idle: return "Idle"
        case .waiting: return "Ready"
        }
    }

    /// How long it has been in its current status, in the largest whole unit.
    func elapsedText(now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(statusChangedAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    /// Where the chat is running, or nil when that is not known.
    var hostLabel: String? {
        switch host {
        case .claudeDesktop: "Claude app"
        case .codexDesktop: "Codex"
        case .terminal: "Terminal"
        case .unknown: nil
        }
    }
}
