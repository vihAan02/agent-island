import IslandCore
import SwiftUI

/// Colors and easing shared by every part of the island.
enum IslandStyle {
    /// Clawd's body color, straight from the CLI theme: rgb(215,119,87).
    static let claude = Color(red: 215 / 255, green: 119 / 255, blue: 87 / 255)
    /// The Codex pet's periwinkle blue.
    static let codex = Color(red: 108 / 255, green: 126 / 255, blue: 235 / 255)

    static let question = Color(red: 244 / 255, green: 183 / 255, blue: 64 / 255)
    static let error = Color(red: 230 / 255, green: 86 / 255, blue: 74 / 255)
    static let complete = Color(red: 88 / 255, green: 199 / 255, blue: 127 / 255)
    static let plan = Color(red: 157 / 255, green: 130 / 255, blue: 236 / 255)
    /// A slash command running: plain white, like the system spinner.
    static let command = Color.white
    /// Ultracode and Codex ultra: a saturated purple, well clear of the soft lavender
    /// of a plan, and always moving, where the plan ring holds still.
    static let ultra = Color(red: 0.66, green: 0.30, blue: 0.98)
    static let ultraHues: [Color] = [
        ultra,
        Color(red: 0.86, green: 0.36, blue: 0.96),
        Color(red: 0.46, green: 0.28, blue: 1.00),
        Color(red: 0.94, green: 0.62, blue: 1.00),
        ultra,
    ]

    static func brand(_ kind: AgentKind) -> Color {
        kind == .claude ? claude : codex
    }

    /// The ring color for a status. Working keeps the agent's own color, or purple
    /// at ultra effort; a running slash command is white.
    static func ring(for session: AgentSession) -> Color {
        if session.isRunningCommand { return command }
        return switch session.status {
        case .working: session.effectiveEffort == .ultra ? ultra : brand(session.kind)
        case .question: question
        case .plan: plan
        case .error: error
        case .complete: complete
        case .idle, .waiting: brand(session.kind).opacity(0.5)
        }
    }

    /// Each agent's own gradient, for the app icon.
    static func brandHues(_ kind: AgentKind) -> [Color] {
        kind == .claude
            ? [claude, Color(red: 0.96, green: 0.76, blue: 0.35), Color(red: 0.90, green: 0.45, blue: 0.42), claude]
            : [codex, Color(red: 0.61, green: 0.45, blue: 0.95), Color(red: 0.36, green: 0.80, blue: 0.93), codex]
    }
}

/// Critically-tuned spring, solved analytically so animations can be driven from a
/// TimelineView clock instead of SwiftUI's implicit animations. That keeps the
/// metaball canvas, the ring, and the mascot on exactly the same timeline.
enum Spring {
    /// Position of a unit step response at `time` seconds.
    static func value(
        time: Double,
        response: Double = 0.5,
        damping: Double = 0.62
    ) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = min(max(damping, 0.05), 0.999)
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * time)
        let value = 1 - decay * (cos(omegaD * time) + (zeta * omega / omegaD) * sin(omegaD * time))
        return min(max(value, -0.2), 1.25)
    }

    /// Smooth 0→1 ramp, used for fades.
    static func smoothstep(_ x: Double, from low: Double = 0, to high: Double = 1) -> Double {
        guard high > low else { return x < low ? 0 : 1 }
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
