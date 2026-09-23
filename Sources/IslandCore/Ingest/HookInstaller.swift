import Foundation

/// Adds and removes the Agent Island hook entries in the agents' own settings files.
///
/// Every entry runs the same small binary with `async: true`, so no hook ever blocks
/// a turn, and none of them print anything, so none can change a permission decision.
public enum HookInstaller {
    public static let marker = "agent-island-hook"

    /// Claude Code events worth a status change, with the tool matcher where one helps.
    public static let claudeEvents: [(event: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("UserPromptExpansion", nil),
        ("PreToolUse", "AskUserQuestion|ExitPlanMode"),
        ("PostToolUse", nil),
        ("PostToolUseFailure", nil),
        ("PermissionRequest", nil),
        ("PermissionDenied", nil),
        ("Notification", nil),
        ("Stop", nil),
        ("StopFailure", nil),
        ("SessionEnd", nil),
        ("PreCompact", nil),
        ("PostCompact", nil),
    ]

    /// Codex uses the same schema, minus the events it does not emit.
    public static let codexEvents: [(event: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", nil),
        ("PostToolUse", nil),
        ("PermissionRequest", nil),
        ("Stop", nil),
        ("Interrupt", nil),
        ("SessionEnd", nil),
    ]

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

    /// Events this version listens for that have no Agent Island hook in the settings
    /// file yet, as after an update that added some.
    public static func missingEvents(settingsPath: String, agent: AgentKind) -> [String] {
        let events = (agent == .claude ? claudeEvents : codexEvents).map(\.event)
        let hooks = readHooks(settingsPath: settingsPath) ?? [:]
        return events.filter { ourCommands(in: hooks[$0] as Any).isEmpty }
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
        let events = agent == .claude ? claudeEvents : codexEvents
        try rewrite(settingsPath: settingsPath) { root in
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            hooks = stripOurEntries(from: hooks)

            for (event, matcher) in events {
                var groups = (hooks[event] as? [[String: Any]]) ?? []
                var group: [String: Any] = [
                    "hooks": [[
                        "type": "command",
                        "command": binaryPath,
                        "args": [agent.rawValue],
                        "async": true,
                        "timeout": 5,
                    ]],
                ]
                if let matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[event] = groups
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
