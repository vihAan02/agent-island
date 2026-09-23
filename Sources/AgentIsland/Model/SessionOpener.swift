import AppKit
import Foundation
import IslandCore

/// Opens the chat a circle stands for.
///
/// Both desktop apps register a URL scheme: Claude takes
/// `claude://code/continue?session=local_<uuid>` and Codex takes `codex://threads/<id>`.
/// A terminal session has no link, so the terminal app that owns it is brought forward.
enum SessionOpener {
    static func claudeLink(for session: AgentSession) -> URL? {
        session.claudeAppLink
    }

    static func open(_ session: AgentSession) {
        switch session.host {
        case .claudeDesktop:
            if let url = claudeLink(for: session) {
                NSWorkspace.shared.open(url)
                return
            }
        case .codexDesktop:
            let threadID = String(session.id.dropFirst("codex:".count))
            if let url = URL(string: "codex://threads/\(threadID)") {
                NSWorkspace.shared.open(url)
                return
            }
        case .terminal, .unknown:
            break
        }
        activateOwningApp(of: session)
    }

    /// Walks up the parent chain until it hits a process that owns a visible app.
    private static func activateOwningApp(of session: AgentSession) {
        guard let pid = session.pid else { return }
        let running = NSWorkspace.shared.runningApplications
        var current: Int32? = pid
        var depth = 0

        while let candidate = current, depth < 8 {
            if let app = running.first(where: { $0.processIdentifier == candidate }) {
                app.activate(options: [])
                return
            }
            current = ProcessArgs.parentPID(of: candidate)
            depth += 1
        }

        // Nothing matched, so fall back to the app that usually hosts that agent.
        let fallback = session.kind == .claude ? "/Applications/Claude.app" : IslandPaths.chatGPTApp
        if FileManager.default.fileExists(atPath: fallback) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: fallback),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }
}
