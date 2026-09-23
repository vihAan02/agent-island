import Foundation
import Testing

@testable import IslandCore

@Suite("Slash commands")
struct CommandTests {
    private let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
    private let id = SessionReducer.claudeID("s1")

    private func hook(
        _ name: HookEvent.Name,
        command: String? = nil,
        trigger: String? = nil,
        tool: String? = nil,
        agentID: String? = nil
    ) -> AgentEvent {
        .hook(HookEvent(
            kind: .claude,
            name: name,
            sessionID: "s1",
            cwd: "/tmp/repo",
            toolName: tool,
            commandName: command,
            trigger: trigger,
            agentID: agentID
        ))
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("A prompt names the command it runs, and a path is not a command")
    func commandNames() {
        #expect(SlashCommand.name(fromPrompt: "/compact") == "compact")
        #expect(SlashCommand.name(fromPrompt: "/review 12") == "review")
        #expect(SlashCommand.name(fromPrompt: "/hello\nand more") == "hello")
        #expect(SlashCommand.name(fromPrompt: "/my-plugin:deploy staging") == "my-plugin:deploy")
        #expect(SlashCommand.name(fromPrompt: "/Users/me/app.swift is broken") == nil)
        #expect(SlashCommand.name(fromPrompt: "fix /compact") == nil)
        #expect(SlashCommand.name(fromPrompt: "/") == nil)
        #expect(SlashCommand.name(fromPrompt: "/ hello") == nil)
        #expect(SlashCommand.name(fromPrompt: nil) == nil)
    }

    @Test("Hook payloads carry the command and what started a compaction")
    func decodesCommandHooks() throws {
        let expansion = """
            {"agent":"claude","env":{},"payload":{"hook_event_name":"UserPromptExpansion","session_id":"s",
             "expansion_type":"slash_command","command_name":"hello","command_args":"there","prompt":"/hello there"}}
            """
        #expect(try #require(HookEvent.decode(envelope: Data(expansion.utf8))).commandName == "hello")

        let submit = """
            {"agent":"claude","env":{},"payload":{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"/hello there"}}
            """
        #expect(try #require(HookEvent.decode(envelope: Data(submit.utf8))).commandName == "hello")

        let plain = """
            {"agent":"claude","env":{},"payload":{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"fix it"}}
            """
        #expect(try #require(HookEvent.decode(envelope: Data(plain.utf8))).commandName == nil)

        let compact = """
            {"agent":"claude","env":{},"payload":{"hook_event_name":"PreCompact","session_id":"s",
             "trigger":"manual","custom_instructions":null}}
            """
        let event = try #require(HookEvent.decode(envelope: Data(compact.utf8)))
        #expect(event.name == .preCompact)
        #expect(event.trigger == "manual")
    }

    @Test("/compact at an idle prompt spins, then lands as done")
    func manualCompact() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit), now: at(0))
        reducer.apply(hook(.stop), now: at(5))

        reducer.apply(hook(.preCompact, trigger: "manual"), now: at(60))
        let compacting = reducer.session(id: id)
        #expect(compacting?.status == .working)
        #expect(compacting?.command?.name == "compact")
        #expect(compacting?.isRunningCommand == true)

        reducer.apply(hook(.postCompact, trigger: "manual"), now: at(150))
        let done = reducer.session(id: id)
        #expect(done?.command == nil)
        #expect(done?.status == .complete)
        #expect(done?.statusChangedAt == at(150), "the circle celebrates the compaction")
    }

    @Test("/compact brings out a session that never had a circle")
    func compactFromAFreshSession() {
        var reducer = SessionReducer()
        reducer.apply(hook(.sessionStart), now: at(0))
        #expect(reducer.visibleSessions.isEmpty)

        reducer.apply(hook(.preCompact, trigger: "manual"), now: at(1))
        #expect(reducer.visibleSessions.first?.isRunningCommand == true)
    }

    @Test("Compacting on its own mid-turn spins, then goes back to work")
    func autoCompact() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit), now: at(0))
        reducer.apply(hook(.preCompact, trigger: "auto"), now: at(30))
        #expect(reducer.session(id: id)?.isRunningCommand == true)

        reducer.apply(hook(.postCompact, trigger: "auto"), now: at(90))
        let after = reducer.session(id: id)
        #expect(after?.command == nil)
        #expect(after?.status == .working, "the turn carries on")
    }

    @Test("A command that expands into a prompt spins for its whole turn, and a question still shows")
    func promptCommand() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptExpansion, command: "review"), now: at(0))
        reducer.apply(hook(.userPromptSubmit, command: "review"), now: at(0.1))
        #expect(reducer.session(id: id)?.command == SlashCommand(name: "review", startedAt: at(0)),
                "reported twice, started once")

        reducer.apply(hook(.permissionRequest, tool: "Bash"), now: at(10))
        #expect(reducer.session(id: id)?.status == .question)
        #expect(reducer.session(id: id)?.isRunningCommand == false, "the question comes first")

        reducer.apply(hook(.postToolUse, tool: "Bash"), now: at(20))
        #expect(reducer.session(id: id)?.isRunningCommand == true, "and the spinner comes back")

        reducer.apply(hook(.stop), now: at(40))
        #expect(reducer.session(id: id)?.command == nil)
        #expect(reducer.session(id: id)?.status == .complete)
    }

    @Test("An ordinary prompt, a failure, or a ready plan ends the command")
    func commandEnds() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit, command: "review"), now: at(0))
        reducer.apply(hook(.userPromptSubmit), now: at(5))
        #expect(reducer.session(id: id)?.command == nil)

        reducer.apply(hook(.preCompact, trigger: "manual"), now: at(10))
        reducer.apply(hook(.stopFailure, agentID: "compactor"), now: at(12))
        #expect(reducer.session(id: id)?.command == nil)
        #expect(reducer.session(id: id)?.status == .error)

        reducer.apply(hook(.userPromptSubmit, command: "plan-it"), now: at(20))
        reducer.apply(hook(.preToolUse, tool: "ExitPlanMode"), now: at(30))
        #expect(reducer.session(id: id)?.command == nil)
        #expect(reducer.session(id: id)?.status == .plan)
    }

    @Test("A subagent compacting its own context leaves the circle alone")
    func subagentCompactIgnored() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit), now: at(0))
        reducer.apply(hook(.preCompact, trigger: "auto", agentID: "a1"), now: at(5))
        #expect(reducer.session(id: id)?.command == nil)
    }

    @Test("The transcript ends a compaction, but not with a boundary from before it began")
    func transcriptEndsCompaction() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit), now: at(0))
        reducer.apply(hook(.stop), now: at(1))
        reducer.apply(hook(.preCompact, trigger: "manual"), now: at(100))

        // A first read replays an old compaction.
        reducer.apply(.claudeTranscript(sessionID: "s1", signal: .commandFinished(name: "compact", at: at(-3600))), now: at(101))
        #expect(reducer.session(id: id)?.isRunningCommand == true)

        // A cancelled one is written as a local_command line.
        reducer.apply(.claudeTranscript(sessionID: "s1", signal: .commandFinished(name: "compact", at: at(130))), now: at(130))
        #expect(reducer.session(id: id)?.command == nil)
        #expect(reducer.session(id: id)?.status == .complete)
    }

    @Test("A command that goes silent for too long is taken to be over")
    func commandTimesOut() {
        var reducer = SessionReducer()
        reducer.apply(hook(.userPromptSubmit), now: at(0))
        reducer.apply(hook(.preCompact, trigger: "auto"), now: at(1))

        reducer.tick(now: at(1 + reducer.commandTimeout - 1))
        #expect(reducer.session(id: id)?.command != nil)

        reducer.tick(now: at(1 + reducer.commandTimeout + 1))
        #expect(reducer.session(id: id)?.command == nil)
    }

    @Test("Transcript lines that mark a command's end")
    func transcriptSignals() {
        let boundary = """
            {"type":"system","subtype":"compact_boundary","content":"Conversation compacted",
             "timestamp":"2026-09-23T13:14:50.125Z","compactMetadata":{"trigger":"manual"}}
            """
        let signals = ClaudeTranscriptWatcher.signals(in: Data(boundary.utf8))
        guard case .commandFinished(let name, let at)? = signals.first else {
            Issue.record("no end signal in \(signals)")
            return
        }
        #expect(name == "compact")
        #expect(at == CodexRolloutParser.timestamp("2026-09-23T13:14:50.125Z"))

        let cancelled = """
            {"type":"system","subtype":"local_command","timestamp":"2026-09-23T13:20:14.746Z",
             "content":"<local-command-stderr>Compaction canceled.</local-command-stderr>",
             "commandRun":{"command":"compact","args":""}}
            """
        #expect(ClaudeTranscriptWatcher.signals(in: Data(cancelled.utf8)).contains {
            if case .commandFinished("compact", _) = $0 { true } else { false }
        })
    }

    @Test("Hooks from an older version get the new events added")
    func missingEvents() throws {
        let directory = NSTemporaryDirectory() + "island-hooks-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/settings.json"
        let old = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Apps/agent-island-hook"}]}],
                      "PreCompact":[{"hooks":[{"type":"command","command":"/usr/local/bin/my-own"}]}]}}
            """
        try Data(old.utf8).write(to: URL(fileURLWithPath: path))

        let missing = HookInstaller.missingEvents(settingsPath: path, agent: .claude)
        #expect(missing.contains("PreCompact"), "someone else's hook there does not count")
        #expect(missing.contains("PostCompact"))
        #expect(missing.contains("UserPromptExpansion"))
        #expect(!missing.contains("Stop"))

        try HookInstaller.install(settingsPath: path, binaryPath: "/Apps/agent-island-hook", agent: .claude)
        #expect(HookInstaller.missingEvents(settingsPath: path, agent: .claude).isEmpty)
    }
}
