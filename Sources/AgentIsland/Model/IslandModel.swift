import AppKit
import Foundation
import IslandCore
import Observation
import SwiftUI

/// One circle on screen: a session plus the animation bookkeeping for it.
struct Bubble: Identifiable, Equatable {
    var id: String
    var session: AgentSession
    /// The side it sits on, or nil while it waits inside the notch for room.
    var side: IslandSide?
    /// Places out from the notch, among the circles showing on that side.
    var rank: Int
    /// When the circle started sliding out of the notch.
    var appearedAt: Date
    /// When it started sliding back in, if it is on the way out.
    var retractingSince: Date?
    /// Its resting place beside the notch, on springs, so circles glide when they
    /// make room for one another or land after a drag.
    var x: SpringMotion
    var y: SpringMotion
    /// Its size under the pointer: 1, or a touch more while hovered.
    var hover: SpringMotion

    var isRetracting: Bool { retractingSince != nil }

    /// Where it is heading, or already sits.
    var restingCenter: CGPoint { CGPoint(x: x.to, y: y.to) }

    func isSliding(at now: Date) -> Bool {
        !x.isSettled(at: now) || !y.isSettled(at: now) || !hover.isSettled(at: now)
    }
}

/// How hard the island is animating right now.
///
/// This is a stored, observed property rather than something the view computes: a
/// TimelineView captures its schedule when the surrounding body runs, so the rate
/// only changes if that body is re-evaluated.
enum AnimationMode: Int, Comparable, Equatable {
    /// Nothing is moving; the island holds still and costs nothing.
    case paused
    /// A long-running turn with no news. The mascot keeps moving, at half rate.
    case calm
    /// Mascots, rings, and effort lights, right after something changed.
    case ambient
    /// A circle is sliding in or out of the notch, which deserves every frame.
    case emerging

    var minimumInterval: Double {
        switch self {
        // Each frame costs a full SwiftUI update, so the island only spends them
        // where they show: the pet sheets hold frames for 120ms or more.
        case .paused, .calm: 1.0 / 12.0
        case .ambient: 1.0 / 24.0
        case .emerging: 1.0 / 60.0
        }
    }

    var isPaused: Bool { self == .paused }

    static func < (a: AnimationMode, b: AnimationMode) -> Bool { a.rawValue < b.rawValue }
}

/// Owns the reducer, the watchers, and the display state of the island.
@MainActor
@Observable
final class IslandModel: IslandPointerTarget {
    private(set) var bubbles: [Bubble] = []
    private(set) var animationMode: AnimationMode = .paused
    private(set) var hookedSessionsSeen = false

    /// The circle under the pointer. It swells a little; nothing else happens until
    /// it is clicked.
    var hoveredID: String? {
        didSet {
            guard hoveredID != oldValue else { return }
            let now = Date()
            if let oldValue {
                hovers[oldValue, default: SpringMotion(at: 1, now: now)].retarget(to: 1, at: now, tuning: .hover)
            }
            if let hoveredID {
                hovers[hoveredID, default: SpringMotion(at: 1, now: now)]
                    .retarget(to: Self.hoverScale, at: now, tuning: .hover)
            }
            rebuild()
        }
    }

    /// The circle whose card is open. Clicking the circle opens and closes it; only
    /// clicking the card itself opens the chat. A click anywhere else closes it too.
    private(set) var expandedID: String? {
        didSet {
            guard expandedID != oldValue else { return }
            let now = Date()
            if let expandedID {
                // Switching straight to another circle pours its card out fresh.
                if oldValue != nil { cardOpenness = SpringMotion(at: 0, now: now) }
                cardID = expandedID
                cardOpenness.retarget(to: 1, at: now, tuning: .cardOpen)
                // A question or a plan waiting on the user opens straight onto it.
                setDetailsOpen(asks[expandedID] != nil, animated: oldValue != nil, at: now)
                onExpansionChanged?(true)
                refreshDiff(for: expandedID, force: true)
            } else {
                cardOpenness.retarget(to: 0, at: now, tuning: .cardClose)
                setDetailsOpen(false, animated: true, at: now)
                finishClosingCard()
            }
            updateAnimationMode()
            publishLayout()
        }
    }

    /// The circle whose card is drawn: the open one, or one still folding away.
    private(set) var cardID: String?
    /// 0 is the circle, 1 the full card. On a spring, so the circle pours down into
    /// the card and back up into itself.
    private(set) var cardOpenness = SpringMotion(at: 0, now: .distantPast)

    /// The card's drop-down: the question or plan waiting, the timeline, and a
    /// field for the next message.
    private(set) var detailsOpen = false
    /// 0 folded, 1 dropped down; the card's height follows it on a spring.
    private(set) var detailsOpenness = SpringMotion(at: 0, now: .distantPast)

    // MARK: Talking back

