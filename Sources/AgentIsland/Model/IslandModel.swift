import AppKit
import Foundation
import IslandCore
import Observation

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
                onExpansionChanged?(true)
                refreshDiff(for: expandedID, force: true)
            } else {
                cardOpenness.retarget(to: 0, at: now, tuning: .cardClose)
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
        let server = HookSocketServer { [weak self] event in
            Task { @MainActor in self?.handle(.hook(event)) }
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
        return IslandLayout.cardRect(around: bubble.restingCenter.x, geometry: geometry)
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
        // The card pouring out of its circle, or back in.
        if cardID != nil, !cardOpenness.isSettled(at: now) { return .emerging }

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
    /// And folding back in, briskly and without a wobble.
    static let cardClose = SpringMotion.Tuning(response: 0.26, damping: 0.95)
}
