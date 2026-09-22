import Foundation

/// Follows Codex rollout files, which are the live transcript of every thread.
///
/// Only root threads get a circle. Subagent rollouts carry a `parent_thread_id`
/// and are skipped, the same way Claude subagent hooks roll up into their parent.
public actor CodexRolloutWatcher {
    private let sessionsDirectory: String
    private let index: CodexThreadIndex
    private let emit: @Sendable (AgentEvent) -> Void
    private var watcher: DirectoryWatcher?
    private var tailer = FileTailer()
    private var parsers: [String: CodexRolloutParser] = [:]
    private var knownTitles: [String: String] = [:]

    /// A rollout touched this recently is replayed on startup so a turn already in
    /// flight shows up straight away.
    private let replayWindow: TimeInterval = 30 * 60

    public init(
        sessionsDirectory: String = IslandPaths.codexSessions,
        index: CodexThreadIndex = CodexThreadIndex(),
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.index = index
        self.emit = emit
    }

    public func start() {
        watcher = DirectoryWatcher(paths: [sessionsDirectory], pollInterval: 1.5) { [weak self] in
            guard let self else { return }
            Task { await self.scan() }
        }
        Task { await scan() }
    }

    public func stop() { watcher = nil }

    /// Today's and yesterday's `YYYY/MM/DD` folders, which is where anything live lives.
    private func recentDirectories(now: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.timeZone = .current
        return [now, now.addingTimeInterval(-86_400)].map {
            (sessionsDirectory as NSString).appendingPathComponent(formatter.string(from: $0))
        }
    }

    public func scan(now: Date = Date()) {
        let manager = FileManager.default
        for directory in recentDirectories(now: now) {
            guard let names = try? manager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                process(path: (directory as NSString).appendingPathComponent(name), now: now)
            }
        }
    }

    private func process(path: String, now: Date) {
        let isNew = parsers[path] == nil

        if isNew {
            parsers[path] = CodexRolloutParser(
                fallbackThreadID: CodexRolloutParser.threadID(fromFileName: path)
            )
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
                ?? nil
            guard now.timeIntervalSince(modified ?? .distantPast) < replayWindow else {
                // An old thread: skip to the end so only new activity counts.
                _ = tailer.newLines(at: path, readFromStart: false)
                return
            }
        }

        let lines = tailer.newLines(at: path, readFromStart: isNew)
        guard !lines.isEmpty, var parser = parsers[path] else { return }

        for line in lines {
            for event in parser.events(for: line, now: now) {
                emit(decorate(event))
            }
            if parser.isSubagent { break }
        }
        parsers[path] = parser
    }

    /// Fills in the chat title from Codex's own thread database.
    private func decorate(_ event: CodexEvent) -> AgentEvent {
        switch event.kind {
        case .discovered(let cwd, _):
            let row = index.row(threadID: event.threadID)
            if let title = row?.title { knownTitles[event.threadID] = title }
            return .codex(CodexEvent(
                threadID: event.threadID,
                kind: .discovered(cwd: cwd.isEmpty ? (row?.cwd ?? "") : cwd, title: row?.title),
                at: event.at
            ))
        case .taskComplete where knownTitles[event.threadID] == nil:
            // Titles are generated after the first turn, so look again once one lands.
            if let row = index.row(threadID: event.threadID), let title = row.title {
                knownTitles[event.threadID] = title
                emit(.codex(CodexEvent(
                    threadID: event.threadID,
                    kind: .discovered(cwd: row.cwd ?? "", title: title),
                    at: event.at
                )))
            }
            return .codex(event)
        default:
            return .codex(event)
        }
    }
}