    /// Questions and plans the island can answer, by session.
    private(set) var asks: [String: PendingReply] = [:]
    /// Sessions whose turn has ended with a hook waiting to take their next message.
    private(set) var wakeChannels: [String: HookReplyChannel] = [:]
    /// Messages typed while the agent was busy, sent as soon as its turn ends.
    private(set) var queuedMessages: [String: String] = [:]
    /// Cards whose message is being pasted into the Claude app right now.
    private(set) var pasting: Set<String> = []
    /// A reply that could not be delivered, shown on the card until the next change.
    private(set) var replyNotices: [String: String] = [:]
    /// Each session's timeline, oldest first.
    private(set) var activity: [String: [ActivityItem]] = [:]
    /// What the user is typing on each card.
    var drafts: [String: String] = [:]
    /// Options picked on a question form, by session, then question.
    var picks: [String: [String: Set<String>]] = [:]

    /// Lines changed in each session folder, for the card.
    private(set) var diffs: [String: DiffState] = [:]
    @ObservationIgnored private var diffFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var diffsInFlight: Set<String> = []

    private static let hoverScale = 1.14
    private var hovers: [String: SpringMotion] = [:]

    /// Called when the card opens or finishes closing, so the window grows only
    /// while there is something below the menu bar to show.
    var onExpansionChanged: ((Bool) -> Void)?

    /// Where the notch is. Set by the panel controller and re-set when screens change.
    var geometry: NotchGeometry = .current() {
        didSet { publishLayout() }
    }

    /// Called with the rects that should take clicks: the circles, plus any open card.
    var onLayoutChanged: (([CGRect]) -> Void)?

    private var reducer = SessionReducer()
    /// Which circles sit on which side, in order out from the notch.
    private var arrangement = IslandArrangement(capacity: NotchGeometry.maximumPerSide)
    /// True while the pointer is at the notch, which pulls tucked circles back out.
    private var isPeeking = false
    private var motion: [String: CircleMotion] = [:]
    private var slides: [String: (x: SpringMotion, y: SpringMotion)] = [:]

    /// A press on a circle, which becomes a drag once the pointer moves far enough.
    private struct Press {
        var id: String
        var start: CGPoint
        /// From the pointer to the circle's centre, so the circle does not jump.
        var grab: CGSize
        var isDragging = false
        var samples: [(time: TimeInterval, point: CGPoint)] = []
    }

    private var press: Press?
    /// Where the others would go if the dragged circle were dropped right now.
    private var dragPreview: IslandArrangement?
    /// A circle just let go of, to be thrown from where it was at the speed it had.
    private var released: (id: String, center: CGPoint, velocity: CGVector)?

    /// The dragged circle's position, read by the island on every frame. It is not
    /// observed: while something is dragged the island redraws every frame anyway,
    /// and observing it would re-run the view for every mouse event as well.
    @ObservationIgnored private(set) var liveDrag: IslandDrag?

    private var hookServer: HookSocketServer?
    private var registryWatcher: ClaudeRegistryWatcher?
    private var transcriptWatcher: ClaudeTranscriptWatcher?
    private var codexWatcher: CodexRolloutWatcher?
    private var ticker: Task<Void, Never>?

    let settings: IslandSettings
    private let demo: DemoDriver?

    /// How long the slide-back-into-the-notch animation lasts before the circle is dropped.
    private let retractDuration = IslandLayout.retractDuration

    init(settings: IslandSettings = IslandSettings(), demoMode: Bool = false) {
        self.settings = settings
        self.demo = demoMode ? DemoDriver() : nil
    }

    // MARK: - Lifecycle

