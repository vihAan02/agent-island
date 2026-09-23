import Foundation

/// Where one circle is in its slide out of, or back into, the notch.
///
/// Pure bookkeeping with no clock of its own, kept apart from the view model so the
/// "pop, then tuck back" rules can be tested.
public struct CircleMotion: Equatable, Sendable {
    /// When the circle last started sliding out of the notch.
    public var appearedAt: Date
    /// When it started sliding back in. Set while it is on the way in, and kept once
    /// it is hidden: a tucked circle is one that retracted but whose session lives on.
    public var retractingSince: Date?

    public init(appearedAt: Date, retractingSince: Date? = nil) {
        self.appearedAt = appearedAt
        self.retractingSince = retractingSince
    }

    public var isRetracting: Bool { retractingSince != nil }

    /// True once the circle has finished sliding in and sits hidden in the notch.
    /// Nothing about it moves any more, so it needs no frames.
    public func isHidden(now: Date, retractDuration: TimeInterval) -> Bool {
        guard let retractingSince else { return false }
        return now.timeIntervalSince(retractingSince) >= retractDuration
    }

    /// Whether a circle should be hidden in the notch right now.
    ///
    /// - Parameters:
    ///   - tuckAfter: How long news stays out before the circle tucks back, or nil
    ///     when circles stay out for as long as the agent works.
    ///   - isPeeking: The pointer is at the notch, which holds every circle out.
    public static func shouldTuck(
        _ session: AgentSession,
        tuckAfter: TimeInterval?,
        isPeeking: Bool,
        now: Date
    ) -> Bool {
        guard let tuckAfter, !session.isRetiring, !isPeeking else { return false }
        // Anything still waiting on you stays out until it is answered.
        guard !session.status.demandsAttention else { return false }
        return now.timeIntervalSince(session.statusChangedAt) > tuckAfter
    }

    /// Moves a circle on, given its session and whether it should be hidden.
    ///
    /// - Parameters:
    ///   - previous: The circle's motion so far, or nil the first time it is seen.
    ///   - tuck: The answer from `shouldTuck`.
    public static func advance(
        _ previous: CircleMotion?,
        session: AgentSession,
        tuck: Bool,
        now: Date,
        retractDuration: TimeInterval
    ) -> CircleMotion {
        let hide = session.isRetiring || tuck

        guard var motion = previous else {
            // A circle whose news is already old starts out hidden, rather than
            // popping out only to slide straight back in.
            return CircleMotion(
                appearedAt: now,
                retractingSince: hide ? now.addingTimeInterval(-retractDuration) : nil
            )
        }

        if hide {
            if motion.retractingSince == nil { motion.retractingSince = now }
        } else if motion.retractingSince != nil {
            // Fresh news, a peek, or switching tucking off brings it back out.
            motion.retractingSince = nil
            motion.appearedAt = now
        }
        return motion
    }
}
