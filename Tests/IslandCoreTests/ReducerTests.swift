import Foundation
import Testing

@testable import IslandCore

@Suite("Session reducer")
struct ReducerTests {
    private func hook(
        _ name: HookEvent.Name,
        session: String = "s1",
        kind: AgentKind = .claude,
        tool: String? = nil,
        summary: String? = nil,
        permissionMode: String? = nil,
        effort: EffortTier? = nil,
        isInterrupt: Bool = false,
        notification: String? = nil
    ) -> AgentEvent {
        .hook(HookEvent(
            kind: kind,
            name: name,
            sessionID: session,
            cwd: "/tmp/repo",
            permissionMode: permissionMode,
            effort: effort,
            toolName: tool,
            toolSummary: summary,
            notificationType: notification,
            isInterrupt: isInterrupt
        ))
    }

    @Test("A Claude turn walks working → question → working → complete")
    func claudeTurn() {
        var reducer = SessionReducer()
        let id = SessionReducer.claudeID("s1")

        reducer.apply(hook(.sessionStart))
        #expect(reducer.session(id: id)?.status == .waiting)
        #expect(reducer.visibleSessions.isEmpty, "an idle session gets no circle")

        reducer.apply(hook(.userPromptSubmit, effort: .xhigh))
        #expect(reducer.session(id: id)?.status == .working)
        #expect(reducer.session(id: id)?.effort == .xhigh)
        #expect(reducer.visibleSessions.count == 1)

        reducer.apply(hook(.permissionRequest, tool: "Bash", summary: "Bash(swift test)"))
        #expect(reducer.session(id: id)?.status == .question)
        #expect(reducer.session(id: id)?.detail == "Needs approval: Bash(swift test)")

        reducer.apply(hook(.postToolUse, tool: "Bash"))
        #expect(reducer.session(id: id)?.status == .working)

        reducer.apply(hook(.stop))
        #expect(reducer.session(id: id)?.status == .complete)
    }

    @Test("Plan mode and ExitPlanMode both read as plan")
    func planStates() {
        var reducer = SessionReducer()
        let id = SessionReducer.claudeID("s1")

        reducer.apply(hook(.userPromptSubmit, permissionMode: "plan"))
        #expect(reducer.session(id: id)?.status == .plan)
        #expect(reducer.session(id: id)?.planMode == true)

        var other = SessionReducer()
        other.apply(hook(.userPromptSubmit, session: "s2"))
        other.apply(hook(.preToolUse, session: "s2", tool: "ExitPlanMode"))
        #expect(other.session(id: SessionReducer.claudeID("s2"))?.status == .plan)
    }

    @Test("A failed tool flashes red and then goes back to working")
    func errorFlash() {
        var reducer = SessionReducer()
        let id = SessionReducer.claudeID("s1")
        let start = Date()

        reducer.apply(hook(.userPromptSubmit), now: start)
        reducer.apply(hook(.postToolUseFailure, tool: "Bash", summary: "Bash(exit 1)"), now: start)
        #expect(reducer.session(id: id)?.status == .error)

        reducer.tick(now: start.addingTimeInterval(3))
        #expect(reducer.session(id: id)?.status == .working)
    }