    func start() {
        startHookServer()
        settings.onWatchChanged = { [weak self] kind, on in
            self?.setWatching(kind, on)
        }
        setWatching(.claude, settings.watchClaude)
        setWatching(.codex, settings.watchCodex)
        startTicker()
        if let demo {
            demo.start { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        }
    }

    private func startHookServer() {
        let server = HookSocketServer { [weak self] event, reply in
            Task { @MainActor in
                // With no model to hold it, the reply channel closes and the hook
                // goes on without an answer.
                self?.handleHook(event, reply: reply)
            }
        }
        do {
            try server.start()
            hookServer = server
        } catch {
            NSLog("Agent Island: hook socket unavailable: \(error)")
        }
    }

    /// Starts or stops everything that watches one agent. Called at launch and
    /// whenever a Watch toggle in the menu flips.
    ///
    /// Switching an agent off sends its circles back into the notch. Switching it on
    /// starts fresh watchers, whose first scan brings live sessions straight back.
    private func setWatching(_ kind: AgentKind, _ on: Bool) {
        // The demo drives the island on its own and never watches anything real.
        guard demo == nil else { return }
        switch kind {
        case .claude: setClaudeWatching(on)
        case .codex: setCodexWatching(on)
        }
    }

    private func setClaudeWatching(_ on: Bool) {
        if on {
            guard registryWatcher == nil else { return }
            reducer.dropRetiring(kind: .claude)

            let registry = ClaudeRegistryWatcher { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            registryWatcher = registry
            Task { await registry.start() }

            let transcripts = ClaudeTranscriptWatcher { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            transcriptWatcher = transcripts
            Task { await transcripts.start() }
            syncTranscriptFollowing()
        } else {
            if let registryWatcher { Task { await registryWatcher.stop() } }
            if let transcriptWatcher { Task { await transcriptWatcher.stop() } }
            registryWatcher = nil
            transcriptWatcher = nil
            reducer.retireAll(kind: .claude)
        }
        rebuild()
    }

    private func setCodexWatching(_ on: Bool) {
        if on {
            guard codexWatcher == nil else { return }
            reducer.dropRetiring(kind: .codex)

            let codex = CodexRolloutWatcher { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            codexWatcher = codex
            Task { await codex.start() }
        } else {
            if let codexWatcher { Task { await codexWatcher.stop() } }
            codexWatcher = nil
            reducer.retireAll(kind: .codex)
        }
        rebuild()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run { self?.tick() }
            }
        }
    }

    // MARK: - Events

    func handle(_ event: AgentEvent) {
        Diagnostics.count("event")
        // Hooks keep arriving whatever the toggles say, and a watcher that was just
        // stopped can still have an event in flight.
        guard demo != nil || settings.isWatching(event.kind) else { return }
        if case .hook = event { hookedSessionsSeen = true }
        record(event)
        reducer.apply(event)
        syncTranscriptFollowing()
        rebuild()
    }

    private func tick() {
        reducer.tick()
        let now = Date()
        // Only a session that is actually gone gets dropped. A circle that merely
        // tucked itself away keeps its place and its session.
        for (id, circle) in motion where circle.isHidden(now: now, retractDuration: retractDuration) {
            guard reducer.session(id: id)?.isRetiring == true, press?.id != id else { continue }
            reducer.drop(id: id)
            forgetConversation(id)
            motion.removeValue(forKey: id)
            slides.removeValue(forKey: id)
            hovers.removeValue(forKey: id)
        }
        // Keep an open card's diff current while the agent works.
        if let expandedID { refreshDiff(for: expandedID) }
        rebuild()
    }

    /// Called with the pointer position in panel coordinates, or nil when it is elsewhere.
    ///
    /// Pointing anywhere at the notch peeks: every tucked circle slides back out for
    /// as long as the pointer is there.
    func setPointer(_ point: CGPoint?) {
        // A drag owns the pointer until it lets go.
        guard press?.isDragging != true else { return }
        let hit = point.flatMap { circle(at: $0) }
        if hoveredID != hit { hoveredID = hit }

        let onCard = point.flatMap { card(at: $0) } != nil
        let peeking = point.map { isInPeekZone($0) || hit != nil || onCard } ?? false
        if peeking != isPeeking {
            isPeeking = peeking
            rebuild()
        }
    }

    /// Pointing just beside the notch starts a peek. Once the circles are out, the
    /// zone widens to cover all of them, so the pointer can travel out to the far
    /// ones without the island tucking them away underneath it.
    private func isInPeekZone(_ point: CGPoint) -> Bool {
        let notch = geometry.notchRect
        var zone = notch.insetBy(dx: -geometry.circleDiameter, dy: 0)
        if isPeeking {
            for bubble in bubbles where bubble.side != nil {
                let center = bubble.restingCenter
                zone = zone.union(CGRect(x: center.x, y: center.y, width: 0, height: 0)
                    .insetBy(dx: -geometry.circleDiameter, dy: -geometry.circleDiameter / 2))
            }
        }
        return CGRect(x: zone.minX, y: 0, width: zone.width, height: notch.maxY + 4).contains(point)
    }

    /// Follows the transcript of every live Claude session, and forgets the rest.
    private func syncTranscriptFollowing() {
        guard let transcriptWatcher else { return }
        let live = reducer.visibleSessions.filter { $0.kind == .claude }
        for session in live {
            let sessionID = String(session.id.dropFirst("claude:".count))
            let path = session.transcriptPath
            Task { await transcriptWatcher.follow(sessionID: sessionID, path: path) }
        }
    }

    /// Recomputes places, springs, and the bubble list from the reducer's sessions.
    private func rebuild() {
        Diagnostics.count("rebuild")
        let now = Date()
        let sessions = reducer.visibleSessions
        let liveIDs = Set(sessions.map(\.id))
        let tuckAfter = settings.visibility == .popThenTuck ? settings.tuckAfter : nil

        // Keep the arrangement in step with the sessions: newcomers go next to the
        // notch on the preferred side, and the gone make room.
        arrangement.preferredSide = settings.newCircleSide
        for id in arrangement.left + arrangement.right + arrangement.waiting where !liveIDs.contains(id) {
            arrangement.remove(id)
        }
        for session in sessions where !arrangement.contains(session.id) {
            arrangement.add(session.id)
        }

        // Retiring or tucking slides a circle in; news, a peek, or switching tucking
        // off brings it back out.
        var occupying: Set<String> = []
        for session in sessions {
            let held = press?.id == session.id || expandedID == session.id
            let tuck = !held && CircleMotion.shouldTuck(session, tuckAfter: tuckAfter, isPeeking: isPeeking, now: now)
            var circle = CircleMotion.advance(
                motion[session.id],
                session: session,
                tuck: tuck,
                now: now,
                retractDuration: retractDuration
            )
            // A circle let out of the notch once there is room emerges like a new one.
            let wasWaiting = bubbles.first { $0.id == session.id }.map { $0.side == nil } ?? false
            if wasWaiting, arrangement.side(of: session.id) != nil, !circle.isRetracting {
                circle.appearedAt = now
            }
            motion[session.id] = circle
            if !circle.isHidden(now: now, retractDuration: retractDuration) { occupying.insert(session.id) }
        }

        // Places count only the circles actually showing, so the rest close up
        // around a tucked one. While dragging, the others make room for the drop.
        let placement = dragPreview ?? arrangement
        var next: [Bubble] = []
        for session in sessions {
            let id = session.id
            let circle = motion[id] ?? CircleMotion(appearedAt: now)
            let side = placement.side(of: id)
            let rank = side.map { side in
                placement.ids(on: side).prefix { $0 != id }.filter { occupying.contains($0) }.count
            } ?? 0

            let target = side.map { geometry.slotCenter(side: $0, rank: rank) } ?? geometry.notchRect.center
            var slide = slides[id] ?? (x: SpringMotion(at: target.x, now: now), y: SpringMotion(at: target.y, now: now))

            if let released, released.id == id {
                // Thrown from where it was let go, at the speed it had.
                slide.x.release(from: released.center.x, velocity: released.velocity.dx, to: target.x, at: now)
                slide.y.release(from: released.center.y, velocity: released.velocity.dy, to: target.y, at: now)
            } else if slide.x.to != target.x || slide.y.to != target.y {
                if occupying.contains(id) {
                    slide.x.retarget(to: target.x, at: now)
                    slide.y.retarget(to: target.y, at: now)
                } else {
                    // Nobody sees a hidden circle move; it just comes out in its new place.
                    slide.x.snap(to: target.x, at: now)
                    slide.y.snap(to: target.y, at: now)
                }
            }
            slides[id] = slide
            let hover = hovers[id] ?? SpringMotion(at: 1, now: now)

            next.append(
                Bubble(
                    id: id,
                    session: session,
                    side: side,
                    rank: rank,
                    appearedAt: circle.appearedAt,
                    retractingSince: circle.retractingSince,
                    x: slide.x,
                    y: slide.y,
                    hover: hover
                )
            )
        }
        released = nil

        // Sessions the reducer dropped outright.
        for id in Set(motion.keys).union(slides.keys).union(hovers.keys) where !liveIDs.contains(id) {
            motion.removeValue(forKey: id)
            slides.removeValue(forKey: id)
            hovers.removeValue(forKey: id)
        }
        if let press, !liveIDs.contains(press.id) { cancelDrag() }

        bubbles = next.sorted { ($0.side?.sortKey ?? 2, $0.rank) < ($1.side?.sortKey ?? 2, $1.rank) }
        updateAnimationMode()
        if let hoveredID, !liveIDs.contains(hoveredID) { self.hoveredID = nil }
        if let expandedID, !liveIDs.contains(expandedID) { self.expandedID = nil }
        publishLayout()
    }

    // MARK: - Hit testing

    /// Rects, in panel coordinates, that should receive clicks right now.
    var interactiveRects: [CGRect] {
        // While dragging, the panel holds on to the pointer wherever it goes, so the
        // drag is never handed to whatever is underneath.
        if press?.isDragging == true { return [geometry.bandRect().insetBy(dx: -10_000, dy: -10_000)] }

        var rects: [CGRect] = bubbles.compactMap { bubble in
            guard bubble.side != nil, !bubble.isRetracting else { return nil }
            let center = bubble.restingCenter
            let diameter = geometry.circleDiameter
            return CGRect(
                x: center.x - diameter / 2 - 3,
                y: center.y - diameter / 2 - 3,
                width: diameter + 6,
                height: diameter + 6
            )
        }
        if let expandedID, let card = cardRect(for: expandedID) { rects.append(card) }
        return rects
    }

    /// The open card under a point, if any.
    func card(at point: CGPoint) -> String? {
        guard let expandedID, let card = cardRect(for: expandedID), card.contains(point) else { return nil }
        return expandedID
    }

    /// The circle under a point, if any.
    func circle(at point: CGPoint) -> String? {
        let radius = geometry.circleDiameter / 2 + 4
        return bubbles.first { bubble in
            guard bubble.side != nil, !bubble.isRetracting else { return false }
            let center = bubble.restingCenter
            return hypot(point.x - center.x, point.y - center.y) <= radius
        }?.id
    }

    func cardRect(for id: String) -> CGRect? {
        guard let bubble = bubbles.first(where: { $0.id == id }), bubble.side != nil else { return nil }
        return IslandLayout.cardRect(around: bubble.restingCenter.x, geometry: geometry, details: detailsOpen ? 1 : 0)
    }

    private func publishLayout() {
        onLayoutChanged?(interactiveRects)
    }

    // MARK: - Reading

    /// Sessions with a circle, leaving out the ones on their way out.
    var liveSessions: [AgentSession] {
        bubbles.map(\.session).filter { !$0.isRetiring }
    }

    /// A one-line roll call, for the menu and the window.
    var summary: String {
        let live = liveSessions
        if live.isEmpty { return "No agents running" }
        let working = live.filter { $0.status == .working }.count
        let waiting = live.filter { $0.status == .question }.count
        var parts = ["\(live.count) session\(live.count == 1 ? "" : "s")"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        return parts.joined(separator: " \u{00b7} ")
    }

    // MARK: - Card

    /// A click on a circle opens its card, or closes it if it is already open.
    /// It never leaves the island; that is the card's job.
    private func circleClicked(_ id: String) {
        expandedID = expandedID == id ? nil : id
    }

    /// A click on the open card opens the chat.
    func cardPressed(_ id: String) {
        open(id: id)
        expandedID = nil
    }

    /// Closes the card, as when the user clicks anywhere else.
    func collapse() {
        expandedID = nil
    }

    func diffState(forSession id: String) -> DiffState {
        guard let cwd = reducer.session(id: id)?.cwd, !cwd.isEmpty else { return .unavailable }
        return diffs[cwd] ?? .loading
    }

    /// Once the card has folded back into its circle, the window can shrink again.
    private func finishClosingCard() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.expandedID == nil, self.cardID != nil else { return }
            self.cardID = nil
            self.onExpansionChanged?(false)
            self.updateAnimationMode()
        }
    }

    /// Reads the session folder's `+x −y` off the main thread, at most every few seconds.
    private func refreshDiff(for id: String, force: Bool = false) {
        guard let cwd = reducer.session(id: id)?.cwd, !cwd.isEmpty else { return }
        if !force, let fetched = diffFetchedAt[cwd], Date().timeIntervalSince(fetched) < 3 { return }
        guard !diffsInFlight.contains(cwd) else { return }
        diffsInFlight.insert(cwd)
        diffFetchedAt[cwd] = Date()

        Task.detached(priority: .utility) { [weak self] in
            let stat = GitDiffStat.compute(in: cwd)
            await self?.finishDiff(cwd: cwd, stat: stat)
        }
    }

    private func finishDiff(cwd: String, stat: DiffStat?) {
        diffsInFlight.remove(cwd)
        let state: DiffState = stat.map { .ready($0) } ?? .unavailable
        if diffs[cwd] != state { diffs[cwd] = state }
    }

    // MARK: - Actions

    func dismiss(id: String) {
        reducer.dismiss(id: id)
        rebuild()
    }

    func open(id: String) {
        guard let session = reducer.session(id: id) else { return }
        SessionOpener.open(session)
    }

    // MARK: - Dragging

    /// How far the pointer has to travel before a press becomes a drag.
    private let dragThreshold: CGFloat = 4

    /// The pointer went down on a circle.
    func pressBegan(on id: String, at point: CGPoint) {
        guard let bubble = bubbles.first(where: { $0.id == id }), bubble.side != nil else { return }
        let now = Date()
        let center = CGPoint(x: bubble.x.value(at: now), y: bubble.y.value(at: now))
        press = Press(
            id: id,
            start: point,
            grab: CGSize(width: center.x - point.x, height: center.y - point.y),
            samples: [(now.timeIntervalSinceReferenceDate, point)]
        )
    }

    /// The pointer moved while down. Past a few points, the circle comes with it
    /// and the others make room where it would land.
    func pressMoved(to point: CGPoint) {
        guard var press else { return }
        let time = Date().timeIntervalSinceReferenceDate
        press.samples.append((time, point))
        press.samples.removeAll { time - $0.time > 0.12 }

        var startedNow = false
        if !press.isDragging {
            guard hypot(point.x - press.start.x, point.y - press.start.y) >= dragThreshold else {
                self.press = press
                return
            }
            press.isDragging = true
            startedNow = true
        }
        self.press = press
        if startedNow {
            hoveredID = nil
            expandedID = nil
        }

        let center = dragCenter(for: point, press: press)
        liveDrag = IslandDrag(id: press.id, center: center)

        let preview = arrangementForDrop(of: press.id, at: center.x)
        if preview != dragPreview {
            dragPreview = preview
            rebuild()
        } else if startedNow {
            updateAnimationMode()
            publishLayout()
        }
    }

    /// The pointer came up. A press that never moved is a click; a drag lands the
    /// circle on the side it was let go over, thrown with the speed it had.
    func pressEnded(at point: CGPoint) {
        guard let press else { return }
        self.press = nil

        guard press.isDragging else {
            circleClicked(press.id)
            return
        }

        let center = dragCenter(for: point, press: press)
        let velocity = releaseVelocity(press.samples)
        // A flick carries on a little way, the way a thrown thing would.
        let projected = center.x + velocity.dx * 0.15
        if let landed = arrangementForDrop(of: press.id, at: projected) {
            arrangement = landed
        }

        dragPreview = nil
        liveDrag = nil
        released = (press.id, center, velocity)
        rebuild()
    }

    /// Lets go of a drag without moving anything, as when its session ends mid-drag.
    private func cancelDrag() {
        press = nil
        dragPreview = nil
        liveDrag = nil
    }

    /// The arrangement if the dragged circle landed at `x`, or nil when that side is full.
    private func arrangementForDrop(of id: String, at x: CGFloat) -> IslandArrangement? {
        let side = geometry.side(for: x)
        let rank = max(0, Int(geometry.fractionalRank(for: x, side: side).rounded()))

        // Places count circles showing; the arrangement also holds tucked ones.
        let showing = Set(bubbles.filter { !$0.isRetracting }.map(\.id))
        let others = arrangement.ids(on: side).filter { $0 != id }
        var index = others.count
        var seen = 0
        for (position, other) in others.enumerated() where showing.contains(other) {
            if seen == rank { index = position; break }
            seen += 1
        }
        return arrangement.moving(id, to: side, at: index)
    }

    /// Where the dragged circle is drawn: under the pointer, held to the strip with
    /// some give at the edges, like rubber.
    private func dragCenter(for point: CGPoint, press: Press) -> CGPoint {
        let raw = CGPoint(x: point.x + press.grab.width, y: point.y + press.grab.height)
        let radius = geometry.circleDiameter / 2
        let low = radius + 2
        let high = geometry.panelFrame.width - radius - 2

        var x = raw.x
        if x < low { x = low - 10 * tanh((low - x) / 30) }
        if x > high { x = high + 10 * tanh((x - high) / 30) }
        let rest = geometry.notchRect.midY
        let y = rest + 9 * tanh((raw.y - rest) / 28)
        return CGPoint(x: x, y: y)
    }

    /// Pointer speed over the last few samples, in points per second.
    private func releaseVelocity(_ samples: [(time: TimeInterval, point: CGPoint)]) -> CGVector {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.008 else {
            return .zero
        }
        let dt = last.time - first.time
        func clamp(_ value: CGFloat) -> CGFloat { min(max(value, -2500), 2500) }
        return CGVector(
            // Carry most of the throw, not all of it: the Dynamic Island is restrained.
            dx: clamp((last.point.x - first.point.x) / dt) * 0.6,
            // Vertical throw only nudges; the strip is shallow.
            dy: clamp((last.point.y - first.point.y) / dt) * 0.3
        )
    }

    /// How long after a status change the island keeps animating at full ambient rate.
    private let livelyWindow: TimeInterval = 25

    /// Works out how hard to animate, from what is on screen right now.
    private func currentAnimationMode() -> AnimationMode {
        let now = Date()
        var mode = AnimationMode.paused
        if press?.isDragging == true { return .emerging }
        // The card pouring out of its circle, or back in, or dropping down.
        if cardID != nil, !cardOpenness.isSettled(at: now) || !detailsOpenness.isSettled(at: now) { return .emerging }

        for bubble in bubbles {
            // Gliding to make room, or landing after a drag.
            if bubble.side != nil, bubble.retractingSince == nil, bubble.isSliding(at: now) {
                return .emerging
            }
            if let since = bubble.retractingSince {
                // Sliding in deserves every frame. Once it is hidden in the notch,
                // a tucked circle is as still as an empty one.
                if now.timeIntervalSince(since) < retractDuration { return .emerging }
                continue
            }
            if now.timeIntervalSince(bubble.appearedAt) < 1.2 {
                return .emerging
            }
            // The spinner steps a spoke at a time, which needs the frames to land.
            if bubble.session.isRunningCommand { mode = Swift.max(mode, .ambient) }
            let age = now.timeIntervalSince(bubble.session.statusChangedAt)
            switch bubble.session.status {
            case .working, .question, .plan, .error:
                // Fresh news animates fully; a turn that has been grinding for a
                // while keeps moving at half the frame rate.
                mode = Swift.max(mode, age < livelyWindow ? .ambient : .calm)
            case .complete:
                // The celebration sweep, then stillness.
                if age < 3 { mode = Swift.max(mode, .ambient) }
            case .idle, .waiting:
                break
            }
        }
        return hoveredID != nil || expandedID != nil ? Swift.max(mode, .ambient) : mode
    }

    private func updateAnimationMode() {
        let mode = currentAnimationMode()
        if mode != animationMode { animationMode = mode }
    }
}

private extension IslandSide {
    var sortKey: Int { self == .left ? 0 : 1 }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension SpringMotion.Tuning {
    /// A circle swelling under the pointer: quick, with a small bounce.
    static let hover = SpringMotion.Tuning(response: 0.3, damping: 0.55)
    /// The card pouring out of its circle.
    static let cardOpen = SpringMotion.Tuning(response: 0.46, damping: 0.74)
    /// The card dropping down to show more, with a little give at the bottom.
    static let details = SpringMotion.Tuning(response: 0.42, damping: 0.78)
    /// And folding back in, briskly and without a wobble.
    static let cardClose = SpringMotion.Tuning(response: 0.26, damping: 0.95)
}

// MARK: - Talking back

/// A question or a plan held open for an answer from the island.
struct PendingReply {
    var ask: PendingAsk
    /// The call's input as Claude sent it, handed back with the answer.
    var toolInput: Data
    var channel: HookReplyChannel
}

/// How a message typed on a card would reach the agent right now.
enum ReplyRoute: Equatable {
    /// Pasted into the chat's own message box in the Claude app.
    case paste
    /// The turn is over and a hook is waiting to take it.
    case now
    /// The agent is busy; it goes as soon as the turn ends.
    case whenDone
    /// It cannot, for the reason given.
    case unavailable(String)
}

extension IslandModel {
    /// A hook payload, with the connection it is holding open if it wants an answer.
    func handleHook(_ hook: HookEvent, reply: HookReplyChannel?) {
        guard demo != nil || settings.isWatching(hook.kind) else {
            reply?.cancel()
            return
        }
        let id = hook.kind == .claude ? SessionReducer.claudeID(hook.sessionID) : SessionReducer.codexID(hook.sessionID)
        settleReplies(for: id, after: hook)
        handle(.hook(hook))
        if let reply { hold(reply, for: hook, id: id) }
    }

