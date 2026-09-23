import Foundation

/// Which side of the notch a circle sits on.
public enum IslandSide: String, Sendable, Codable, CaseIterable {
    case left
    case right

    public var opposite: IslandSide { self == .left ? .right : .left }
}

/// Which circles sit on which side of the notch, in order out from the notch.
///
/// New circles land next to the notch on the preferred side and push the others
/// outward. A side holds `capacity` circles; beyond that a new one goes to the other
/// side, and beyond both it waits inside the notch until there is room. Dragging a
/// circle moves it to a side and a position, if that side has room.
public struct IslandArrangement: Equatable, Sendable {
    public private(set) var left: [String] = []
    public private(set) var right: [String] = []
    /// Circles with no room on either side. They stay inside the notch.
    public private(set) var waiting: [String] = []

    public var capacity: Int
    public var preferredSide: IslandSide

    public init(capacity: Int = 4, preferredSide: IslandSide = .left) {
        self.capacity = capacity
        self.preferredSide = preferredSide
    }

    // MARK: - Reading

    public func ids(on side: IslandSide) -> [String] {
        side == .left ? left : right
    }

    public func side(of id: String) -> IslandSide? {
        if left.contains(id) { return .left }
        if right.contains(id) { return .right }
        return nil
    }

    public func contains(_ id: String) -> Bool {
        side(of: id) != nil || waiting.contains(id)
    }

    // MARK: - Changing

    /// Places a new circle next to the notch, on the preferred side if it has room.
    public mutating func add(_ id: String) {
        guard !contains(id) else { return }
        if let side = sideWithRoom() {
            insert(id, on: side, at: 0)
        } else {
            waiting.append(id)
        }
    }

    /// Takes a circle away, and lets the longest-waiting one out if that made room.
    public mutating func remove(_ id: String) {
        left.removeAll { $0 == id }
        right.removeAll { $0 == id }
        waiting.removeAll { $0 == id }
        promoteWaiting()
    }

    /// Moves a circle to `side`, at `index` out from the notch.
    ///
    /// - Returns: false, changing nothing, when that side is already full.
    @discardableResult
    public mutating func move(_ id: String, to side: IslandSide, at index: Int) -> Bool {
        guard let current = self.side(of: id) else { return false }
        if current != side, ids(on: side).count >= capacity { return false }

        if current == .left { left.removeAll { $0 == id } } else { right.removeAll { $0 == id } }
        let clamped = min(max(index, 0), ids(on: side).count)
        insert(id, on: side, at: clamped)
        return true
    }

    /// The arrangement if `id` were dropped on `side` at `index`, or nil when it
    /// could not go there. Used to make room while a circle is being dragged.
    public func moving(_ id: String, to side: IslandSide, at index: Int) -> IslandArrangement? {
        var copy = self
        return copy.move(id, to: side, at: index) ? copy : nil
    }

    // MARK: - Helpers

    private func sideWithRoom() -> IslandSide? {
        if ids(on: preferredSide).count < capacity { return preferredSide }
        if ids(on: preferredSide.opposite).count < capacity { return preferredSide.opposite }
        return nil
    }

    private mutating func insert(_ id: String, on side: IslandSide, at index: Int) {
        if side == .left { left.insert(id, at: index) } else { right.insert(id, at: index) }
    }

    private mutating func promoteWaiting() {
        while let next = waiting.first, let side = sideWithRoom() {
            waiting.removeFirst()
            insert(next, on: side, at: 0)
        }
    }
}