    @Test("An interrupt is not an error")
    func interruptIsNotError() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit))
        reducer.apply(hook(.postToolUseFailure, tool: "Bash", isInterrupt: true))
        #expect(reducer.session(id: SessionReducer.claudeID("s1"))?.status == .working)
    }

    @Test("A permission notification counts as a question")
    func permissionNotification() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit))
        reducer.apply(hook(.notification, notification: "permission_prompt"))
        #expect(reducer.session(id: SessionReducer.claudeID("s1"))?.status == .question)
    }

    @Test("SessionEnd retires the circle")
    func sessionEndRetires() {
        var reducer = SessionReducer()
        let id = SessionReducer.claudeID("s1")
        reducer.apply(hook(.userPromptSubmit))
        reducer.apply(hook(.sessionEnd))
        #expect(reducer.session(id: id)?.isRetiring == true)

        reducer.drop(id: id)
        #expect(reducer.session(id: id) == nil)
        #expect(reducer.order.isEmpty)
    }

    @Test("Without hooks, the registry's busy/idle drives status")
    func registryDrivesStatusWithoutHooks() {
        var reducer = SessionReducer()
        let id = SessionReducer.claudeID("s9")
        let entry = ClaudeRegistryEntry(
            pid: 42, sessionID: "s9", cwd: "/tmp/repo", name: "Fix the parser",
            status: "busy", entrypoint: "claude-desktop", effort: .high, isUltra: true
        )

        reducer.apply(.claudeRegistry([entry]))
        #expect(reducer.session(id: id)?.status == .working)
        #expect(reducer.session(id: id)?.title == "Fix the parser")
        #expect(reducer.session(id: id)?.isUltra == true)
        #expect(reducer.session(id: id)?.effectiveEffort == .ultra)

        var idle = entry
        idle.status = "idle"
        reducer.apply(.claudeRegistry([idle]))
        #expect(reducer.session(id: id)?.status == .complete)
    }

    @Test("With hooks, the registry does not overwrite a question")
    func hooksWinOverRegistry() {
        var reducer = SessionReducer()
        let id = SessionReducer.claudeID("s1")
        reducer.apply(hook(.userPromptSubmit))
        reducer.apply(hook(.permissionRequest, tool: "Bash", summary: "Bash(rm -rf)"))

        let entry = ClaudeRegistryEntry(pid: 7, sessionID: "s1", cwd: "/tmp/repo", status: "idle")
        reducer.apply(.claudeRegistry([entry]))
        #expect(reducer.session(id: id)?.status == .question)
        #expect(reducer.session(id: id)?.pid == 7)
    }

    @Test("A dead process retires its circle")
    func deadProcessRetires() {
        var reducer = SessionReducer()
        let id = SessionReducer.claudeID("s1")
        reducer.apply(hook(.userPromptSubmit))

        var entry = ClaudeRegistryEntry(pid: 7, sessionID: "s1", cwd: "/tmp/repo", status: "busy")
        entry.isAlive = false
        reducer.apply(.claudeRegistry([entry]))
        #expect(reducer.session(id: id)?.isRetiring == true)
    }

    @Test("A session vanishing from the registry retires, but one it never listed stays")
    func registryOnlyRetiresWhatItListed() {
        var reducer = SessionReducer()
        let listed = SessionReducer.claudeID("s1")
        let hookOnly = SessionReducer.claudeID("headless")

        reducer.apply(hook(.userPromptSubmit))
        reducer.apply(hook(.userPromptSubmit, session: "headless"))
        reducer.apply(.claudeRegistry([
            ClaudeRegistryEntry(pid: 7, sessionID: "s1", cwd: "/tmp/repo", status: "busy"),
        ]))
        #expect(reducer.session(id: hookOnly)?.isRetiring == false, "never in the registry, so not gone from it")

        reducer.apply(.claudeRegistry([]))
        #expect(reducer.session(id: listed)?.isRetiring == true)
        #expect(reducer.session(id: hookOnly)?.isRetiring == false)
    }

    @Test("Codex events map onto the same statuses")
    func codexFlow() {
        var reducer = SessionReducer()
        let id = SessionReducer.codexID("t1")

        reducer.apply(.codex(CodexEvent(threadID: "t1", kind: .discovered(cwd: "/tmp/ocr", title: "Review notebook"))))
        reducer.apply(.codex(CodexEvent(threadID: "t1", kind: .turnContext(effort: .ultra, planMode: false))))
        reducer.apply(.codex(CodexEvent(threadID: "t1", kind: .taskStarted)))
        #expect(reducer.session(id: id)?.status == .working)
        #expect(reducer.session(id: id)?.isUltra == true)
        #expect(reducer.session(id: id)?.title == "Review notebook")

        reducer.apply(.codex(CodexEvent(threadID: "t1", kind: .approvalRequest("rm -rf /"))))
        #expect(reducer.session(id: id)?.status == .question)

        reducer.apply(.codex(CodexEvent(threadID: "t1", kind: .taskComplete)))
        #expect(reducer.session(id: id)?.status == .complete)

        reducer.apply(.codex(CodexEvent(threadID: "t1", kind: .streamError("disconnected"))))
        #expect(reducer.session(id: id)?.status == .error)
    }

    @Test("A finished session retires after its grace period")
    func completedSessionsRetire() {
        var reducer = SessionReducer()
        reducer.retireCompletedAfter = 60
        let id = SessionReducer.claudeID("s1")
        let start = Date()

        reducer.apply(hook(.userPromptSubmit), now: start)
        reducer.apply(hook(.stop), now: start)

        reducer.tick(now: start.addingTimeInterval(30))
        #expect(reducer.session(id: id)?.isRetiring == false)

        let retired = reducer.tick(now: start.addingTimeInterval(90))
        #expect(retired == [id])
        #expect(reducer.session(id: id)?.isRetiring == true)
    }

    @Test("Slot order is stable as sessions come and go")
    func slotOrderStable() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit, session: "a"))
        reducer.apply(hook(.userPromptSubmit, session: "b"))
        reducer.drop(id: SessionReducer.claudeID("a"))
        reducer.apply(hook(.userPromptSubmit, session: "c"))

        #expect(reducer.order == [
            SessionReducer.claudeID("b"),
            SessionReducer.claudeID("c"),
        ])
    }
}