    /// Lets go of answers that something else has already given: the question was
    /// answered in the chat, or a new turn started there.
    private func settleReplies(for id: String, after hook: HookEvent) {
        let turnMoved: Bool = switch hook.name {
        case .userPromptSubmit, .userPromptExpansion, .stop, .stopFailure, .interrupt, .sessionEnd: true
        default: false
        }

        if let pending = asks[id] {
            let tool = if case .plan = pending.ask { "ExitPlanMode" } else { "AskUserQuestion" }
            let answeredThere = switch hook.name {
            case .postToolUse, .postToolUseFailure, .permissionDenied: hook.toolName == tool
            default: false
            }
            if turnMoved || answeredThere || (hook.name == .permissionRequest && hook.wantsReply) {
                pending.channel.cancel()
                asks[id] = nil
            }
        }

        if let channel = wakeChannels[id], hook.agentID == nil {
            let working = switch hook.name {
            case .userPromptSubmit, .userPromptExpansion, .preToolUse, .postToolUse, .sessionEnd, .stop: true
            default: false
            }
            if working {
                channel.cancel()
                wakeChannels[id] = nil
            }
        }
        if hook.name == .userPromptSubmit || hook.name == .stop { replyNotices[id] = nil }
    }

    /// Keeps a waiting hook when it is one the island can answer, and lets the rest go.
    private func hold(_ reply: HookReplyChannel, for hook: HookEvent, id: String) {
        guard hook.agentID == nil, let session = reducer.session(id: id), !session.isRetiring else {
            reply.cancel()
            return
        }
        switch hook.name {
        case .permissionRequest:
            guard let ask = hook.ask, let input = hook.toolInput else { return reply.cancel() }
            asks[id] = PendingReply(ask: ask, toolInput: input, channel: reply)
            picks[id] = nil
            if expandedID == id { setDetailsOpen(true, animated: true, at: Date()) }

        case .stop:
            // Only a session the Claude registry lists is one someone is sitting at.
            // A headless `claude -p` run would otherwise wait on its last hook.
            guard session.pid != nil else { return reply.cancel() }
            if let queued = queuedMessages.removeValue(forKey: id) {
                deliver(queued, over: reply, to: id)
            } else {
                wakeChannels[id] = reply
            }

        default:
            reply.cancel()
        }
        publishLayout()
    }

