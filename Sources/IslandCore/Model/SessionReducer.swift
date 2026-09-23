import Foundation

/// Folds every event source into the set of sessions on screen.
///
/// Pure value type with no UI and no I/O, so the whole state machine is testable.
public struct SessionReducer: Sendable {
    /// How long a finished session keeps its circle before it slides back into the notch.
    public var retireCompletedAfter: TimeInterval = 600
    /// How long a single failed tool call tints the ring red before returning to working.
    public var errorFlashDuration: TimeInterval = 2.5
    /// A session that has said nothing at all for this long is dropped.
    public var retireStaleAfter: TimeInterval = 3600
    /// A slash command that has gone this long without a word is taken to be over.
    /// Its end is always written down, but only in a transcript that may not be followed.
    public var commandTimeout: TimeInterval = 900

    public private(set) var sessions: [String: AgentSession] = [:]
    /// Insertion order, so a circle keeps its slot while others come and go.
    public private(set) var order: [String] = []

    /// Sessions that have delivered at least one hook. For those, file watching stops
    /// guessing at status and only fills in titles and effort.
    private var hooked: Set<String> = []
    /// Sessions the Claude registry listed last time, so the ones that vanish from it
    /// can be told apart from sessions it never knew about.
    private var registered: Set<String> = []

    public init() {}

    // MARK: - Reading

    /// Sessions that should have a circle, in slot order.
    public var visibleSessions: [AgentSession] {
        order.compactMap { sessions[$0] }.filter { $0.status.isOnStage }
    }

    public func session(id: String) -> AgentSession? { sessions[id] }

    public static func claudeID(_ sessionID: String) -> String { "claude:\(sessionID)" }
    public static func codexID(_ threadID: String) -> String { "codex:\(threadID)" }

    // MARK: - Applying events

    public mutating func apply(_ event: AgentEvent, now: Date = Date()) {
        switch event {
        case .hook(let hook):
            applyHook(hook, now: now)
        case .claudeRegistry(let entries):
            applyRegistry(entries, now: now)
        case .claudeTranscript(let sessionID, let signal):
            applyTranscript(sessionID: sessionID, signal: signal, now: now)
        case .codex(let codex):
            applyCodex(codex, now: now)
        }
    }

    // MARK: Hooks

    private mutating func applyHook(_ hook: HookEvent, now: Date) {
        // Subagent hooks roll up into their parent session; they get no circle of their own.
        let isSubagent = hook.agentID != nil
        let id = hook.kind == .claude
            ? Self.claudeID(hook.sessionID)
            : Self.codexID(hook.sessionID)

        if hook.name == .sessionEnd {
            retire(id, now: now)
            return
        }

        var session = sessions[id] ?? makeSession(id: id, kind: hook.kind, now: now)
        hooked.insert(id)
        session.lastActivity = now
        session.setCwd(hook.cwd)
        if let path = hook.transcriptPath { session.transcriptPath = path }
        if let effort = hook.effort { session.effort = effort }
        if session.host == .unknown { session.host = host(for: hook) }
        if let mode = hook.permissionMode {
            session.planMode = (mode == "plan")
            session.permissionMode = mode
        }

        switch hook.name {
        case .sessionStart:
            break

        case .userPromptSubmit:
            setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: now)
            if let name = hook.commandName {
                startCommand(&session, name: name, now: now)
            } else {
                session.command = nil
            }

        case .userPromptExpansion:
            setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: now)
            if let name = hook.commandName { startCommand(&session, name: name, now: now) }

