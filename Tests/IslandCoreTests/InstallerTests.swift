import Foundation
import Testing

@testable import IslandCore

@Suite("Hook installer")
struct HookInstallerTests {
    private func temporarySettings(_ contents: String?) throws -> String {
        let directory = NSTemporaryDirectory() + "island-hooks-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/settings.json"
        if let contents { try Data(contents.utf8).write(to: URL(fileURLWithPath: path)) }
        return path
    }

    private func json(at path: String) throws -> [String: Any] {
        let data = try #require(FileManager.default.contents(atPath: path))
        return try #require((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    @Test("Installing keeps the user's other settings and their own hooks")
    func installPreservesSettings() throws {
        let path = try temporarySettings("""
            {"theme":"dark","model":"opus",
             "hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/say-done"}]}]}}
            """)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        try HookInstaller.install(settingsPath: path, binaryPath: "/tmp/agent-island-hook", agent: .claude)
        let root = try json(at: path)

        #expect(root["theme"] as? String == "dark")
        #expect(root["model"] as? String == "opus")
        #expect(HookInstaller.isInstalled(settingsPath: path))

        let stop = try #require((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains("/usr/local/bin/say-done"), "the user's own hook survived")
        #expect(commands.contains("/tmp/agent-island-hook"))

        // The originals are backed up before the file is rewritten.
        #expect(FileManager.default.fileExists(atPath: path + ".agent-island.bak"))
    }

    @Test("Our entries never block a turn, except the two kinds the island answers")
    func entriesAreAsync() throws {
        let path = try temporarySettings(nil)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        try HookInstaller.install(settingsPath: path, binaryPath: "/tmp/agent-island-hook", agent: .claude)
        let hooks = try #require(try json(at: path)["hooks"] as? [String: Any])

        var waiting: [String] = []
        for (event, value) in hooks {
            for group in (value as? [[String: Any]]) ?? [] {
                for entry in (group["hooks"] as? [[String: Any]]) ?? [] {
                    #expect((entry["args"] as? [String])?.first == "claude")
                    if entry["async"] as? Bool == true { continue }
                    waiting.append("\(event) \(group["matcher"] as? String ?? "")")
                    #expect((entry["args"] as? [String])?.contains("--reply") == true)
                }
            }
        }
        // AskUserQuestion and plans race Claude's own dialog; the end of a turn waits
        // in the background (asyncRewake) and never holds the turn.
        #expect(waiting.sorted() == ["PermissionRequest AskUserQuestion|ExitPlanMode", "Stop "])

        let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(stop.first?["asyncRewake"] as? Bool == true)
    }

    @Test("Installing twice does not pile up entries")
    func installIsIdempotent() throws {
        let path = try temporarySettings("{}")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        try HookInstaller.install(settingsPath: path, binaryPath: "/tmp/agent-island-hook", agent: .claude)
        let first = try json(at: path)
        try HookInstaller.install(settingsPath: path, binaryPath: "/tmp/agent-island-hook", agent: .claude)
        let second = try json(at: path)

        let count: ([String: Any]) -> Int = { root in
            ((root["hooks"] as? [String: Any]) ?? [:]).values
                .compactMap { $0 as? [[String: Any]] }
                .flatMap { $0 }
                .count
        }
        #expect(count(first) == count(second))
    }

    @Test("Hooks left by a moved app are spotted, and reinstalling repoints them")
    func detectsMovedApp() throws {
        let path = try temporarySettings(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/say-done"}]}]}}"#)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let old = "/Users/me/Desktop/AgentIsland.app/Contents/MacOS/agent-island-hook"
        let new = "/Applications/AgentIsland.app/Contents/MacOS/agent-island-hook"
        try HookInstaller.install(settingsPath: path, binaryPath: old, agent: .claude)
        #expect(HookInstaller.installedCommands(settingsPath: path) == [old], "the user's own hook is not ours")

        try HookInstaller.install(settingsPath: path, binaryPath: new, agent: .claude)
        #expect(HookInstaller.installedCommands(settingsPath: path) == [new])
    }

    @Test("Uninstalling leaves the file as it was found")
    func uninstallRestores() throws {
        let original = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/say-done"}]}]},"theme":"dark"}
            """
        let path = try temporarySettings(original)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        try HookInstaller.install(settingsPath: path, binaryPath: "/tmp/agent-island-hook", agent: .claude)
        try HookInstaller.uninstall(settingsPath: path)

        let root = try json(at: path)
        #expect(!HookInstaller.isInstalled(settingsPath: path))
        #expect(root["theme"] as? String == "dark")

        let stop = try #require((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands == ["/usr/local/bin/say-done"])
    }

    @Test("A settings file that is not an object is left alone")
    func refusesBrokenSettings() throws {
        let path = try temporarySettings("[1,2,3]")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        #expect(throws: HookInstaller.InstallError.self) {
            try HookInstaller.install(settingsPath: path, binaryPath: "/tmp/hook", agent: .claude)
        }
    }

    @Test("Codex gets the events Codex actually emits")
    func codexEventSet() throws {
        let path = try temporarySettings(nil)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        try HookInstaller.install(settingsPath: path, binaryPath: "/tmp/agent-island-hook", agent: .codex)
        let hooks = try #require(try json(at: path)["hooks"] as? [String: Any])
        #expect(hooks["Interrupt"] != nil)
        #expect(hooks["StopFailure"] == nil, "Codex has no StopFailure event")
    }
}

@Suite("File tailer")
struct FileTailerTests {
    @Test("Only new whole lines come back")
    func tailsAppends() throws {
        let path = NSTemporaryDirectory() + "island-tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try Data("{\"a\":1}\n{\"a\":2}\n".utf8).write(to: URL(fileURLWithPath: path))
        var tailer = FileTailer()

        let first = tailer.newLines(at: path, readFromStart: true)
        #expect(first.count == 2)
        #expect(tailer.newLines(at: path, readFromStart: false).isEmpty)

        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        // A half-written line is held back until its newline arrives.
        try handle.write(contentsOf: Data("{\"a\":3}".utf8))
        #expect(tailer.newLines(at: path, readFromStart: false).isEmpty)

        try handle.write(contentsOf: Data("\n".utf8))
        let third = tailer.newLines(at: path, readFromStart: false)
        #expect(third.count == 1)
        #expect(String(decoding: third[0], as: UTF8.self) == "{\"a\":3}")
        try handle.close()
    }

    @Test("A new file can be followed from its end")
    func startsAtEnd() throws {
        let path = NSTemporaryDirectory() + "island-tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("old\nlines\n".utf8).write(to: URL(fileURLWithPath: path))

        var tailer = FileTailer()
        #expect(tailer.newLines(at: path, readFromStart: false).isEmpty)

        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("new\n".utf8))
        try handle.close()

        #expect(tailer.newLines(at: path, readFromStart: false).count == 1)
    }

    @Test("A truncated file is re-read from the start")
    func handlesTruncation() throws {
        let path = NSTemporaryDirectory() + "island-tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("one\ntwo\n".utf8).write(to: URL(fileURLWithPath: path))

        var tailer = FileTailer()
        _ = tailer.newLines(at: path, readFromStart: true)
        try Data("fresh\n".utf8).write(to: URL(fileURLWithPath: path))

        let lines = tailer.newLines(at: path, readFromStart: false)
        #expect(lines.count == 1)
        #expect(String(decoding: lines[0], as: UTF8.self) == "fresh")
    }
}