    // MARK: Answering

    /// Answers the questions Claude asked, keyed by question text.
    func answer(_ id: String, with answers: [String: String]) {
        guard let pending = asks.removeValue(forKey: id),
              let reply = HookReply.answer(toolInput: pending.toolInput, answers: answers)
        else { return }
        let summary = answers.values.joined(separator: "; ")
        finish(id, sending: reply, over: pending.channel, logging: "Answered: \(summary)")
        picks[id] = nil
    }

    func approvePlan(_ id: String, acceptEdits: Bool) {
        guard let pending = asks.removeValue(forKey: id),
              let reply = HookReply.approvePlan(toolInput: pending.toolInput, acceptEdits: acceptEdits)
        else { return }
        finish(id, sending: reply, over: pending.channel,
               logging: acceptEdits ? "Approved the plan, accepting edits" : "Approved the plan")
    }

    func revisePlan(_ id: String, feedback: String) {
        guard let pending = asks.removeValue(forKey: id) else { return }
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(id, sending: .revisePlan(feedback: trimmed), over: pending.channel,
               logging: trimmed.isEmpty ? "Asked to keep planning" : "Asked for changes: \(trimmed)")
        drafts[id] = nil
    }

    /// Sends the typed message now, or queues it until the turn ends.
    func send(_ id: String, message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch replyRoute(for: id) {
        case .paste:
            guard let session = reducer.session(id: id) else { return }
            pasting.insert(id)
            replyNotices[id] = nil
            let sends = settings.pasteSends
            Task { @MainActor [weak self] in
                let outcome = await ChatPaster.deliver(text, to: session, send: sends)
                self?.finishPaste(id, text: text, outcome: outcome)
            }
            return
        case .now:
            guard let channel = wakeChannels.removeValue(forKey: id) else { return }
            deliver(text, over: channel, to: id)
        case .whenDone:
            queuedMessages[id] = text
            appendActivity(ActivityItem(kind: .sent, text: "Queued: \(text)", at: Date()), to: id)
        case .unavailable:
            return
        }
        drafts[id] = nil
    }

