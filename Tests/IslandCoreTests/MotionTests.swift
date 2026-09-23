import Foundation
import Testing

@testable import IslandCore

@Suite("Pop, then tuck back")
struct MotionTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let retract: TimeInterval = 0.55

    private func session(_ status: AgentStatus, changedSecondsAgo age: TimeInterval, retiring: Bool = false) -> AgentSession {
        var session = AgentSession(id: "claude:s1", kind: .claude, now: start.addingTimeInterval(-age))
        session.status = status
        session.statusChangedAt = start.addingTimeInterval(-age)
        session.isRetiring = retiring
        return session
    }

    @Test("Circles never tuck while tucking is off")
    func stayModeNeverTucks() {
        let old = session(.working, changedSecondsAgo: 3600)
        #expect(!CircleMotion.shouldTuck(old, tuckAfter: nil, isPeeking: false, now: start))
    }

    @Test("Old news tucks away; fresh news and questions stay out")
    func tuckRules() {
        #expect(CircleMotion.shouldTuck(session(.working, changedSecondsAgo: 6), tuckAfter: 5, isPeeking: false, now: start))
        #expect(CircleMotion.shouldTuck(session(.complete, changedSecondsAgo: 6), tuckAfter: 5, isPeeking: false, now: start))
        #expect(!CircleMotion.shouldTuck(session(.working, changedSecondsAgo: 2), tuckAfter: 5, isPeeking: false, now: start))

        for status in [AgentStatus.question, .plan, .error] {
            #expect(
                !CircleMotion.shouldTuck(session(status, changedSecondsAgo: 60), tuckAfter: 5, isPeeking: false, now: start),
                "\(status) still wants an answer"
            )
        }
    }

    @Test("Peeking holds every circle out")
    func peekHoldsOut() {
        let old = session(.working, changedSecondsAgo: 60)
        #expect(!CircleMotion.shouldTuck(old, tuckAfter: 5, isPeeking: true, now: start))
    }

    @Test("A tucked circle slides in, then sits still")
    func tuckSettles() {
        let live = session(.working, changedSecondsAgo: 1)
        var motion = CircleMotion.advance(nil, session: live, tuck: false, now: start, retractDuration: retract)
        #expect(!motion.isRetracting)

        let tuckAt = start.addingTimeInterval(6)
        motion = CircleMotion.advance(motion, session: live, tuck: true, now: tuckAt, retractDuration: retract)
        #expect(motion.retractingSince == tuckAt)
        #expect(!motion.isHidden(now: tuckAt.addingTimeInterval(0.3), retractDuration: retract), "still sliding in")
        #expect(motion.isHidden(now: tuckAt.addingTimeInterval(0.6), retractDuration: retract))

        // Staying tucked does not restart the slide.
        let later = tuckAt.addingTimeInterval(30)
        motion = CircleMotion.advance(motion, session: live, tuck: true, now: later, retractDuration: retract)
        #expect(motion.retractingSince == tuckAt)
        #expect(motion.isHidden(now: later, retractDuration: retract))
    }

    @Test("News or a peek brings a tucked circle back out")
    func untucks() {
        let live = session(.working, changedSecondsAgo: 60)
        let tucked = CircleMotion(appearedAt: start.addingTimeInterval(-60), retractingSince: start.addingTimeInterval(-50))

        let now = start
        let motion = CircleMotion.advance(tucked, session: live, tuck: false, now: now, retractDuration: retract)
        #expect(!motion.isRetracting)
        #expect(motion.appearedAt == now, "it emerges again from the notch")
    }

    @Test("A retiring circle never comes back out")
    func retiringStaysIn() {
        let ending = session(.working, changedSecondsAgo: 0, retiring: true)
        let sliding = CircleMotion(appearedAt: start.addingTimeInterval(-10), retractingSince: start)
        let motion = CircleMotion.advance(sliding, session: ending, tuck: false, now: start.addingTimeInterval(0.2), retractDuration: retract)
        #expect(motion.retractingSince == start)
    }

    @Test("A circle first seen with old news starts hidden instead of flashing")
    func oldNewsStartsHidden() {
        let stale = session(.working, changedSecondsAgo: 600)
        let motion = CircleMotion.advance(nil, session: stale, tuck: true, now: start, retractDuration: retract)
        #expect(motion.isHidden(now: start, retractDuration: retract))
    }
}

@Suite("Watch toggles")
struct WatchToggleTests {
    private func claudePrompt(_ session: String) -> AgentEvent {
        .hook(HookEvent(kind: .claude, name: .userPromptSubmit, sessionID: session, cwd: "/tmp/repo"))
    }

    private func codexStart(_ thread: String) -> AgentEvent {
        .codex(CodexEvent(threadID: thread, kind: .taskStarted))
    }

    @Test("Events know which agent they are about")
    func eventKinds() {
        #expect(claudePrompt("a").kind == .claude)
        #expect(codexStart("t").kind == .codex)
        #expect(AgentEvent.claudeRegistry([]).kind == .claude)
        #expect(AgentEvent.claudeTranscript(sessionID: "a", signal: .planReady).kind == .claude)
        let codexHook = AgentEvent.hook(HookEvent(kind: .codex, name: .stop, sessionID: "t", cwd: "/tmp"))
        #expect(codexHook.kind == .codex)
    }

    @Test("Switching an agent off retires only its sessions")
    func retireAllByKind() {
        var reducer = SessionReducer()
        reducer.apply(claudePrompt("a"))
        reducer.apply(claudePrompt("b"))
        reducer.apply(codexStart("t"))

        reducer.retireAll(kind: .claude)
        #expect(reducer.session(id: "claude:a")?.isRetiring == true)
        #expect(reducer.session(id: "claude:b")?.isRetiring == true)
        #expect(reducer.session(id: "codex:t")?.isRetiring == false)
    }

    @Test("Switching it back on clears the retiring sessions so a fresh scan can bring them back")
    func dropRetiringByKind() {
        var reducer = SessionReducer()
        reducer.apply(claudePrompt("a"))
        reducer.apply(codexStart("t"))
        reducer.retireAll(kind: .claude)
        reducer.dismiss(id: "codex:t")

        reducer.dropRetiring(kind: .claude)
        #expect(reducer.session(id: "claude:a") == nil)
        #expect(reducer.session(id: "codex:t")?.isRetiring == true, "the other agent is left alone")

        reducer.apply(claudePrompt("a"))
        let revived = reducer.session(id: "claude:a")
        #expect(revived?.isRetiring == false)
        #expect(revived?.status == .working)
    }
}
