import Foundation
import IslandCore

/// Fake sessions for `--demo`, so the animations can be tuned without live agents.
///
/// The script walks every status and every effort tier, including ultra, and then
/// starts over.
final class DemoDriver: @unchecked Sendable {
    private var task: Task<Void, Never>?

    struct Step {
        var after: Duration
        var event: AgentEvent
    }

    func start(emit: @escaping @Sendable (AgentEvent) -> Void) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                for step in Self.script() {
                    try? await Task.sleep(for: step.after)
                    if Task.isCancelled { return }
                    emit(step.event)
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stop() { task?.cancel() }

    // MARK: - Script

    private static func claude(
        _ session: String,
        _ name: HookEvent.Name,
        effort: EffortTier = .xhigh,
        tool: String? = nil,
        summary: String? = nil,
        planMode: Bool = false,
        error: String? = nil
    ) -> AgentEvent {
        .hook(
            HookEvent(
                kind: .claude,
                name: name,
                sessionID: session,
                cwd: FileManager.default.currentDirectoryPath,
                permissionMode: planMode ? "plan" : "default",
                effort: effort,
                toolName: tool,
                toolSummary: summary,
                errorText: error,
                env: ["__CFBundleIdentifier": "com.anthropic.claudefordesktop"]
            )
        )
    }

    private static func codex(_ thread: String, _ kind: CodexEvent.Kind) -> AgentEvent {
        .codex(CodexEvent(threadID: thread, kind: kind))
    }

    private static func script() -> [Step] {
        let one = "demo-claude-ultra"
        let two = "demo-codex-ultra"
        let three = "demo-claude-low"
        let four = "demo-codex-high"

        return [
            // A Claude session on ultracode starts working.
            Step(after: .seconds(1), event: claude(one, .sessionStart)),
            Step(after: .milliseconds(100), event: .claudeRegistry([
                ClaudeRegistryEntry(
                    pid: 1, sessionID: one, cwd: FileManager.default.currentDirectoryPath,
                    name: "Refactor the liquid layer", status: "busy",
                    entrypoint: "claude-desktop", effort: .xhigh, isUltra: true
                ),
            ])),
            Step(after: .milliseconds(200), event: claude(one, .userPromptSubmit)),

            // A Codex thread on ultra joins on the other side.
            Step(after: .seconds(2), event: codex(two, .discovered(cwd: "/Users/demo/f1-ml-model", title: "Choose F1 prediction model"))),
            Step(after: .milliseconds(100), event: codex(two, .turnContext(effort: .ultra, planMode: false))),
            Step(after: .milliseconds(100), event: codex(two, .taskStarted)),

            // A third, low effort.
            Step(after: .seconds(2), event: claude(three, .sessionStart, effort: .low)),
            Step(after: .milliseconds(100), event: .claudeRegistry([
                ClaudeRegistryEntry(
                    pid: 1, sessionID: one, cwd: FileManager.default.currentDirectoryPath,
                    name: "Refactor the liquid layer", status: "busy",
                    entrypoint: "claude-desktop", effort: .xhigh, isUltra: true
                ),
                ClaudeRegistryEntry(
                    pid: 2, sessionID: three, cwd: "/Users/demo/uw-go",
                    name: "Fix flaky test", status: "busy", entrypoint: "cli", effort: .low
                ),
            ])),
            Step(after: .milliseconds(100), event: claude(three, .userPromptSubmit, effort: .low)),

            // And a fourth.
            Step(after: .seconds(2), event: codex(four, .discovered(cwd: "/Users/demo/ocr", title: "Review notebook"))),
            Step(after: .milliseconds(100), event: codex(four, .turnContext(effort: .high, planMode: false))),
            Step(after: .milliseconds(100), event: codex(four, .taskStarted)),

            // Now walk the statuses.
            Step(after: .seconds(4), event: claude(one, .permissionRequest, tool: "Bash", summary: "Bash(swift test)")),
            Step(after: .seconds(4), event: claude(one, .postToolUse, tool: "Bash")),
            Step(after: .seconds(3), event: codex(two, .streamError("stream disconnected"))),
            Step(after: .seconds(3), event: codex(two, .taskStarted)),
            Step(after: .seconds(3), event: claude(three, .preToolUse, effort: .low, tool: "ExitPlanMode")),
            Step(after: .seconds(4), event: codex(four, .userInputRequest("Which dataset should I use?"))),
            Step(after: .seconds(4), event: claude(one, .stop)),
            Step(after: .seconds(2), event: codex(two, .taskComplete)),
            Step(after: .seconds(3), event: claude(three, .stopFailure, effort: .low, error: "API error 529")),

            // Tear the demo down so the retract animation plays, then start over.
            Step(after: .seconds(6), event: claude(one, .sessionEnd)),
            Step(after: .milliseconds(600), event: codex(two, .turnAborted)),
            Step(after: .milliseconds(600), event: claude(three, .sessionEnd)),
            Step(after: .milliseconds(600), event: .claudeRegistry([])),
        ]
    }
}