    /// Takes back a message that was waiting for the turn to end.
    func unqueue(_ id: String) {
        guard let text = queuedMessages.removeValue(forKey: id) else { return }
        drafts[id] = text
    }

    func replyRoute(for id: String) -> ReplyRoute {
        guard let session = reducer.session(id: id), !session.isRetiring else {
            return .unavailable("This session has ended")
        }
        guard session.kind == .claude else { return .unavailable("Reply to Codex in the Codex app") }
        // A chat in the Claude app takes the message in its own box, busy or not:
        // Claude queues it there as if it had been typed.
        if session.host == .claudeDesktop, SessionOpener.claudeLink(for: session) != nil { return .paste }
        if wakeChannels[id]?.isOpen == true { return .now }
        switch session.status {
        case .working, .plan, .question, .error:
            return .whenDone
        case .complete, .idle, .waiting:
            return .unavailable("Replies start after Claude's next turn ends")
        }
    }

    private func finishPaste(_ id: String, text: String, outcome: ChatPaster.Outcome) {
        pasting.remove(id)
        switch outcome {
        case .sent:
            appendActivity(ActivityItem(kind: .sent, text: text, at: Date()), to: id)
            drafts[id] = nil
            collapse()
        case .pasted(let note):
            appendActivity(ActivityItem(kind: .sent, text: "Pasted: \(text)", at: Date()), to: id)
            drafts[id] = nil
            replyNotices[id] = note
        case .copied(let note):
            replyNotices[id] = note
        }
    }

