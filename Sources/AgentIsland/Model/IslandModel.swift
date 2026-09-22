import AppKit
import Foundation
import IslandCore
import Observation

/// One circle on screen: a session plus the animation bookkeeping for it.
struct Bubble: Identifiable, Equatable {
    var id: String
    var session: AgentSession
    var slot: Int
    /// When the circle started sliding out of the notch.
    var appearedAt: Date
    /// When it started sliding back in, if it is on the way out.
    var retractingSince: Date?

    var isRetracting: Bool { retractingSince != nil }
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
final class IslandModel {
    private(set) var bubbles: [Bubble] = []
    private(set) var animationMode: AnimationMode = .paused
    private(set) var hookedSessionsSeen = false
    var hoveredID: String? {
        didSet { if hoveredID != oldValue { publishLayout() } }
    }
    var expandedID: String? {
        didSet {
            guard expandedID != oldValue else { return }
            publishLayout()
            onExpansionChanged?(expandedID != nil)
        }
    }

    /// Called when the hover card opens or closes, so the window can grow only when
    /// there is something below the menu bar to show.
    var onExpansionChanged: ((Bool) -> Void)?

    /// Where the notch is. Set by the panel controller and re-set when screens change.
    var geometry: NotchGeometry = .current() {
        didSet { publishLayout() }
    }

    /// Called with the rects that should take clicks: the circles, plus any open card.
    var onLayoutChanged: (([CGRect]) -> Void)?

    private var reducer = SessionReducer()
    private var slots: [String: Int] = [:]
    private var lastStatus: [String: AgentStatus] = [:]
    /// True while the pointer is at the notch, which pulls tucked circles back out.
    private var isPeeking = false
    private var appearance: [String: Date] = [:]
    private var retracting: [String: Date] = [:]

    private var hookServer: HookSocketServer?
    private var registryWatcher: ClaudeRegistryWatcher?
    private var transcriptWatcher: ClaudeTranscriptWatcher?
    private var codexWatcher: CodexRolloutWatcher?
    private var ticker: Task<Void, Never>?

    let settings: IslandSettings
    private let demo: DemoDriver?

    /// How long the slide-back-into-the-notch animation lasts before the circle is dropped.
    private let retractDuration: TimeInterval = 0.55

    init(settings: IslandSettings = IslandSettings(), demoMode: Bool = false) {
        self.settings = settings
        self.demo = demoMode ? DemoDriver() : nil
    }

    // MARK: - Lifecycle

