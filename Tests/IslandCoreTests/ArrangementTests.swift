import Foundation
import Testing

@testable import IslandCore

@Suite("Arranging circles beside the notch")
struct ArrangementTests {
    @Test("New circles line up on the left, newest next to the notch")
    func newCirclesGoLeft() {
        var arrangement = IslandArrangement(capacity: 4, preferredSide: .left)
        arrangement.add("a")
        arrangement.add("b")
        arrangement.add("c")
        #expect(arrangement.left == ["c", "b", "a"])
        #expect(arrangement.right.isEmpty)
    }

    @Test("A full side spills onto the other, then into the notch")
    func overflow() {
        var arrangement = IslandArrangement(capacity: 2, preferredSide: .left)
        for id in ["a", "b", "c", "d", "e"] { arrangement.add(id) }
        #expect(arrangement.left == ["b", "a"])
        #expect(arrangement.right == ["d", "c"])
        #expect(arrangement.waiting == ["e"])

        arrangement.remove("a")
        #expect(arrangement.left == ["e", "b"], "the waiting circle takes the freed place")
        #expect(arrangement.waiting.isEmpty)
    }

    @Test("Dragging moves a circle across, at the position it was dropped")
    func moveAcross() {
        var arrangement = IslandArrangement(capacity: 4, preferredSide: .left)
        for id in ["a", "b", "c"] { arrangement.add(id) }

        let movedB = arrangement.move("b", to: .right, at: 0)
        #expect(movedB)
        #expect(arrangement.left == ["c", "a"])
        #expect(arrangement.right == ["b"])

        let movedA = arrangement.move("a", to: .right, at: 9)
        #expect(movedA, "an index past the end lands at the end")
        #expect(arrangement.right == ["b", "a"])
    }

    @Test("Dragging within a side reorders it")
    func reorder() {
        var arrangement = IslandArrangement(capacity: 4, preferredSide: .left)
        for id in ["a", "b", "c"] { arrangement.add(id) }
        let moved = arrangement.move("a", to: .left, at: 0)
        #expect(moved)
        #expect(arrangement.left == ["a", "c", "b"])
    }

    @Test("A full side refuses a dropped circle and nothing changes")
    func fullSideRefuses() {
        var arrangement = IslandArrangement(capacity: 1, preferredSide: .left)
        arrangement.add("a")
        arrangement.add("b")
        let before = arrangement
        let moved = arrangement.move("b", to: .left, at: 0)
        #expect(!moved)
        #expect(arrangement == before)
        #expect(arrangement.moving("b", to: .left, at: 0) == nil)
    }

    @Test("The preferred side can be the right")
    func preferRight() {
        var arrangement = IslandArrangement(capacity: 4, preferredSide: .right)
        arrangement.add("a")
        #expect(arrangement.side(of: "a") == .right)
    }
}

@Suite("Spring motion")
struct SpringMotionTests {
    private let start = Date(timeIntervalSinceReferenceDate: 5_000)

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test("It starts where it was, ends at the target, and settles")
    func endpoints() {
        let spring = SpringMotion(from: 0, to: 100, velocity: 0, start: start, tuning: .reflow)
        #expect(spring.value(at: start) == 0)
        #expect(!spring.isSettled(at: at(0.1)))
        #expect(spring.isSettled(at: at(3)))
        #expect(abs(spring.value(at: at(3)) - 100) < 0.05)
    }

    @Test("An underdamped spring overshoots, like the Dynamic Island")
    func overshoots() {
        let spring = SpringMotion(from: 0, to: 100, velocity: 0, start: start, tuning: .drop)
        let peak = stride(from: 0.0, through: 1.5, by: 0.01).map { spring.value(at: at($0)) }.max() ?? 0
        #expect(peak > 101, "it should swing past the target")
        #expect(peak < 130, "but not wildly")
    }

    @Test("Retargeting keeps position and speed continuous")
    func retargetIsSmooth() {
        var spring = SpringMotion(from: 0, to: 100, velocity: 0, start: start, tuning: .reflow)
        let moment = at(0.15)
        let position = spring.value(at: moment)
        let speed = spring.velocity(at: moment)

        spring.retarget(to: 40, at: moment)
        #expect(abs(spring.value(at: moment) - position) < 1e-9)
        #expect(abs(spring.velocity(at: moment) - speed) < 1e-9)
        #expect(abs(spring.value(at: at(4)) - 40) < 0.05)
    }

    @Test("A flung circle keeps moving the way it was thrown before it swings back")
    func releaseCarriesVelocity() {
        var spring = SpringMotion(at: 0, now: start)
        spring.release(from: 50, velocity: 800, to: 0, at: start)
        #expect(spring.value(at: at(0.03)) > 50, "still travelling in the direction of the throw")
        #expect(abs(spring.value(at: at(4))) < 0.05)
    }

    @Test("A spring at rest reports itself settled")
    func restIsSettled() {
        let spring = SpringMotion(at: 12, now: start)
        #expect(spring.isSettled(at: start))
        #expect(spring.value(at: at(1)) == 12)
    }
}