    private func deliver(_ text: String, over channel: HookReplyChannel, to id: String) {
        finish(id, sending: .prompt(text), over: channel, logging: text)
    }

    private func finish(_ id: String, sending reply: HookReply, over channel: HookReplyChannel, logging text: String) {
        if channel.send(reply) {
            appendActivity(ActivityItem(kind: .sent, text: text, at: Date()), to: id)
            replyNotices[id] = nil
            reducer.noteReplySent(id: id)
            rebuild()
        } else {
            replyNotices[id] = "That didn't reach Claude. It may have been answered in the chat."
        }
        publishLayout()
    }

    // MARK: Timeline

    /// Keeps the timeline lines out of every event on its way to the reducer.
    func record(_ event: AgentEvent) {
        switch event {
        case .claudeTranscript(let sessionID, .activity(let item)):
            appendActivity(item, to: SessionReducer.claudeID(sessionID))
        case .codex(let codex):
            let id = SessionReducer.codexID(codex.threadID)
            switch codex.kind {
            case .message(let item): appendActivity(item, to: id)
            case .toolCall(let detail): appendActivity(ActivityItem(kind: .tool, text: detail, at: codex.at), to: id)
            default: break
            }
        default:
            break
        }
    }

    private static let activityLimit = 80

    private func appendActivity(_ item: ActivityItem, to id: String) {
        var items = activity[id] ?? []
        items.append(item)
        if items.count > Self.activityLimit { items.removeFirst(items.count - Self.activityLimit) }
        activity[id] = items
    }

