import Foundation

/// A damped spring along one axis, solved in closed form so it can be read at any
/// instant from a clock, and retargeted mid-flight without a jump in position or
/// speed. That is what gives the island its Dynamic Island feel: a circle thrown
/// or nudged overshoots a little, swings back, and settles.
public struct SpringMotion: Equatable, Sendable {
    public struct Tuning: Equatable, Sendable {
        /// Roughly how long one swing takes, in seconds.
        public var response: Double
        /// 1 settles without overshoot; lower bounces more.
        public var damping: Double

        public init(response: Double, damping: Double) {
            self.response = response
            self.damping = damping
        }

        /// Circles making room for one another.
        public static let reflow = Tuning(response: 0.42, damping: 0.72)
        /// A dropped circle landing in its place: a livelier swing.
        public static let drop = Tuning(response: 0.5, damping: 0.6)
    }

    /// Where the motion started, and how fast it was going then.
    public private(set) var from: Double
    public private(set) var velocity: Double
    public private(set) var to: Double
    public private(set) var start: Date
    public private(set) var tuning: Tuning
    /// How long after `start` the motion is within a fraction of a point of `to`.
    public private(set) var settleDuration: TimeInterval

    /// A spring already at rest.
    public init(at value: Double, now: Date) {
        self.init(from: value, to: value, velocity: 0, start: now, tuning: .reflow)
    }

    public init(from: Double, to: Double, velocity: Double, start: Date, tuning: Tuning) {
        self.from = from
        self.to = to
        self.velocity = velocity
        self.start = start
        self.tuning = tuning
        self.settleDuration = Self.settleDuration(
            displacement: from - to,
            velocity: velocity,
            tuning: tuning
        )
    }

    public func value(at date: Date) -> Double {
        let (displacement, _) = state(at: date)
        return to + displacement
    }

    public func velocity(at date: Date) -> Double {
        state(at: date).velocity
    }

    public func isSettled(at date: Date) -> Bool {
        date.timeIntervalSince(start) >= settleDuration
    }

    /// Heads for a new target from wherever the motion is right now, keeping its speed.
    public mutating func retarget(to target: Double, at date: Date, tuning: Tuning = .reflow) {
        let (displacement, speed) = state(at: date)
        self = SpringMotion(from: to + displacement, to: target, velocity: speed, start: date, tuning: tuning)
    }

    /// Lets go of something held at `value` and moving at `velocity`, towards `target`.
    public mutating func release(from value: Double, velocity: Double, to target: Double, at date: Date, tuning: Tuning = .drop) {
        self = SpringMotion(from: value, to: target, velocity: velocity, start: date, tuning: tuning)
    }

    /// Jumps straight to a new resting place, for things nobody can see move.
    public mutating func snap(to target: Double, at date: Date) {
        self = SpringMotion(at: target, now: date)
    }

    // MARK: - Solution

    private var omega: Double { 2 * .pi / max(tuning.response, 0.01) }
    private var zeta: Double { min(max(tuning.damping, 0.05), 0.999) }

    /// Displacement from `to`, and velocity, at a given moment.
    ///
    /// x(t) = e^(-ζωt) (x₀ cos ω_d t + (v₀ + ζωx₀)/ω_d sin ω_d t)
    /// v(t) = e^(-ζωt) (v₀ cos ω_d t − (ζωv₀ + ω²x₀)/ω_d sin ω_d t)
    private func state(at date: Date) -> (displacement: Double, velocity: Double) {
        let x0 = from - to
        let v0 = velocity
        let t = date.timeIntervalSince(start)
        guard t > 0 else { return (x0, v0) }
        guard t < settleDuration else { return (0, 0) }

        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        let cosine = cos(omegaD * t)
        let sine = sin(omegaD * t)

        let displacement = decay * (x0 * cosine + (v0 + zeta * omega * x0) / omegaD * sine)
        let speed = decay * (v0 * cosine - (zeta * omega * v0 + omega * omega * x0) / omegaD * sine)
        return (displacement, speed)
    }

    /// When the envelope of the swing drops below a twentieth of a point.
    private static func settleDuration(displacement x0: Double, velocity v0: Double, tuning: Tuning) -> TimeInterval {
        let omega = 2 * .pi / max(tuning.response, 0.01)
        let zeta = min(max(tuning.damping, 0.05), 0.999)
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let amplitude = (x0 * x0 + pow((v0 + zeta * omega * x0) / omegaD, 2)).squareRoot()
        let tolerance = 0.05
        guard amplitude > tolerance else { return 0 }
        return log(amplitude / tolerance) / (zeta * omega)
    }
}