    func start() {
        startHookServer()
        startWatchers()
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

    private func startWatchers() {
        guard demo == nil else { return }

        if settings.watchClaude {
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
        }

        if settings.watchCodex {
            let codex = CodexRolloutWatcher { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            codexWatcher = codex
            Task { await codex.start() }
        }
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
        if case .hook = event { hookedSessionsSeen = true }
        reducer.apply(event)
        syncTranscriptFollowing()
        rebuild()
    }

    private func tick() {
        reducer.tick()
        let now = Date()
        // Only a session that is actually gone gets dropped. A circle that merely
        // tucked itself away keeps its slot and its session.
        for (id, since) in retracting where now.timeIntervalSince(since) > retractDuration {
            guard reducer.session(id: id)?.isRetiring == true else { continue }
            reducer.drop(id: id)
            retracting.removeValue(forKey: id)
            slots.removeValue(forKey: id)
            appearance.removeValue(forKey: id)
            lastStatus.removeValue(forKey: id)
        }
        rebuild()
    }

    /// Called with the pointer position in panel coordinates, or nil when it is elsewhere.
    ///
    /// Pointing anywhere at the notch peeks: every tucked circle slides back out for
    /// as long as the pointer is there.
    func setPointer(_ point: CGPoint?) {
        let hit = point.flatMap { hitTest($0) }
        if hoveredID != hit {
            hoveredID = hit
            expandedID = hit
        }

        let peekZone = geometry.notchRect.insetBy(dx: -geometry.circleDiameter, dy: -4)
        let peeking = point.map { peekZone.contains($0) } ?? false
        if peeking != isPeeking {
            isPeeking = peeking
            rebuild()
        }
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

    /// Recomputes slots and the bubble list from the reducer's sessions.
    private func rebuild() {
        Diagnostics.count("rebuild")
        let now = Date()
        let sessions = reducer.visibleSessions
        var next: [Bubble] = []
        var liveIDs: Set<String> = []

        for session in sessions {
            liveIDs.insert(session.id)

            if session.isRetiring, retracting[session.id] == nil {
                retracting[session.id] = now
            }

            let slot = slots[session.id] ?? assignSlot(to: session.id)
            if appearance[session.id] == nil { appearance[session.id] = now }

            // Anything new to report pops the circle back out.
            if lastStatus[session.id] != session.status {
                lastStatus[session.id] = session.status
                if !session.isRetiring, retracting[session.id] != nil {
                    retracting[session.id] = nil
                    appearance[session.id] = now
                }
            }

            if shouldTuck(session, now: now) {
                if retracting[session.id] == nil { retracting[session.id] = now }
            } else if !session.isRetiring, isPeeking, retracting[session.id] != nil {
                // Peeking pulls a tucked circle back out.
                retracting[session.id] = nil
                appearance[session.id] = now
            }

            let appeared = appearance[session.id] ?? now

            next.append(
                Bubble(
                    id: session.id,
                    session: session,
                    slot: slot,
                    appearedAt: appeared,
                    retractingSince: retracting[session.id]
                )
            )
        }

        // Sessions the reducer dropped outright.
        for id in slots.keys where !liveIDs.contains(id) {
            slots.removeValue(forKey: id)
            appearance.removeValue(forKey: id)
            retracting.removeValue(forKey: id)
        }

        bubbles = next.sorted { $0.slot < $1.slot }
        updateAnimationMode()
        if let hoveredID, !liveIDs.contains(hoveredID) { self.hoveredID = nil }
        if let expandedID, !liveIDs.contains(expandedID) { self.expandedID = nil }
        publishLayout()
    }

    /// In "pop, then tuck back" mode a circle slides away again once its news is old,
    /// unless it still wants an answer from you.
    private func shouldTuck(_ session: AgentSession, now: Date) -> Bool {
        guard settings.visibility == .popThenTuck else { return false }
        guard !session.isRetiring, !isPeeking else { return false }
        guard !session.status.demandsAttention else { return false }
        return now.timeIntervalSince(session.statusChangedAt) > settings.tuckAfter
    }

    private func assignSlot(to id: String) -> Int {
        let taken = Set(slots.values)
        var candidate = 0
        while taken.contains(candidate) { candidate += 1 }
        slots[id] = candidate
        return candidate
    }

    // MARK: - Hit testing

    /// Rects, in panel coordinates, that should receive clicks right now.
    var interactiveRects: [CGRect] {
        var rects: [CGRect] = bubbles.compactMap { bubble in
            guard bubble.slot / 2 < NotchGeometry.maximumPerSide, !bubble.isRetracting else { return nil }
            let center = geometry.slotCenter(index: bubble.slot)
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

    /// The circle or open card under a point, if any.
    func hitTest(_ point: CGPoint) -> String? {
        for bubble in bubbles {
            guard bubble.slot / 2 < NotchGeometry.maximumPerSide, !bubble.isRetracting else { continue }
            let center = geometry.slotCenter(index: bubble.slot)
            let radius = geometry.circleDiameter / 2 + 4
            if hypot(point.x - center.x, point.y - center.y) <= radius { return bubble.id }
        }
        // Keep the card open while the pointer is on it.
        if let expandedID, let card = cardRect(for: expandedID), card.contains(point) {
            return expandedID
        }
        return nil
    }

    func cardRect(for id: String) -> CGRect? {
        guard let bubble = bubbles.first(where: { $0.id == id }) else { return nil }
        let center = geometry.slotCenter(index: bubble.slot)
        return IslandLayout.cardRect(around: center.x, geometry: geometry)
    }

    private func publishLayout() {
        onLayoutChanged?(interactiveRects)
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

    /// How long after a status change the island keeps animating at full ambient rate.
    private let livelyWindow: TimeInterval = 25

    /// Works out how hard to animate, from what is on screen right now.
    private func currentAnimationMode() -> AnimationMode {
        let now = Date()
        var mode = AnimationMode.paused

        for bubble in bubbles {
            if bubble.isRetracting || now.timeIntervalSince(bubble.appearedAt) < 1.2 {
                return .emerging
            }
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
        return hoveredID != nil ? Swift.max(mode, .ambient) : mode
    }

    private func updateAnimationMode() {
        let mode = currentAnimationMode()
        if mode != animationMode { animationMode = mode }
    }

}
