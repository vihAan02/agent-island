import Foundation
import Testing

@testable import IslandCore

@Suite("Hook payloads")
struct HookParsingTests {
    @Test("A forwarded Claude envelope decodes, effort and all")
    func decodesEnvelope() throws {
        let json = """
            {"agent":"claude","pid":4242,
             "env":{"CLAUDE_EFFORT":"xhigh","__CFBundleIdentifier":"com.anthropic.claudefordesktop"},
             "payload":{"hook_event_name":"PreToolUse","session_id":"abc-123",
                        "cwd":"/Users/me/repo","transcript_path":"/tmp/t.jsonl",
                        "permission_mode":"plan","effort":{"level":"max"},
                        "tool_name":"Bash","tool_input":{"command":"swift test --parallel"}}}
            """
        let event = try #require(HookEvent.decode(envelope: Data(json.utf8)))

        #expect(event.kind == .claude)
        #expect(event.name == .preToolUse)
        #expect(event.sessionID == "abc-123")
        #expect(event.cwd == "/Users/me/repo")
        #expect(event.permissionMode == "plan")
        #expect(event.effort == .max)
        #expect(event.toolSummary == "Bash(swift test --parallel)")
        #expect(event.env["__CFBundleIdentifier"] == "com.anthropic.claudefordesktop")
    }

    @Test("Effort falls back to the CLAUDE_EFFORT variable")
    func effortFromEnvironment() throws {
        let json = """
            {"agent":"claude","env":{"CLAUDE_EFFORT":"ultracode"},
             "payload":{"hook_event_name":"Stop","session_id":"s"}}
            """
        let event = try #require(HookEvent.decode(envelope: Data(json.utf8)))
        #expect(event.effort == .ultra)
    }

    @Test("A Codex hook ignores a CLAUDE_EFFORT it inherited")
    func codexIgnoresClaudeEffort() throws {
        let json = """
            {"agent":"codex","env":{"CLAUDE_EFFORT":"xhigh"},
             "payload":{"hook_event_name":"Stop","session_id":"t"}}
            """
        let event = try #require(HookEvent.decode(envelope: Data(json.utf8)))
        #expect(event.effort == nil)
    }

    @Test("A Codex envelope decodes with the same schema")
    func decodesCodexEnvelope() throws {
        let json = """
            {"agent":"codex","env":{},
             "payload":{"hook_event_name":"PermissionRequest","session_id":"01a0","cwd":"/tmp",
                        "model":"gpt-5.6-terra","permission_mode":"default",
                        "tool_name":"exec","tool_input":{"cmd":"pytest -q"}}}
            """
        let event = try #require(HookEvent.decode(envelope: Data(json.utf8)))
        #expect(event.kind == .codex)
        #expect(event.name == .permissionRequest)
        #expect(event.toolSummary == "exec(pytest -q)")
    }

    @Test("Junk and unknown events are ignored")
    func rejectsJunk() {
        #expect(HookEvent.decode(envelope: Data("not json".utf8)) == nil)
        #expect(HookEvent.decode(envelope: Data(#"{"payload":{}}"#.utf8)) == nil)
        #expect(HookEvent.decode(
            envelope: Data(#"{"payload":{"hook_event_name":"Bogus","session_id":"s"}}"#.utf8)
        ) == nil)
        #expect(HookEvent.decode(
            envelope: Data(#"{"payload":{"hook_event_name":"Stop"}}"#.utf8)
        ) == nil, "a payload with no session id is useless")
    }

    @Test("AskUserQuestion summarises to the question itself")
    func summarisesQuestions() {
        let summary = ToolSummary.describe(
            toolName: "AskUserQuestion",
            toolInput: ["questions": [["question": "Which database should I use?", "header": "DB"]]]
        )
        #expect(summary == "Which database should I use?")
    }
}

@Suite("Claude transcripts")
struct TranscriptParsingTests {
    @Test("Assistant lines carry the turn's effort")
    func readsEffort() {
        let line = #"{"type":"assistant","effort":"xhigh","message":{"content":[]}}"#
        let signals = ClaudeTranscriptWatcher.signals(in: Data(line.utf8))
        #expect(signals.contains(.effort(.xhigh)))
        #expect(signals.contains(.assistantActivity))
    }

