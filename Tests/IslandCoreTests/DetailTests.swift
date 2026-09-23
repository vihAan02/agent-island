import Foundation
import Testing

@testable import IslandCore

@Suite("Card details")
struct DetailTests {
    @Test("numstat output sums up, binary files counting as changed")
    func parsesNumstat() {
        let stat = GitDiffStat.parse(numstat: "12\t3\tSources/a.swift\n0\t7\tREADME.md\n-\t-\tlogo.png\n")
        #expect(stat == DiffStat(added: 12, removed: 10, files: 3))
        #expect(GitDiffStat.parse(numstat: "").isEmpty)
    }

    @Test("A real repository reports its uncommitted lines, new files included")
    func diffOfARealRepository() throws {
        let root = NSTemporaryDirectory() + "island-diff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        try Data("one\ntwo\nthree\n".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "first")

        try Data("one\n2\nthree\nfour\n".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        try Data("new\nfile\n".utf8).write(to: URL(fileURLWithPath: root + "/b.txt"))

        let stat = try #require(GitDiffStat.compute(in: root))
        #expect(stat == DiffStat(added: 4, removed: 1, files: 2), "2 and four added, two removed, plus b.txt's 2 lines")
    }

    @Test("A folder outside any repository has no diff")
    func noRepository() {
        #expect(GitDiffStat.compute(in: "/") == nil)
    }

    @Test("Modes read the way each agent names them")
    func modeLabels() {
        var session = AgentSession(id: "claude:s", kind: .claude)
        #expect(session.modeLabel == nil)
        session.permissionMode = "acceptEdits"
        #expect(session.modeLabel == "Accept edits")
        session.permissionMode = "auto"
        #expect(session.modeLabel == "Auto")
        session.planMode = true
        #expect(session.modeLabel == "Plan", "plan mode wins over the permission mode")

        var codex = AgentSession(id: "codex:t", kind: .codex)
        codex.permissionMode = "danger-full-access"
        #expect(codex.modeLabel == "Full access")
    }

    @Test("Codex tool calls read as what the agent is doing")
    func codexToolCalls() {
        let exec = #"const r = await tools.exec_command({"cmd":"rg --files -g '!node_modules'","workdir":"/x"})"#
        #expect(CodexRolloutParser.describeToolCall(name: "exec", input: exec) == "Run(rg --files -g '!node_modules')")

        let patch = "*** Begin Patch\n*** Update File: src/resume/main.tex\n@@\n-a\n+b\n*** End Patch"
        #expect(CodexRolloutParser.describeToolCall(name: "apply_patch", input: patch) == "Edit(main.tex)")

        #expect(CodexRolloutParser.describeToolCall(name: "wait_agent", input: "{}") == nil, "bookkeeping says nothing")
    }

    @Test("A turn context carries the sandbox, and hooks carry the permission mode")
    func modesReachTheSession() {
        var parser = CodexRolloutParser()
        _ = parser.events(for: Data(#"{"type":"session_meta","payload":{"id":"t-1","cwd":"/x"}}"#.utf8))
        let events = parser.events(for: Data(#"{"type":"turn_context","payload":{"effort":"high","sandbox_policy":{"type":"read-only"},"collaboration_mode":{"mode":"default"}}}"#.utf8))
        var reducer = SessionReducer()
        events.forEach { reducer.apply(.codex($0)) }
        #expect(reducer.session(id: "codex:t-1")?.modeLabel == "Read only")

        reducer.apply(.hook(HookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "s", permissionMode: "acceptEdits")))
        #expect(reducer.session(id: "claude:s")?.modeLabel == "Accept edits")
    }

    @Test("After a tool runs, the card says what it did")
    func postToolUseSetsActivity() {
        var reducer = SessionReducer()
        reducer.apply(.hook(HookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "s")))
        reducer.apply(.hook(HookEvent(kind: .claude, name: .postToolUse, sessionID: "s", toolName: "Edit", toolSummary: "Edit(IslandModel.swift)")))
        #expect(reducer.session(id: "claude:s")?.detail == "Edit(IslandModel.swift)")
    }

    @Test("The transcript reports the permission mode")
    func transcriptMode() {
        let line = Data(#"{"type":"user","permissionMode":"plan","message":{"content":"hi"}}"#.utf8)
        #expect(ClaudeTranscriptWatcher.signals(in: line).contains(.permissionMode("plan")))
    }
}
