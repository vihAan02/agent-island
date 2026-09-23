import Foundation

/// Adds and removes the Agent Island hook entries in the agents' own settings files.
///
/// Every entry runs the same small binary. Almost all of them are `async: true` and
/// print nothing, so they never block a turn or change a decision. Two kinds wait
/// instead, so the island can answer: see `HookMode`.
public enum HookInstaller {
    public static let marker = "agent-island-hook"

    /// How an entry runs.
    public enum HookMode: Sendable, Equatable {
        /// Tells the app and exits at once. Never waits, never prints.
        case notify
        /// Waits for an answer from the island. Claude shows its own dialog at the
        /// same time, and whichever is answered first wins.
        case answer
        /// Runs in the background once a turn ends, so a message typed in the island
        /// can wake the session.
        case wake
    }

    public struct Entry: Sendable {
        public var event: String
        public var matcher: String?
        public var mode: HookMode

        public init(_ event: String, _ matcher: String? = nil, _ mode: HookMode = .notify) {
            self.event = event
            self.matcher = matcher
            self.mode = mode
        }

        /// How the entry shows in the Hooks pane and the logs.
        public var label: String {
            matcher.map { "\(event) (\($0))" } ?? event
        }
    }

    /// The Claude tools whose question the island can answer.
    public static let answerableTools = "AskUserQuestion|ExitPlanMode"
    /// A waiting hook lasts a day at most, then Claude Code ends it.
    public static let replyTimeout = 86_400
    /// Put before a message typed in the island, when it reaches Claude.
    public static let wakePrefix = "The user sent this from Agent Island, the menu bar app watching this session. It is their next message to you:"

    /// Claude Code events worth a status change, with the tool matcher where one helps.
    public static let claudeEntries: [Entry] = [
        Entry("SessionStart"),
        Entry("UserPromptSubmit"),
        Entry("UserPromptExpansion"),
        Entry("PreToolUse", answerableTools),
        Entry("PostToolUse"),
        Entry("PostToolUseFailure"),
        Entry("PermissionRequest"),
        Entry("PermissionRequest", answerableTools, .answer),
        Entry("PermissionDenied"),
        Entry("Notification"),
        Entry("Stop", nil, .wake),
        Entry("StopFailure"),
        Entry("SessionEnd"),
        Entry("PreCompact"),
        Entry("PostCompact"),
    ]

    /// Codex uses the same schema, minus the events it does not emit.
    public static let codexEntries: [Entry] = [
        Entry("SessionStart"),
        Entry("UserPromptSubmit"),
        Entry("PreToolUse"),
        Entry("PostToolUse"),
        Entry("PermissionRequest"),
        Entry("Stop"),
        Entry("Interrupt"),
        Entry("SessionEnd"),
    ]

    public static func entries(for agent: AgentKind) -> [Entry] {
        agent == .claude ? claudeEntries : codexEntries
    }

    /// The hook command for one entry, as it is written into the settings file.
    static func command(for entry: Entry, binaryPath: String, agent: AgentKind) -> [String: Any] {
        var hook: [String: Any] = ["type": "command", "command": binaryPath]
        switch entry.mode {
        case .notify:
            hook["args"] = [agent.rawValue]
            hook["async"] = true
            hook["timeout"] = 5
        case .answer:
            hook["args"] = [agent.rawValue, "--reply"]
            hook["timeout"] = replyTimeout
        case .wake:
            hook["args"] = [agent.rawValue, "--reply"]
            hook["asyncRewake"] = true
            hook["timeout"] = replyTimeout
            hook["rewakeMessage"] = wakePrefix
            hook["rewakeSummary"] = "Message from Agent Island"
        }
        return hook
    }

    public enum InstallError: Error, CustomStringConvertible {
        case unreadable(String)
        case notAnObject(String)
        case writeFailed(String, Error)

        public var description: String {
            switch self {
            case .unreadable(let path): "Could not read \(path)"
            case .notAnObject(let path): "\(path) is not a JSON object"
            case .writeFailed(let path, let error): "Could not write \(path): \(error)"
            }
        }
    }

    // MARK: - Status

    public static func isInstalled(settingsPath: String) -> Bool {
        !installedCommands(settingsPath: settingsPath).isEmpty
    }

