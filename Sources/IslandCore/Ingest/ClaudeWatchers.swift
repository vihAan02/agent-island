import Foundation

/// Watches `~/.claude/sessions`, the registry the CLI keeps for every live session.
///
/// This is what finds sessions in the first place, and it carries the chat title,
/// the working directory, and busy/idle. The effort level and the ultracode flag
/// come from the process arguments of the same pid.
public actor ClaudeRegistryWatcher {
    private let directory: String
    private let emit: @Sendable (AgentEvent) -> Void
    private var watcher: DirectoryWatcher?
    private var launchCache: [Int32: ProcessArgs.ClaudeLaunchInfo] = [:]
    private var lastEntries: [ClaudeRegistryEntry] = []

    public init(
        directory: String = IslandPaths.claudeSessions,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.directory = directory
        self.emit = emit
    }

    public func start() {
        watcher = DirectoryWatcher(paths: [directory], pollInterval: 2.0) { [weak self] in
            guard let self else { return }
            Task { await self.scan() }
        }
        Task { scan() }
    }

    public func stop() {
        watcher = nil
    }

    /// Reads every registry file and emits the current picture.
    public func scan() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return }

        var entries: [ClaudeRegistryEntry] = []
        var alivePIDs: Set<Int32> = []

        for name in names {
            // `<pid>.<hash>.key` files hold peer tokens; only the plain json files matter.
            guard name.hasSuffix(".json"), !name.contains(".key") else { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            guard
                let data = manager.contents(atPath: path),
                var entry = ClaudeRegistryEntry.decode(data)
            else { continue }

            entry.isAlive = ProcessArgs.isAlive(pid: entry.pid)
            if entry.isAlive {
                alivePIDs.insert(entry.pid)
                let info = launchCache[entry.pid] ?? {
                    let fresh = ProcessArgs.claudeLaunchInfo(pid: entry.pid)
                    launchCache[entry.pid] = fresh
                    return fresh
                }()
                entry.effort = info.effort
                entry.isUltra = info.isUltra
            }
            entries.append(entry)
        }

        launchCache = launchCache.filter { alivePIDs.contains($0.key) }

        guard entries != lastEntries else { return }
        lastEntries = entries
        emit(.claudeRegistry(entries))
    }
}

/// Follows Claude transcripts for the signals the registry cannot give:
/// the per-turn effort level, and, when hooks are not installed, questions,
/// plan-ready, and API errors.
public actor ClaudeTranscriptWatcher {
    private struct Followed {
        var path: String
        var firstRead: Bool = true
    }

    private let projectsDirectory: String
    private let emit: @Sendable (AgentEvent) -> Void
    private var followed: [String: Followed] = [:]
    private var tailer = FileTailer()
    private var timer: Task<Void, Never>?

    public init(
        projectsDirectory: String = IslandPaths.claudeProjects,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.projectsDirectory = projectsDirectory
        self.emit = emit
    }

    public func start(interval: Duration = .milliseconds(700)) {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pump()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Keeps the followed set in step with the live sessions.
    public func follow(sessionID: String, path: String?) {
        if let path, FileManager.default.fileExists(atPath: path) {
            if followed[sessionID]?.path != path {
                followed[sessionID] = Followed(path: path)
            }
            return
        }
        guard followed[sessionID] == nil, let found = locateTranscript(sessionID: sessionID) else { return }
        followed[sessionID] = Followed(path: found)
    }

    public func unfollow(sessionID: String) {
        if let entry = followed.removeValue(forKey: sessionID) {
            tailer.forget(entry.path)
        }
    }

    /// Transcripts live in `~/.claude/projects/<mangled cwd>/<session id>.jsonl`.
    private func locateTranscript(sessionID: String) -> String? {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(atPath: projectsDirectory) else { return nil }
        for project in projects {
            let candidate = (projectsDirectory as NSString)
                .appendingPathComponent(project)
                .appending("/\(sessionID).jsonl")
            if manager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func pump() {
        for (sessionID, entry) in followed {
            let lines = tailer.newLines(at: entry.path, readFromStart: entry.firstRead)
            if entry.firstRead { followed[sessionID]?.firstRead = false }
            for line in lines {
                for signal in Self.signals(in: line) {
                    emit(.claudeTranscript(sessionID: sessionID, signal: signal))
                }
            }
        }
    }

    /// Pulls the signals out of one transcript line. Static so it can be tested directly.
    public static func signals(in line: Data) -> [TranscriptSignal] {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        var signals: [TranscriptSignal] = []

        if let effort = EffortTier.parse(object["effort"] as? String) {
            signals.append(.effort(effort))
        }
        if (object["isApiErrorMessage"] as? Bool) == true {
            let text = Self.firstText(in: object)
            signals.append(.apiError(text))
            return signals
        }
        guard (object["type"] as? String) == "assistant" else { return signals }
        signals.append(.assistantActivity)

        let message = object["message"] as? [String: Any]
        let content = (message?["content"] as? [[String: Any]]) ?? []
        for block in content where (block["type"] as? String) == "tool_use" {
            switch block["name"] as? String {
            case "AskUserQuestion":
                signals.append(.askingQuestion(
                    ToolSummary.describe(toolName: "AskUserQuestion", toolInput: block["input"])
                ))
            case "ExitPlanMode":
                signals.append(.planReady)
            default:
                break
            }
        }
        return signals
    }

    private static func firstText(in object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return String(text.prefix(120)) }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where (block["type"] as? String) == "text" {
            if let text = block["text"] as? String { return String(text.prefix(120)) }
        }
        return nil
    }
}