    @Test("Tool calls surface questions and finished plans")
    func readsToolCalls() {
        let question = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion",
             "input":{"questions":[{"question":"Ship it?"}]}}]}}
            """
        #expect(
            ClaudeTranscriptWatcher.signals(in: Data(question.utf8))
                .contains(.askingQuestion("Ship it?"))
        )

        let plan = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ExitPlanMode","input":{}}]}}"#
        #expect(ClaudeTranscriptWatcher.signals(in: Data(plan.utf8)).contains(.planReady))
    }

    @Test("API error lines report an error")
    func readsApiErrors() {
        let line = """
            {"type":"assistant","isApiErrorMessage":true,
             "message":{"content":[{"type":"text","text":"API Error 529: overloaded"}]}}
            """
        let signals = ClaudeTranscriptWatcher.signals(in: Data(line.utf8))
        #expect(signals.contains(.apiError("API Error 529: overloaded")))
    }
}

@Suite("Codex rollouts")
struct CodexParsingTests {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    @Test("A root thread reports discovery, effort, and turn boundaries")
    func parsesRootThread() {
        var parser = CodexRolloutParser()
        var events: [CodexEvent.Kind] = []

        events += parser.events(for: line("""
            {"timestamp":"2026-09-17T11:56:22.334Z","type":"session_meta",
             "payload":{"id":"t-1","session_id":"t-1","cwd":"/Users/me/ocr","parent_thread_id":null}}
            """)).map(\.kind)
        events += parser.events(for: line("""
            {"timestamp":"2026-09-17T11:56:22.335Z","type":"turn_context",
             "payload":{"effort":"ultra","collaboration_mode":{"mode":"plan"}}}
            """)).map(\.kind)
        events += parser.events(for: line("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            """)).map(\.kind)
        events += parser.events(for: line("""
            {"type":"event_msg","payload":{"type":"task_complete"}}
            """)).map(\.kind)

        #expect(parser.threadID == "t-1")
        #expect(events == [
            .discovered(cwd: "/Users/me/ocr", title: nil),
            .turnContext(effort: .ultra, planMode: true),
            .taskStarted,
            .taskComplete,
        ])
    }

    @Test("Subagent rollouts are skipped")
    func skipsSubagents() {
        var parser = CodexRolloutParser()
        let meta = """
            {"type":"session_meta","payload":{"id":"t-2","session_id":"t-1",
             "parent_thread_id":"t-1","cwd":"/Users/me/ocr"}}
            """
        #expect(parser.events(for: line(meta)).isEmpty)
        #expect(parser.isSubagent)
        #expect(parser.events(for: line(#"{"type":"event_msg","payload":{"type":"task_started"}}"#)).isEmpty)
    }

    @Test("request_user_input opens and closes a question")
    func tracksUserInput() {
        var parser = CodexRolloutParser()
        _ = parser.events(for: line(#"{"type":"session_meta","payload":{"id":"t-1","cwd":"/x"}}"#))

        let ask = parser.events(for: line("""
            {"type":"response_item","payload":{"type":"function_call","name":"request_user_input",
             "call_id":"call_1","arguments":"{}"}}
            """))
        #expect(ask.first?.kind == .userInputRequest("Waiting on your answer"))

        let answered = parser.events(for: line("""
            {"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"ok"}}
            """))
        #expect(answered.first?.kind == .activity)
    }

    @Test("Approvals and stream errors map to question and error")
    func parsesApprovalsAndErrors() {
        var parser = CodexRolloutParser()
        _ = parser.events(for: line(#"{"type":"session_meta","payload":{"id":"t-1","cwd":"/x"}}"#))

        let approval = parser.events(for: line("""
            {"type":"event_msg","payload":{"type":"exec_approval_request","command":["rm","-rf","build"]}}
            """))
        #expect(approval.first?.kind == .approvalRequest("rm -rf build"))

        let failure = parser.events(for: line("""
            {"type":"event_msg","payload":{"type":"stream_error","message":"disconnected"}}
            """))
        #expect(failure.first?.kind == .streamError("disconnected"))
    }

    @Test("Thread ids can be recovered from the file name")
    func readsThreadIDFromFileName() {
        let path = "/x/2026/09/17/rollout-2026-09-17T11-47-51-01a0b00d-85ca-7663-968f-90af304c6132.jsonl"
        #expect(CodexRolloutParser.threadID(fromFileName: path) == "01a0b00d-85ca-7663-968f-90af304c6132")
        #expect(CodexRolloutParser.threadID(fromFileName: "/x/rollout-nope.jsonl") == nil)
    }
}

@Suite("Process arguments")
struct ProcessArgsTests {
    @Test("Effort and ultracode come out of the Claude command line")
    func parsesLaunchInfo() {
        let arguments = [
            "claude", "--effort", "xhigh", "--model", "claude-opus-5",
            "--settings", #"{"ultracode":true,"deniedMcpServers":[]}"#,
        ]
        let info = ProcessArgs.parseClaudeLaunchInfo(arguments)
        #expect(info.effort == .xhigh)
        #expect(info.model == "claude-opus-5")
        #expect(info.isUltra)
    }

    @Test("Ultracode off stays off")
    func ultracodeFalse() {
        let info = ProcessArgs.parseClaudeLaunchInfo(["claude", "--effort=high", #"{"ultracode":false}"#])
        #expect(info.effort == .high)
        #expect(!info.isUltra)
    }

    @Test("This process can be read back")
    func readsOwnArguments() throws {
        let arguments = try #require(ProcessArgs.arguments(pid: ProcessInfo.processInfo.processIdentifier))
        #expect(!arguments.isEmpty)
        #expect(ProcessArgs.isAlive(pid: ProcessInfo.processInfo.processIdentifier))
    }
}

@Suite("Registry files")
struct RegistryTests {
    @Test("A session file decodes into an entry")
    func decodesEntry() throws {
        let json = """
            {"pid":56564,"sessionId":"4dbad511-57cc","cwd":"/Users/me/agent-island",
             "startedAt":1790095234937,"version":"2.1.275","kind":"interactive",
             "entrypoint":"claude-desktop","name":"Dynamic island","status":"busy",
             "hostSessionId":"local_336dea01-45ca-457a-b323-9b37b11aa537",
             "statusUpdatedAt":1790095234937}
            """
        let entry = try #require(ClaudeRegistryEntry.decode(Data(json.utf8)))
        #expect(entry.hostSessionID == "local_336dea01-45ca-457a-b323-9b37b11aa537")
        #expect(entry.pid == 56564)
        #expect(entry.sessionID == "4dbad511-57cc")
        #expect(entry.name == "Dynamic island")
        #expect(entry.status == "busy")
        #expect(entry.host == .claudeDesktop)
    }

    @Test("A chat in the Claude app opens by the app's own id, not the Claude Code one")
    func claudeAppLink() throws {
        var reducer = SessionReducer()
        reducer.apply(.claudeRegistry([
            ClaudeRegistryEntry(pid: 7, sessionID: "4dbad511-57cc", cwd: "/tmp", status: "busy",
                                entrypoint: "claude-desktop", hostSessionID: "local_336dea01-45ca"),
        ]))
        let session = try #require(reducer.session(id: SessionReducer.claudeID("4dbad511-57cc")))
        #expect(session.claudeAppLink?.absoluteString == "claude://code/continue?session=local_336dea01-45ca&source=agent_island")

        var terminal = session
        terminal.hostSessionID = nil
        #expect(terminal.claudeAppLink == nil, "a CLI session has no chat in the app to open")
    }

    @Test("Key files and junk decode to nothing")
    func rejectsKeyFiles() {
        let keyFile = #"{"peerToken":"abc","procStart":"Tue Sep 22 03:59:16 2026"}"#
        #expect(ClaudeRegistryEntry.decode(Data(keyFile.utf8)) == nil)
    }
}
