import AppKit
import IslandCore
import SwiftUI

/// `AgentIsland --render <directory>` draws the island offscreen into PNGs.
///
/// Used to check the emerge animation, every status, and every effort tier without
/// having to catch them live on screen.
@MainActor
enum RenderMode {
    /// A stand-in desktop behind the island, so black-on-black is still readable.
    private static let backdrop = Color(red: 0.16, green: 0.17, blue: 0.20)

    static func run(outputDirectory: String) {
        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        write(emergeSheet(), to: directory.appendingPathComponent("emerge.png"))
        write(statusSheet(), to: directory.appendingPathComponent("statuses.png"))
        write(effortSheet(), to: directory.appendingPathComponent("efforts.png"))
        write(cardSheet(), to: directory.appendingPathComponent("card.png"))
        write(commandSheet(), to: directory.appendingPathComponent("command.png"))
        // Scroll views and text fields only draw through AppKit.
        writeThroughWindow(conversationSheet(), size: CGSize(width: 1410, height: 520),
                           to: directory.appendingPathComponent("conversation.png"))
        write(dragSheet(), to: directory.appendingPathComponent("drag.png"))
        write(modelDragSheet(), to: directory.appendingPathComponent("drag-model.png"))
        write(mascotSheet(), to: directory.appendingPathComponent("mascots.png"))
        writeWindowPages(to: directory)
    }

    // MARK: - Main window

    /// Each page of the main window, with a few sample sessions, drawn from a real
    /// window kept out of sight. AppKit controls only draw properly through AppKit,
    /// so this goes through `cacheDisplay` rather than `ImageRenderer`.
    private static func writeWindowPages(to directory: URL) {
        let model = IslandModel(settings: AppEnvironment.shared.settings)
        for event in sampleEvents() { model.handle(event) }

        let state = MainWindowState()
        let hosting = NSHostingController(
            rootView: MainWindowView(state: state, model: model, hooks: AppEnvironment.shared.hooks)
        )
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Agent Island"
        window.setContentSize(NSSize(width: 800, height: 540))
        window.alphaValue = 0
        window.orderFrontRegardless()

        for section in MainSection.allCases {
            state.section = section
            // Give SwiftUI and the list a moment to lay out and load their rows.
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))