    /// Every Agent Island command the settings file runs. More than one, or one that
    /// is not this app's helper, means the app moved since the hooks were added.
    public static func installedCommands(settingsPath: String) -> Set<String> {
        guard let hooks = readHooks(settingsPath: settingsPath) else { return [] }
        var commands: Set<String> = []
        for (_, value) in hooks {
            commands.formUnion(ourCommands(in: value))
        }
        return commands
    }

    /// Entries this version wants that the settings file does not have in this form
    /// yet, as after an update that added some or changed how one runs.
    public static func missingEntries(settingsPath: String, agent: AgentKind) -> [String] {
        let hooks = readHooks(settingsPath: settingsPath) ?? [:]
        return entries(for: agent).filter { entry in
            let groups = (hooks[entry.event] as? [[String: Any]]) ?? []
            return !groups.contains { group in
                (group["matcher"] as? String) == entry.matcher
                    && ((group["hooks"] as? [[String: Any]]) ?? []).contains { mode(of: $0) == entry.mode }
            }
        }.map(\.label)
    }

    /// The mode an installed hook of ours runs in, or nil for someone else's hook.
    private static func mode(of hook: [String: Any]) -> HookMode? {
        guard (hook["command"] as? String)?.contains(marker) == true else { return nil }
        if (hook["asyncRewake"] as? Bool) == true { return .wake }
        if ((hook["args"] as? [String]) ?? []).contains("--reply") { return .answer }
        return .notify
    }

    private static func readHooks(settingsPath: String) -> [String: Any]? {
        guard
            let data = FileManager.default.contents(atPath: settingsPath),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root["hooks"] as? [String: Any]
    }

    /// The Agent Island commands in one event's list of hook groups.
    private static func ourCommands(in groups: Any) -> Set<String> {
        var commands: Set<String> = []
        for group in (groups as? [[String: Any]]) ?? [] {
            for entry in (group["hooks"] as? [[String: Any]]) ?? [] {
                if let command = entry["command"] as? String, command.contains(marker) {
                    commands.insert(command)
                }
            }
        }
        return commands
    }

    // MARK: - Install and uninstall

    public static func install(
        settingsPath: String,
        binaryPath: String,
        agent: AgentKind
    ) throws {
        try rewrite(settingsPath: settingsPath) { root in
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            hooks = stripOurEntries(from: hooks)

            for entry in entries(for: agent) {
                var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
                var group: [String: Any] = [
                    "hooks": [command(for: entry, binaryPath: binaryPath, agent: agent)],
                ]
                if let matcher = entry.matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[entry.event] = groups
            }
            root["hooks"] = hooks
            return root
        }
    }

    public static func uninstall(settingsPath: String) throws {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return }
        try rewrite(settingsPath: settingsPath) { root in
            guard var hooks = root["hooks"] as? [String: Any] else { return root }
            hooks = stripOurEntries(from: hooks)
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
            return root
        }
    }

    /// Drops every group that points at our binary, and any group left with no hooks.
    public static func stripOurEntries(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            var kept: [[String: Any]] = []
            for var group in groups {
                let entries = (group["hooks"] as? [[String: Any]]) ?? []
                let survivors = entries.filter { ($0["command"] as? String)?.contains(marker) != true }
                if survivors.isEmpty, !entries.isEmpty { continue }
                group["hooks"] = survivors
                kept.append(group)
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    // MARK: - File handling

    /// Reads, transforms, backs up, and writes atomically.
    private static func rewrite(
        settingsPath: String,
        transform: (inout [String: Any]) throws -> [String: Any]
    ) throws {
        let manager = FileManager.default
        var root: [String: Any] = [:]

        if manager.fileExists(atPath: settingsPath) {
            guard let data = manager.contents(atPath: settingsPath) else {
                throw InstallError.unreadable(settingsPath)
            }
            if data.isEmpty {
                root = [:]
            } else {
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw InstallError.notAnObject(settingsPath)
                }
                root = object
                // One backup per change, so the previous good file is always recoverable.
                try? data.write(to: URL(fileURLWithPath: settingsPath + ".agent-island.bak"))
            }
        } else {
            IslandPaths.ensureDirectory((settingsPath as NSString).deletingLastPathComponent)
        }

        let updated = try transform(&root)
        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        do {
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        } catch {
            throw InstallError.writeFailed(settingsPath, error)
        }
    }
}
