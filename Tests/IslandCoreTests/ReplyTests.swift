import Darwin
import Foundation
import Testing

@testable import IslandCore

@Suite("Answering from the island")
struct ReplyTests {
    private func json(_ reply: HookReply) throws -> [String: Any] {
        guard case .decision(let text) = reply else {
            Issue.record("not a decision: \(reply)")
            return [:]
        }
        return try #require((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    private func decision(_ reply: HookReply) throws -> [String: Any] {
        let output = try #require(try json(reply)["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        return try #require(output["decision"] as? [String: Any])
    }

    @Test("Answers go back as the question's own input, with answers filled in")
    func answersQuestions() throws {
        let input = Data(#"{"questions":[{"question":"Which database?","options":[{"label":"Postgres"}]}]}"#.utf8)
        let reply = try #require(HookReply.answer(toolInput: input, answers: ["Which database?": "Postgres"]))
        let decision = try decision(reply)
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedInput"] as? [String: Any])
        #expect((updated["questions"] as? [[String: Any]])?.count == 1, "the questions are sent back unchanged")
        #expect((updated["answers"] as? [String: String]) == ["Which database?": "Postgres"])
    }

    @Test("A plan is approved as is, or with edits accepted from then on")
    func approvesPlans() throws {
        let input = Data(##"{"plan":"# Do it","planFilePath":"/tmp/p.md"}"##.utf8)

        let plain = try decision(try #require(HookReply.approvePlan(toolInput: input, acceptEdits: false)))
        #expect(plain["behavior"] as? String == "allow")
        #expect((plain["updatedInput"] as? [String: Any])?["plan"] as? String == "# Do it")
        #expect(plain["updatedPermissions"] == nil, "Claude goes back to the mode it planned from")

        let edits = try decision(try #require(HookReply.approvePlan(toolInput: input, acceptEdits: true)))
        let permissions = try #require(edits["updatedPermissions"] as? [[String: Any]])
        #expect(permissions.first?["type"] as? String == "setMode")
        #expect(permissions.first?["mode"] as? String == "acceptEdits")
    }

    @Test("Changes to a plan go back as a denial carrying the user's words")
    func revisesPlans() throws {
        let decision = try decision(HookReply.revisePlan(feedback: "  Use SQLite instead  "))
        #expect(decision["behavior"] as? String == "deny")
        #expect((decision["message"] as? String)?.hasSuffix("Use SQLite instead") == true)
    }

    @Test("On the wire, a decision is stdout and a message is stderr")
    func wireFormat() {
        #expect(HookReply.decision("{}").wire == Data("O{}".utf8))
        #expect(HookReply.prompt("  hello \n").wire == Data("Whello".utf8))
    }

    @Test("A hook waiting on an answer decodes with what it asks")
    func decodesAsks() throws {
        let question = """
            {"agent":"claude","reply":true,"env":{},"payload":{"hook_event_name":"PermissionRequest","session_id":"s",
             "tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Ship it?","header":"Ship",
             "multiSelect":false,"options":[{"label":"Yes","description":"Now"},{"label":"No"}]}]}}}
            """
        let event = try #require(HookEvent.decode(envelope: Data(question.utf8)))
        #expect(event.wantsReply)
        #expect(event.ask == .questions([
            AgentQuestion(question: "Ship it?", header: "Ship", options: [.init(label: "Yes", description: "Now"), .init(label: "No")]),
        ]))
        #expect(event.toolInput != nil)

        let plan = """
            {"agent":"claude","env":{},"payload":{"hook_event_name":"PermissionRequest","session_id":"s",
             "tool_name":"ExitPlanMode","tool_input":{"plan":"# Plan"}}}
            """
        let planEvent = try #require(HookEvent.decode(envelope: Data(plan.utf8)))
        #expect(!planEvent.wantsReply)
        #expect(planEvent.ask == .plan("# Plan"))

        let bash = """
            {"agent":"claude","env":{},"payload":{"hook_event_name":"PermissionRequest","session_id":"s",
             "tool_name":"Bash","tool_input":{"command":"ls"}}}
            """
        let bashEvent = try #require(HookEvent.decode(envelope: Data(bash.utf8)))
        #expect(bashEvent.ask == nil)
        #expect(bashEvent.toolInput == nil, "only the two tools that wait on the user keep their input")
    }

    @Test("A question or a plan waiting for approval shows as such, not as a permission prompt")
    func permissionRequestsForAsks() {
        var reducer = SessionReducer()
        let id = SessionReducer.claudeID("s")
        reducer.apply(.hook(HookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "s")))
        reducer.apply(.hook(HookEvent(kind: .claude, name: .permissionRequest, sessionID: "s",
                                      toolName: "AskUserQuestion", toolSummary: "Ship it?")))
        #expect(reducer.session(id: id)?.status == .question)
        #expect(reducer.session(id: id)?.detail == "Ship it?")

        reducer.apply(.hook(HookEvent(kind: .claude, name: .permissionRequest, sessionID: "s", toolName: "ExitPlanMode")))
        #expect(reducer.session(id: id)?.status == .plan)

        reducer.noteReplySent(id: id)
        #expect(reducer.session(id: id)?.status == .working)
    }

    // MARK: - The socket

