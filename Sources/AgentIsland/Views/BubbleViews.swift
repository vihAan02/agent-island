import IslandCore
import SwiftUI

/// The ring around a circle. Its color is the status; its motion is the status too.
struct StatusRing: View {
    let session: AgentSession
    let clock: Double
    let secondsInStatus: Double

    var body: some View {
        let color = IslandStyle.ring(for: session)

        ZStack {
            Circle()
                .strokeBorder(color.opacity(baseOpacity), lineWidth: 1.9)
                .scaleEffect(pulseScale)

            if session.status == .complete, secondsInStatus < 0.75 {
                // A single sweep around the ring when a turn lands.
                Circle()
                    .trim(from: 0, to: min(1, secondsInStatus / 0.6))
                    .stroke(IslandStyle.complete, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        // Shadows are an extra offscreen pass each frame, so only the states that
        // need to catch your eye get one.
        .shadow(color: color.opacity(glowStrength), radius: glowStrength > 0 ? 4 : 0)
    }

    private var baseOpacity: Double {
        switch session.status {
        case .question:
            // Breathing, so it reads as waiting rather than stalled.
            0.55 + 0.45 * (0.5 + 0.5 * sin(clock * 2.4))
        case .error:
            // Two quick flashes, then solid.
            secondsInStatus < 0.6 ? (sin(secondsInStatus * 22) > 0 ? 1 : 0.25) : 0.95
        case .idle, .waiting:
            0.45
        default:
            0.9
        }
    }

    private var pulseScale: Double {
        guard session.status == .question else { return 1 }
        return 1 + 0.02 * sin(clock * 2.4)
    }

    private var glowStrength: Double {
        switch session.status {
        case .question, .error: 0.55
        case .complete: 0.45
        default: 0
        }
    }
}

/// The effort light: comets that orbit the ring while the agent is thinking.
/// Ultracode and Codex ultra get the aurora instead.
struct EffortAura: View {
    let session: AgentSession
    let clock: Double
    /// Only spin while there is something to spin for.
    let isActive: Bool

    var body: some View {
        let tier = session.effectiveEffort
        let color = IslandStyle.brand(session.kind)

        ZStack {
            if tier == .ultra {
                aurora
            } else if tier == .max {
                shimmer(color: color)
            } else {
                comets(tier: tier, color: color)
            }
        }
        .opacity(isActive ? 1 : 0.25)
        .allowsHitTesting(false)
    }

    // MARK: Tiers

    private func comets(tier: EffortTier, color: Color) -> some View {
        let spec = Self.cometSpec(for: tier)
        let rotation = isActive ? clock / spec.period * 360 : 0

        return ZStack {
            ForEach(0..<spec.count, id: \.self) { index in
                Circle()
                    .trim(from: 0, to: spec.arc)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [color.opacity(0), color.opacity(spec.opacity)]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * spec.arc)
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation + Double(index) * 360 / Double(spec.count)))
            }
        }
        .shadow(color: color.opacity(tier == .xhigh ? 0.5 : 0), radius: tier == .xhigh ? 3.5 : 0)
    }

    private func shimmer(color: Color) -> some View {
        let breath = 0.5 + 0.5 * sin(clock * 2.6)
        return Circle()
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [
                        color.opacity(0.15), color.opacity(0.95), color.opacity(0.2),
                        color.opacity(0.95), color.opacity(0.15),
                    ]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
            )
            .rotationEffect(.degrees(isActive ? clock * 190 : 0))
            .shadow(color: color.opacity(0.35 + 0.35 * breath), radius: 4 + 2 * breath)
    }

    /// The signature: a full conic sweep in brand hues, a breathing bloom, and sparks.
    private var aurora: some View {
        let hues = IslandStyle.auroraHues(session.kind)
        let breath = 0.5 + 0.5 * sin(clock * 1.7)
        let rotation = isActive ? clock * 150 : 0

        return ZStack {
            Circle()
                .stroke(
                    AngularGradient(gradient: Gradient(colors: hues), center: .center),
                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
                .blur(radius: 3.2 + 1.6 * breath)
                .opacity(0.75)

            Circle()
                .stroke(
                    AngularGradient(gradient: Gradient(colors: hues), center: .center),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))

            Sparks(clock: clock, colors: hues, isActive: isActive)
        }
    }

    private static func cometSpec(for tier: EffortTier) -> (count: Int, period: Double, arc: Double, opacity: Double) {
        switch tier {
        case .low: (1, 4.0, 0.10, 0.55)
        case .medium: (1, 3.0, 0.12, 0.75)
        case .high: (2, 2.2, 0.13, 0.85)
        case .xhigh: (3, 1.6, 0.14, 0.95)
        case .max, .ultra: (3, 1.2, 0.16, 1.0)
        }
    }
}

/// Small embers that lift off the ring. Only the ultra tier uses these.
private struct Sparks: View {
    let clock: Double
    let colors: [Color]
    let isActive: Bool

    private static let count = 6

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard isActive else { return }
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            for index in 0..<Self.count {
                // Each spark runs its own slightly out-of-step loop.
                let phase = Double(index) * 0.618
                let life = (clock * 0.55 + phase).truncatingRemainder(dividingBy: 1)
                let angle = (phase * 2 * .pi) + clock * 1.1 + life * 0.6
                let distance = radius + CGFloat(life) * radius * 0.55
                let point = CGPoint(
                    x: center.x + cos(angle) * distance,
                    y: center.y + sin(angle) * distance
                )
                let fade = (1 - life) * (1 - life)
                let dot = CGRect(x: point.x - 0.9, y: point.y - 0.9, width: 1.8, height: 1.8)
                context.fill(
                    Path(ellipseIn: dot),
                    with: .color(colors[index % colors.count].opacity(fade * 0.9))
                )
            }
        }
    }
}