            guard let frame = window.contentView?.superview ?? window.contentView,
                  let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
            else { continue }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)

            let url = directory.appendingPathComponent("window-\(section.rawValue).png")
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                print("wrote \(url.path)")
            }
        }
        window.orderOut(nil)
    }

    /// Draws a view in a real window kept out of sight, for views ImageRenderer
    /// leaves blank: scroll views and text fields.
    private static func writeThroughWindow(_ view: some View, size: CGSize, to url: URL) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("wrote \(url.path)")
        }
        window.orderOut(nil)
    }

    private static func sampleEvents() -> [AgentEvent] {
        let cwd = FileManager.default.currentDirectoryPath
        return [
            .claudeRegistry([
                ClaudeRegistryEntry(pid: 90001, sessionID: "sample-1", cwd: cwd, name: "Refactor the liquid layer", status: "busy", effort: .xhigh, isUltra: true),
                ClaudeRegistryEntry(pid: 90002, sessionID: "sample-2", cwd: cwd, name: "Fix the flaky clock test", status: "busy", effort: .max),
            ]),
            .hook(HookEvent(
                kind: .claude,
                name: .permissionRequest,
                sessionID: "sample-2",
                cwd: cwd,
                toolName: "Bash",
                toolSummary: "Bash(npm test -- --runInBand)"
            )),
            .codex(CodexEvent(threadID: "sample-3", kind: .discovered(cwd: "/Users/me/ocr", title: "Port the parser to Rust"))),
            .codex(CodexEvent(threadID: "sample-3", kind: .turnContext(effort: .ultra, planMode: false))),
            .codex(CodexEvent(threadID: "sample-3", kind: .taskStarted)),
        ]
    }

    // MARK: - Sheets

    /// The first circle pulling out of the notch, frame by frame.
    private static func emergeSheet() -> some View {
        let geometry = sampleGeometry()
        let session = sampleSession(kind: .claude, status: .working, effort: .xhigh, ultra: true)
        let times: [Double] = [0, 0.06, 0.12, 0.18, 0.26, 0.4, 0.7]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(times, id: \.self) { time in
                labeled("t = \(String(format: "%.2f", time))s") {
                    band(geometry: geometry) {
                        [
                            layout(session: session, side: .left, rank: 0, geometry: geometry, progress: Spring.value(time: time)),
                        ]
                    }
                }
            }
        }
        .background(backdrop)
    }

    /// Every ring state, for both agents.
    private static func statusSheet() -> some View {
        let geometry = sampleGeometry()
        let statuses: [AgentStatus] = [.working, .question, .plan, .error, .complete, .idle]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(statuses, id: \.self) { status in
                labeled(status.rawValue) {
                    band(geometry: geometry) {
                        [
                            layout(
                                session: sampleSession(kind: .claude, status: status, effort: .high),
                                side: .left, rank: 0, geometry: geometry, progress: 1
                            ),
                            layout(
                                session: sampleSession(kind: .codex, status: status, effort: .high),
                                side: .left, rank: 1, geometry: geometry, progress: 1
                            ),
                        ]
                    }
                }
            }
        }
        .background(backdrop)
    }

    /// Every effort tier, Claude next to the notch, Codex beside it.
    private static func effortSheet() -> some View {
        let geometry = sampleGeometry()
        let tiers: [EffortTier] = [.low, .medium, .high, .xhigh, .max, .ultra]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(tiers, id: \.self) { tier in
                labeled(tier == .ultra ? "ultra / ultracode" : tier.label) {
                    band(geometry: geometry) {
                        [
                            layout(
                                session: sampleSession(
                                    kind: .claude, status: .working, effort: tier, ultra: tier == .ultra
                                ),
                                side: .left, rank: 0, geometry: geometry, progress: 1
                            ),
                            layout(
                                session: sampleSession(
                                    kind: .codex, status: .working, effort: tier, ultra: tier == .ultra
                                ),
                                side: .left, rank: 1, geometry: geometry, progress: 1
                            ),
                        ]
                    }
                }
            }
        }
        .background(backdrop)
    }

    /// Hovering, then clicking: the circle swells a touch under the pointer, then
    /// pours down into its card, frame by frame, and the card shows what the agent
    /// is doing, its diff, and its mode.
    private static func cardSheet() -> some View {
        let geometry = sampleGeometry()
        var first = sampleSession(kind: .claude, status: .working, effort: .xhigh, ultra: true,
                                  title: "Refactor the liquid layer", detail: "Edit(IslandModel.swift)")
        first.permissionMode = "acceptEdits"
        var second = sampleSession(kind: .codex, status: .working, effort: .ultra, title: "Choose F1 prediction model")
        second.permissionMode = "workspace-write"
        let sessions = [
            first,
            second,
            sampleSession(kind: .claude, status: .plan, effort: .low, title: "Fix flaky test"),
            sampleSession(kind: .codex, status: .complete, effort: .high, title: "Review notebook"),
        ]
        let layouts = sessions.enumerated().map { index, session in
            layout(session: session, side: .left, rank: index, geometry: geometry, progress: 1)
        }
        var hovered = layouts
        hovered[0].hoverScale = 1.14
        let diff = DiffState.ready(DiffStat(added: 128, removed: 14, files: 3))

        func frame(_ label: String, layouts: [BubbleLayout], openness: Double?) -> some View {
            labeled(label) {
                IslandContent(
                    geometry: geometry,
                    layouts: layouts,
                    clock: 1.1,
                    petID: PetCatalog.preferredPetID(),
                    card: openness.map { IslandCardState(id: layouts[0].id, openness: $0, diff: diff) }
                )
                .frame(height: 150, alignment: .top)
                .clipped()
            }
        }

        return VStack(alignment: .leading, spacing: 0) {
            frame("resting", layouts: layouts, openness: nil)
            frame("hovered: a slight swell, nothing else", layouts: hovered, openness: nil)
            ForEach([0.2, 0.45, 0.7], id: \.self) { openness in
                frame("clicked: pouring, \(Int(openness * 100))%", layouts: layouts, openness: openness)
            }
            frame("open: click the card to go to the chat", layouts: layouts, openness: 1)
        }
        .background(backdrop)
    }

    /// The card dropped down: a question to answer, a plan to approve, and the
    /// timeline with the message field, side by side.
    private static func conversationSheet() -> some View {
        let geometry = sampleGeometry()
        let start = Date().addingTimeInterval(-300)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

        let activity: [ActivityItem] = [
            ActivityItem(kind: .prompt, text: "Make the circles draggable to either side of the notch", at: at(0)),
            ActivityItem(kind: .reply, text: "I'll add a spring-driven drag, then let the arrangement decide which side a dropped circle lands on.", at: at(0.2)),
            ActivityItem(kind: .tool, text: "Read(IslandModel.swift)", at: at(0.4)),
            ActivityItem(kind: .tool, text: "Grep(pressBegan)", at: at(0.5)),
            ActivityItem(kind: .tool, text: "Edit(IslandArrangement.swift)", at: at(1)),
            ActivityItem(kind: .error, text: "error: cannot use mutating member on immutable value", at: at(1.5)),
            ActivityItem(kind: .tool, text: "Edit(ArrangementTests.swift)", at: at(2)),
            ActivityItem(kind: .tool, text: "Bash(swift test)", at: at(2.5)),
            ActivityItem(kind: .reply, text: "All 63 tests pass. Circles now spring to the side they are dropped on, and a full side sends them back.", at: at(3)),
            ActivityItem(kind: .sent, text: "Now make the landing a bit bouncier", at: at(4)),
        ]
        let questions = PendingAsk.questions([
            AgentQuestion(
                question: "Which database should the sync service use?",
                header: "Database",
                options: [
                    .init(label: "Postgres (Recommended)", description: "Relational, and already in the stack"),
                    .init(label: "SQLite", description: "One file, no server to run"),
                    .init(label: "DynamoDB", description: "Serverless, pay per request"),
                ]
            ),
        ])
        let plan = PendingAsk.plan("""
            # Drag circles between sides

            ## Context
            Circles all sit left of the notch. Users want to move them.

            ## Steps
            1. Track presses in `IslandHostingView`, so drags survive leaving the circle.
            2. Add `IslandArrangement.move(_:to:at:)`, refusing a full side.
            3. Throw the circle on release with **60%** of the pointer's speed.
            """)

        func card(_ label: String, session: AgentSession, conversation: CardConversation, draft: String = "") -> some View {
            let layout = layout(session: session, side: .left, rank: 0, geometry: geometry, progress: 1)
            var actions = CardActions.inert
            actions.draft = .constant(draft)
            return labeled(label) {
                IslandContent(
                    geometry: geometry,
                    layouts: [layout],
                    clock: 1.1,
                    petID: PetCatalog.preferredPetID(),
                    card: IslandCardState(
                        id: layout.id,
                        openness: 1,
                        details: 1,
                        diff: .ready(DiffStat(added: 128, removed: 14, files: 3)),
                        conversation: conversation
                    ),
                    actions: actions
                )
                .frame(width: 470, height: 500, alignment: .topLeading)
                .clipped()
            }
        }

        var asking = sampleSession(kind: .claude, status: .question, effort: .high, title: "Sync service",
                                   detail: "Which database should the sync service use?")
        asking.permissionMode = "auto"
        var planning = sampleSession(kind: .claude, status: .plan, effort: .xhigh, title: "Drag circles between sides",
                                     detail: "Plan ready for review")
        planning.planMode = true
        var done = sampleSession(kind: .claude, status: .complete, effort: .xhigh, ultra: true,
                                 title: "Dynamic island floating chat app")
        done.permissionMode = "acceptEdits"

        return HStack(alignment: .top, spacing: 0) {
            card("a question: click an option to answer",
                 session: asking,
                 conversation: CardConversation(ask: questions, activity: Array(activity.prefix(3)), route: .whenDone, queued: nil, notice: nil))
            card("a plan: approve, or type what to change",
                 session: planning,
                 conversation: CardConversation(ask: plan, activity: Array(activity.prefix(2)), route: .whenDone, queued: nil, notice: nil))
            card("done: the timeline, and the next message",
                 session: done,
                 conversation: CardConversation(ask: nil, activity: activity, route: .paste, queued: nil, notice: nil),
                 draft: "Now make the landing a bit bouncier")
        }
        .background(backdrop)
    }

    /// A slash command running: the circle turns into a white spinner, shown step by
    /// step beside a circle at work, and beside a question, which it never hides.
    private static func commandSheet() -> some View {
        let geometry = sampleGeometry()

        func running(_ kind: AgentKind, _ name: String, startedAgo: Double = 2, status: AgentStatus = .working) -> AgentSession {
            var session = sampleSession(kind: kind, status: status, effort: .xhigh, title: "Dynamic island floating chat app")
            session.id += "-\(name)-\(startedAgo)"
            session.command = SlashCommand(name: name, startedAt: Date().addingTimeInterval(-startedAgo))
            return session
        }
        let sessions = [
            running(.claude, SlashCommand.compact),
            sampleSession(kind: .claude, status: .working, effort: .xhigh),
            running(.codex, "review"),
            running(.claude, "review", status: .question),
        ]
        let layouts = sessions.enumerated().map { index, session in
            layout(session: session, side: .left, rank: index, geometry: geometry, progress: 1)
        }
        // Rank 0 sits by the notch, so the earliest frame goes furthest out, on the left.
        let fading = [0.3, 0.15, 0.05].enumerated().map { index, ago in
            layout(session: running(.claude, SlashCommand.compact, startedAgo: ago), side: .left, rank: index, geometry: geometry, progress: 1)
        }
        let steps: [(String, Double)] = [
            ("/compact, /review, beside working and a question", 1.1),
            ("one step on", 1.1 + 1.0 / 12),
            ("two steps on", 1.1 + 2.0 / 12),
            ("between blinks", 1.65),
        ]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(steps, id: \.1) { label, clock in
                labeled(label) { band(geometry: geometry, clock: clock) { layouts } }
            }
            labeled("fading in: 0.05s, 0.15s, 0.3s") { band(geometry: geometry) { fading } }
            labeled("open: what the command is doing") {
                IslandContent(
                    geometry: geometry,
                    layouts: layouts,
                    clock: 1.1,
                    petID: PetCatalog.preferredPetID(),
                    card: IslandCardState(id: layouts[0].id, openness: 1, diff: .ready(DiffStat(added: 42, removed: 7, files: 2)))
                )
                .frame(height: 150, alignment: .top)
                .clipped()
            }
        }
        .background(backdrop)
    }

    /// One circle dragged from the left, across the notch, and let go on the right,
    /// then the landing, frame by frame: the others close up behind it, and it
    /// overshoots its place and swings back.
    private static func dragSheet() -> some View {
        let geometry = sampleGeometry()
        let sessions = [
            sampleSession(kind: .claude, status: .working, effort: .xhigh, ultra: true, title: "a"),
            sampleSession(kind: .codex, status: .working, effort: .high, title: "b"),
            sampleSession(kind: .claude, status: .question, effort: .max, title: "c"),
        ]
        let dragged = sessions[1]
        let rest = geometry.notchRect.midY
        let target = geometry.slotCenter(side: .right, rank: 0)
        let letGo = CGPoint(x: target.x + 34, y: rest + 5)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var x = SpringMotion(at: 0, now: start)
        x.release(from: letGo.x, velocity: 700, to: target.x, at: start)
        var y = SpringMotion(at: 0, now: start)
        y.release(from: letGo.y, velocity: 0, to: rest, at: start)

        func frame(_ label: String, dragAt: CGPoint?, others: [(AgentSession, Int)], landed: CGPoint?) -> some View {
            var layouts = others.map { session, rank in
                layout(session: session, side: .left, rank: rank, geometry: geometry, progress: 1)
            }
            if let dragAt {
                var held = layout(session: dragged, side: geometry.side(for: dragAt.x), rank: 0, geometry: geometry, progress: 1)
                held.center = dragAt
                layouts.append(held)
            }
            if let landed {
                var down = layout(session: dragged, side: .right, rank: 0, geometry: geometry, progress: 1)
                down.center = landed
                layouts.append(down)
            }
            return labeled(label) { band(geometry: geometry) { layouts } }
        }

        let leftOrigin = geometry.slotCenter(side: .left, rank: 1)
        let times: [Double] = [0, 0.06, 0.12, 0.2, 0.3, 0.45, 0.8]

        return VStack(alignment: .leading, spacing: 0) {
            frame("picked up", dragAt: CGPoint(x: leftOrigin.x, y: rest + 5),
                  others: [(sessions[0], 0), (sessions[2], 2)], landed: nil)
            frame("crossing the notch", dragAt: CGPoint(x: geometry.notchRect.minX + 18, y: rest + 5),
                  others: [(sessions[0], 0), (sessions[2], 1)], landed: nil)
            frame("over the right side", dragAt: letGo,
                  others: [(sessions[0], 0), (sessions[2], 1)], landed: nil)
            ForEach(times, id: \.self) { time in
                let moment = start.addingTimeInterval(time)
                frame("let go, t = \(String(format: "%.2f", time))s", dragAt: nil,
                      others: [(sessions[0], 0), (sessions[2], 1)],
                      landed: CGPoint(x: x.value(at: moment), y: y.value(at: moment)))
            }
        }
        .background(backdrop)
    }

    /// The same drag, but driven through the real model with made-up pointer events:
    /// press, drag across the notch, let go. What it draws is what the model decided.
    private static func modelDragSheet() -> some View {
        let geometry = sampleGeometry()
        let model = IslandModel(settings: AppEnvironment.shared.settings)
        model.geometry = geometry
        for event in sampleEvents() { model.handle(event) }
        // The emerge springs run on the wall clock.
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))

        var frames: [(String, [BubbleLayout])] = []
        func snapshot(_ label: String) {
            let layouts = IslandLayout.layouts(for: model.bubbles, geometry: geometry, now: Date(), drag: model.liveDrag)
            frames.append((label, layouts))
        }
        snapshot("before: " + describe(model.bubbles))

        // Pick up the second circle on the left and carry it past the notch.
        let picked = model.bubbles.first { $0.side == .left && $0.rank == 1 }
        if let picked {
            let from = picked.restingCenter
            let to = CGPoint(x: geometry.slotCenter(side: .right, rank: 0).x + 26, y: from.y + 4)
            model.pressBegan(on: picked.id, at: from)
            let steps = 16
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                model.pressMoved(to: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                RunLoop.main.run(until: Date().addingTimeInterval(0.016))
                if step == 4 { snapshot("dragging: the others close up") }
                if step == 10 { snapshot("dragging: over the notch") }
            }
            snapshot("dragging: over the right side")
            model.pressEnded(at: to)

            let letGo = Date()
            for t in [0.0, 0.06, 0.14, 0.25, 0.4, 0.7, 1.2] {
                let layouts = IslandLayout.layouts(for: model.bubbles, geometry: geometry, now: letGo.addingTimeInterval(t))
                frames.append((String(format: "let go, t = %.2fs", t), layouts))
            }
            frames.append(("after: " + describe(model.bubbles), frames.last?.1 ?? []))
        }

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                labeled(frame.0) { band(geometry: geometry) { frame.1 } }
            }
        }
        .background(backdrop)
    }

    private static func describe(_ bubbles: [Bubble]) -> String {
        bubbles.map { bubble in
            let name = bubble.session.displayTitle.split(separator: " ").first.map(String.init) ?? "?"
            return "\(name) \(bubble.side?.rawValue ?? "none") \(bubble.rank)"
        }.joined(separator: ", ")
    }

    /// Both mascots, drawn large, in every status. This is the sheet to look at when
    /// tuning the sprites themselves.
    private static func mascotSheet() -> some View {
        let statuses: [AgentStatus] = [.working, .question, .plan, .error, .complete, .idle]
        let size: CGFloat = 120

        return VStack(alignment: .leading, spacing: 10) {
            ForEach([0.0, 0.35, 0.7], id: \.self) { clock in
                HStack(spacing: 14) {
                    ForEach(statuses, id: \.self) { status in
                        VStack(spacing: 4) {
                            ZStack {
                                Circle().fill(.black)
                                ClawdView(
                                    status: status,
                                    color: IslandStyle.claude,
                                    clock: clock,
                                    secondsInStatus: 0.9
                                )
                                .frame(width: size * 0.66)
                            }
                            .frame(width: size, height: size)

                            ZStack {
                                Circle().fill(.black)
                                CodexPetView(
                                    petID: PetCatalog.preferredPetID(),
                                    status: status,
                                    clock: clock,
                                    secondsInStatus: 0.9,
                                    fallbackColor: IslandStyle.codex
                                )
                                .frame(width: size * 0.8, height: size * 0.8)
                            }
                            .frame(width: size, height: size)

                            Text(status.rawValue)
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(backdrop)
    }

    // MARK: - Pieces

    private static func band(
        geometry: NotchGeometry,
        clock: Double = 1.1,
        layouts: () -> [BubbleLayout]
    ) -> some View {
        IslandContent(
            geometry: geometry,
            layouts: layouts(),
            clock: clock,
            petID: PetCatalog.preferredPetID()
        )
        .frame(height: 56, alignment: .top)
        .clipped()
    }

    private static func labeled(_ text: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 10)
            content()
        }
        .padding(.vertical, 5)
    }

    private static func sampleGeometry() -> NotchGeometry {
        // A 14-inch MacBook Pro: 1512pt wide, a 186pt notch, and the island window
        // hugging it with room for four circles a side.
        let extent: CGFloat = 12 + 4 * (28 + 8) + 16
        return NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            panelFrame: CGRect(x: 663 - extent, y: 0, width: 186 + extent * 2, height: NotchGeometry.panelHeight),
            notchRect: CGRect(x: extent, y: 0, width: 186, height: 32),
            hasRealNotch: true
        )
    }

    private static func sampleSession(
        kind: AgentKind,
        status: AgentStatus,
        effort: EffortTier,
        ultra: Bool = false,
        title: String = "Sample session",
        detail: String? = nil
    ) -> AgentSession {
        var session = AgentSession(
            id: "\(kind.rawValue)-\(status.rawValue)-\(effort.rawValue)-\(ultra)",
            kind: kind,
            host: kind == .claude ? .claudeDesktop : .codexDesktop,
            title: title,
            effort: effort,
            isUltra: ultra
        )
        session.status = status
        session.repo = "agent-island"
        session.branch = "main"
        session.detail = detail
        // Push the status change back a little so one-shot animations are past their flash.
        session.statusChangedAt = Date().addingTimeInterval(-0.9)
        return session
    }

    private static func layout(
        session: AgentSession,
        side: IslandSide,
        rank: Int,
        geometry: NotchGeometry,
        progress: Double
    ) -> BubbleLayout {
        let start = geometry.slotOrigin(side: side)
        let end = geometry.slotCenter(side: side, rank: rank)
        return BubbleLayout(
            id: session.id,
            session: session,
            side: side,
            rank: rank,
            center: CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            ),
            diameter: geometry.circleDiameter,
            progress: progress
        )
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard
            let image = renderer.cgImage,
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else {
            NSLog("Agent Island: could not render \(url.lastPathComponent)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(url.path)")
    }
}