        case .preCompact:
            // A subagent compacting its own context gets no PostCompact, and has no
            // circle of its own to show it on.
            guard !isSubagent else { break }
            let wasBusy = session.status == .working || session.status == .plan
            if wasBusy {
                session.detail = nil
            } else {
                setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: now)
            }
            session.command = SlashCommand(
                name: SlashCommand.compact,
                startedAt: now,
                endsTurn: hook.trigger.map { $0 == "manual" } ?? !wasBusy
            )

        case .postCompact:
            guard !isSubagent else { break }
            finishCommand(&session, named: SlashCommand.compact, now: now)

        case .preToolUse:
            switch hook.toolName {
            case "AskUserQuestion":
                setStatus(&session, .question, detail: hook.toolSummary, now: now)
            case "ExitPlanMode":
                // The plan is what the command was for; approving it starts a new stretch.
                session.command = nil
                setStatus(&session, .plan, detail: "Plan ready for review", now: now)
            default:
                if !isSubagent, session.status == .question || session.status == .error {
                    setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: now)
                }
                session.detail = hook.toolSummary
            }

        case .postToolUse:
            if session.status == .question || session.status == .error {
                setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: now)
            }
            // The last thing it did is the best word on what it is doing.
            if session.status == .working || session.status == .plan, let summary = hook.toolSummary {
                session.detail = summary
            }

        case .postToolUseFailure:
            guard !hook.isInterrupt else { break }
            setStatus(&session, .error, detail: hook.toolSummary ?? hook.errorText, now: now)
            session.flashRevertAt = now.addingTimeInterval(errorFlashDuration)

        case .permissionRequest:
            setStatus(&session, .question, detail: hook.toolSummary.map { "Needs approval: \($0)" }, now: now)

        case .permissionDenied:
            setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: now)

        case .notification:
            let type = hook.notificationType?.lowercased() ?? ""
            if type.contains("permission") || type.contains("input") || type.contains("question") {
                setStatus(&session, .question, detail: hook.message, now: now)
            } else if session.status == .working {
                session.detail = hook.message
            }

        case .stop:
            setStatus(&session, .complete, detail: nil, now: now)

        case .stopFailure:
            session.command = nil
            setStatus(&session, .error, detail: hook.errorText, now: now)

        case .interrupt:
            setStatus(&session, .idle, detail: nil, now: now)

        case .sessionEnd:
            break
        }

        store(session)
    }

    private func host(for hook: HookEvent) -> AgentHost {
        if hook.kind == .codex { return .codexDesktop }
        let bundle = hook.env["__CFBundleIdentifier"] ?? ""
        if bundle.contains("anthropic") { return .claudeDesktop }
        if hook.env["TERM_PROGRAM"] != nil || hook.env["TERM"] != nil { return .terminal }
        return .unknown
    }

    // MARK: Claude session registry

    private mutating func applyRegistry(_ entries: [ClaudeRegistryEntry], now: Date) {
        var seen: Set<String> = []

        for entry in entries {
            let id = Self.claudeID(entry.sessionID)
            seen.insert(id)

            guard entry.isAlive else {
                retire(id, now: now)
                continue
            }

            var session = sessions[id] ?? makeSession(id: id, kind: .claude, now: now)
            session.pid = entry.pid
            session.host = entry.host
            session.setCwd(entry.cwd)
            if let name = entry.name, !name.isEmpty { session.title = name }
            if let effort = entry.effort { session.effort = effort }
            session.isUltra = entry.isUltra

            // With hooks installed the registry is only a source of metadata. Without them,
            // busy/idle is the only status signal there is.
            if !hooked.contains(id) {
                switch entry.status {
                case "busy":
                    if session.status != .question, session.status != .plan {
                        setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: now)
                    }
                    session.lastActivity = now
                case "idle":
                    if session.status == .working {
                        setStatus(&session, .complete, detail: nil, now: now)
                    }
                default:
                    break
                }
            }
            store(session)
        }

        // Anything the registry listed and has now dropped is gone: the process exited.
        // Sessions it never listed, such as headless runs known only from hooks, end
        // with their own SessionEnd or go stale.
        for id in order where registered.contains(id) && !seen.contains(id) {
            retire(id, now: now)
        }
        registered = seen
    }

    // MARK: Claude transcript

    private mutating func applyTranscript(sessionID: String, signal: TranscriptSignal, now: Date) {
        let id = Self.claudeID(sessionID)
        guard var session = sessions[id] else { return }

        switch signal {
        case .effort(let tier):
            session.effort = tier
        case .permissionMode(let mode):
            session.permissionMode = mode
            session.planMode = (mode == "plan")
        case .assistantActivity:
            session.lastActivity = now
            if !hooked.contains(id), session.status == .complete || session.status == .idle {
                setStatus(&session, .working, detail: nil, now: now)
            }
        case .askingQuestion(let text):
            guard !hooked.contains(id) else { break }
            setStatus(&session, .question, detail: text, now: now)
        case .planReady:
            guard !hooked.contains(id) else { break }
            setStatus(&session, .plan, detail: "Plan ready for review", now: now)
        case .apiError(let text):
            setStatus(&session, .error, detail: text, now: now)
            session.flashRevertAt = now.addingTimeInterval(errorFlashDuration)
        case .commandFinished(let name, let at):
            // The first read of a transcript replays its past, so only an end written
            // after this command started can be this command's.
            guard let command = session.command, (at ?? now) > command.startedAt else { break }
            finishCommand(&session, named: name, now: now)
        }
        store(session)
    }

    // MARK: Codex

    private mutating func applyCodex(_ event: CodexEvent, now: Date) {
        let id = Self.codexID(event.threadID)
        var session = sessions[id] ?? makeSession(id: id, kind: .codex, now: now)
        session.host = .codexDesktop
        session.lastActivity = event.at

        switch event.kind {
        case .discovered(let cwd, let title):
            session.setCwd(cwd)
            if let title, !title.isEmpty { session.title = title }

        case .turnContext(let effort, let planMode, let sandbox):
            if let effort {
                session.effort = effort
                session.isUltra = (effort == .ultra)
            }
            session.planMode = planMode
            if let sandbox { session.permissionMode = sandbox }
            if planMode, session.status == .working {
                setStatus(&session, .plan, detail: nil, now: event.at)
            }

        case .taskStarted:
            setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: event.at)

        case .taskComplete:
            setStatus(&session, .complete, detail: nil, now: event.at)

        case .turnAborted:
            setStatus(&session, .idle, detail: nil, now: event.at)

        case .approvalRequest(let detail):
            setStatus(&session, .question, detail: detail.map { "Needs approval: \($0)" }, now: event.at)

        case .userInputRequest(let detail):
            setStatus(&session, .question, detail: detail, now: event.at)

        case .streamError(let text):
            setStatus(&session, .error, detail: text, now: event.at)

        case .activity:
            if session.status == .complete || session.status == .idle {
                setStatus(&session, .working, detail: nil, now: event.at)
            }

        case .toolCall(let detail):
            if session.status == .complete || session.status == .idle {
                setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: event.at)
            }
            if session.status == .working || session.status == .plan { session.detail = detail }
        }
        store(session)
    }

    // MARK: - Timers

    /// Advances time. Returns the ids that finished retiring and can be dropped.
    @discardableResult
    public mutating func tick(now: Date = Date()) -> [String] {
        var retired: [String] = []

        for id in order {
            guard var session = sessions[id] else { continue }

            if let revert = session.flashRevertAt, now >= revert, session.status == .error {
                session.flashRevertAt = nil
                setStatus(&session, session.planMode ? .plan : .working, detail: nil, now: now)
                store(session)
                continue
            }

            if session.status == .complete || session.status == .idle,
               now.timeIntervalSince(session.statusChangedAt) > retireCompletedAfter {
                retire(id, now: now)
                retired.append(id)
                continue
            }

            if let command = session.command, now.timeIntervalSince(session.lastActivity) > commandTimeout {
                finishCommand(&session, named: command.name, now: now)
                store(session)
            }

            if now.timeIntervalSince(session.lastActivity) > retireStaleAfter {
                retire(id, now: now)
                retired.append(id)
            }
        }
        return retired
    }

    /// Removes a retiring session once its animation has played.
    public mutating func drop(id: String) {
        sessions.removeValue(forKey: id)
        order.removeAll { $0 == id }
        hooked.remove(id)
        registered.remove(id)
    }

    /// Forgets a session the user dismissed by hand.
    public mutating func dismiss(id: String, now: Date = Date()) {
        retire(id, now: now)
    }

    /// Sends every session of one kind back into the notch, as when watching it is
    /// switched off.
    public mutating func retireAll(kind: AgentKind, now: Date = Date()) {
        for id in order where sessions[id]?.kind == kind {
            retire(id, now: now)
        }
    }

    /// Drops the sessions of one kind that are already on their way out, so a fresh
    /// scan can bring them straight back rather than landing on a retiring session.
    public mutating func dropRetiring(kind: AgentKind) {
        for id in order where sessions[id]?.kind == kind && sessions[id]?.isRetiring == true {
            drop(id: id)
        }
    }

    // MARK: - Helpers

    private mutating func makeSession(id: String, kind: AgentKind, now: Date) -> AgentSession {
        AgentSession(id: id, kind: kind, now: now)
    }

    /// Notes a slash command starting, keeping the one already running if this is
    /// the same command reported twice: UserPromptExpansion, then UserPromptSubmit.
    private func startCommand(_ session: inout AgentSession, name: String, now: Date) {
        guard session.command?.name != name else { return }
        session.command = SlashCommand(name: name, startedAt: now)
    }

    /// Ends a slash command. One typed at an idle prompt leaves the session done;
    /// one that ran inside a turn hands back to the turn.
    private mutating func finishCommand(_ session: inout AgentSession, named name: String, now: Date) {
        guard let command = session.command, command.name == name else { return }
        session.command = nil
        guard session.status == .working || session.status == .plan else { return }
        if command.endsTurn {
            setStatus(&session, .complete, detail: nil, now: now)
        } else {
            session.detail = nil
        }
    }

    private mutating func store(_ session: AgentSession) {
        if sessions[session.id] == nil { order.append(session.id) }
        sessions[session.id] = session
    }

    private mutating func setStatus(
        _ session: inout AgentSession,
        _ status: AgentStatus,
        detail: String?,
        now: Date
    ) {
        if session.status != status {
            session.status = status
            session.statusChangedAt = now
        }
        session.detail = detail
        session.lastActivity = now
        if status != .error { session.flashRevertAt = nil }
        // However the turn ended, nothing it started is still running.
        if status == .complete || status == .idle { session.command = nil }
    }

    private mutating func retire(_ id: String, now: Date) {
        guard var session = sessions[id], !session.isRetiring else { return }
        session.isRetiring = true
        session.statusChangedAt = now
        sessions[id] = session
    }
}