    /// Drops everything kept for a session that has gone.
    func forgetConversation(_ id: String) {
        asks.removeValue(forKey: id)?.channel.cancel()
        wakeChannels.removeValue(forKey: id)?.cancel()
        queuedMessages[id] = nil
        replyNotices[id] = nil
        activity[id] = nil
        drafts[id] = nil
        picks[id] = nil
    }

    // MARK: Card

    /// What the drop-down shows for a session.
    func conversation(for id: String) -> CardConversation {
        CardConversation(
            ask: asks[id]?.ask,
            activity: activity[id] ?? [],
            route: replyRoute(for: id),
            queued: queuedMessages[id],
            notice: replyNotices[id],
            isPasting: pasting.contains(id),
            pasteSends: settings.pasteSends
        )
    }

    /// The card's controls, bound to one session.
    func cardActions(for id: String) -> CardActions {
        CardActions(
            openChat: { [weak self] in self?.cardPressed(id) },
            toggleDetails: { [weak self] in self?.toggleDetails() },
            collapse: { [weak self] in self?.collapse() },
            answer: { [weak self] answers in self?.answer(id, with: answers) },
            approvePlan: { [weak self] acceptEdits in self?.approvePlan(id, acceptEdits: acceptEdits) },
            revisePlan: { [weak self] feedback in self?.revisePlan(id, feedback: feedback) },
            send: { [weak self] text in self?.send(id, message: text) },
            unqueue: { [weak self] in self?.unqueue(id) },
            draft: Binding(
                get: { [weak self] in self?.drafts[id] ?? "" },
                set: { [weak self] in self?.drafts[id] = $0 }
            ),
            picks: Binding(
                get: { [weak self] in self?.picks[id] ?? [:] },
                set: { [weak self] in self?.picks[id] = $0 }
            )
        )
    }

    // MARK: Drop-down

    func toggleDetails() {
        setDetailsOpen(!detailsOpen, animated: true, at: Date())
    }

    func setDetailsOpen(_ open: Bool, animated: Bool, at now: Date) {
        guard open != detailsOpen else { return }
        detailsOpen = open
        if animated {
            detailsOpenness.retarget(to: open ? 1 : 0, at: now, tuning: .details)
        } else {
            detailsOpenness = SpringMotion(at: open ? 1 : 0, now: now)
        }
        updateAnimationMode()
        publishLayout()
    }
}