    /// Unix socket paths are limited to about 100 bytes, so keep the name short.
    private func socketPath() -> String {
        NSTemporaryDirectory() + "is-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    /// Connects like the helper does: writes, half-closes, and hands back the socket.
    private func connect(to path: String, sending text: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(connected == 0)
        _ = Array(text.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// Hands the channels the server gives out to the test, in order.
    private final class Channels: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [HookReplyChannel?] = []

        func add(_ channel: HookReplyChannel?) {
            lock.lock()
            received.append(channel)
            lock.unlock()
        }

        func next(timeout: TimeInterval = 3) -> HookReplyChannel?? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                if !received.isEmpty {
                    let first = received.removeFirst()
                    lock.unlock()
                    return .some(first)
                }
                lock.unlock()
                usleep(10_000)
            }
            return nil
        }
    }

    @Test("A waiting hook hears that the app will answer, then gets the answer")
    func socketRoundTrip() throws {
        let path = socketPath()
        let channels = Channels()
        let server = HookSocketServer(path: path) { _, channel in channels.add(channel) }
        try server.start()
        defer { server.stop() }

        let waiting = try connect(to: path, sending: #"{"agent":"claude","reply":true,"payload":{"hook_event_name":"Stop","session_id":"s"}}"#)
        defer { close(waiting) }
        let delivered = try #require(channels.next(), "the server handed nothing over")
        let channel = try #require(delivered, "a waiting hook gets a channel")
        #expect(channel.send(.prompt("carry on")))
        #expect(readAll(waiting) == Data("KWcarry on".utf8))
        #expect(!channel.isOpen)

        // A plain hook gets no channel, and its connection is closed at once.
        let plain = try connect(to: path, sending: #"{"agent":"claude","payload":{"hook_event_name":"Stop","session_id":"s"}}"#)
        defer { close(plain) }
        let none = try #require(channels.next())
        #expect(none == nil)
        #expect(readAll(plain).isEmpty)
    }

    // MARK: - The helper binary

    /// The helper `swift build` made, if there is one.
    static let helper: String? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(".build/debug/agent-island-hook").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    private func runHelper(socket: String, payload: String) throws -> (status: Int32, stdout: String, stderr: String, seconds: TimeInterval) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.helper))
        process.arguments = ["claude", "--reply"]
        process.environment = ["AGENT_ISLAND_SOCKET": socket, "HOME": NSHomeDirectory()]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self),
                Date().timeIntervalSince(started))
    }

    @Test("The helper prints a decision, wakes the session with a message, or goes quietly",
          .enabled(if: ReplyTests.helper != nil, "run swift build first"))
    func helperEndToEnd() throws {
        let path = socketPath()
        let channels = Channels()
        let replies = [HookReply.decision(#"{"ok":true}"#), HookReply.prompt("next thing"), nil]
        let server = HookSocketServer(path: path) { _, channel in channels.add(channel) }
        try server.start()
        defer { server.stop() }

        let payload = #"{"hook_event_name":"Stop","session_id":"s"}"#
        for reply in replies {
            let answerer = Thread {
                guard let channel = channels.next() ?? nil else { return }
                if let reply { channel.send(reply) } else { channel.cancel() }
            }
            answerer.start()
            let result = try runHelper(socket: path, payload: payload)
            switch reply {
            case .decision?:
                #expect(result.status == 0)
                #expect(result.stdout == #"{"ok":true}"#)
            case .wake?:
                #expect(result.status == 2, "exit 2 is what wakes an asyncRewake hook's session")
                #expect(result.stderr == "next thing")
            case nil:
                #expect(result.status == 0)
                #expect(result.stdout.isEmpty && result.stderr.isEmpty)
            }
        }

        // With no app listening, it gives up at once.
        let alone = try runHelper(socket: socketPath(), payload: payload)
        #expect(alone.status == 0)
        #expect(alone.seconds < 1)
    }
}

@Suite("Timeline")
struct TimelineTests {
    private func items(_ line: String) -> [ActivityItem] {
        ClaudeTranscriptWatcher.signals(in: Data(line.utf8)).compactMap {
            if case .activity(let item) = $0 { item } else { nil }
        }
    }

    @Test("What the user typed, commands included, and nothing Claude wraps around it")
    func userLines() {
        #expect(items(#"{"type":"user","timestamp":"2026-09-23T13:16:34.526Z","message":{"role":"user","content":"Fix the parser"}}"#)
            .map(\.text) == ["Fix the parser"])
        #expect(items(#"{"type":"user","message":{"content":"<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args></command-args>"}}"#)
            .map(\.text) == ["/compact"])
        #expect(items(#"{"type":"user","message":{"content":"<local-command-stdout>Compacted</local-command-stdout>"}}"#).isEmpty)
        #expect(items(#"{"type":"user","isMeta":true,"message":{"content":"Continue from where you left off."}}"#).isEmpty)
    }

    @Test("What Claude said and ran, and what failed")
    func assistantLines() {
        let turn = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Running the tests."},{"type":"tool_use","name":"Bash","input":{"command":"swift test"}},{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Ship it?"}]}}]}}"#
        #expect(items(turn).map(\.kind) == [.reply, .tool, .tool])
        #expect(items(turn).map(\.text) == ["Running the tests.", "Bash(swift test)", "Asked: Ship it?"])

        let failure = #"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"exit code 1"}]}}"#
        #expect(items(failure) == [ActivityItem(kind: .error, text: "exit code 1")])
    }

    @Test("Codex messages, without the context Codex wraps in tags")
    func codexMessages() {
        let user = CodexRolloutParser.message(["role": "user", "content": [
            ["type": "input_text", "text": "<environment_context>cwd</environment_context>"],
            ["type": "input_text", "text": "Port the parser"],
        ]], at: Date())
        #expect(user?.kind == .prompt)
        #expect(user?.text == "Port the parser")
        #expect(CodexRolloutParser.message(["role": "developer", "content": [["type": "input_text", "text": "x"]]], at: Date()) == nil)
    }
}
