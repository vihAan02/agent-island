import IslandCore
import SwiftUI

/// Draws every circle — mascot, effort light, status ring — in one canvas.
///
/// This used to be a small view tree per circle. Drawing it directly is much
/// cheaper per frame: no view graph to diff sixty times a second, and no offscreen
/// shadow passes, since the glows are drawn as wider, fainter strokes.
struct IslandCanvas: View {
    let layouts: [BubbleLayout]
    let petID: String
    /// Shared island clock, in seconds.
    let clock: Double
    let now: Date
    let hoveredID: String?

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for layout in layouts where layout.contentOpacity > 0.01 {
                draw(layout, in: context)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - One circle

    private func draw(_ layout: BubbleLayout, in context: GraphicsContext) {
        let session = layout.session
        let scale = layout.scale * (hoveredID == layout.id ? 1.08 : 1)
        let diameter = layout.diameter * scale
        let rect = CGRect(
            x: layout.center.x - diameter / 2,
            y: layout.center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        let secondsInStatus = max(0, now.timeIntervalSince(session.statusChangedAt))
        let isActive = session.status == .working || session.status == .plan

        var circle = context
        circle.opacity = layout.contentOpacity

        // The black disc keeps the mascot legible over whatever is behind the menu bar.
        circle.fill(Path(ellipseIn: rect), with: .color(.black))

        drawMascot(session: session, in: rect, secondsInStatus: secondsInStatus, context: circle)
        drawEffortLight(session: session, in: rect, isActive: isActive, context: circle)
        drawStatusRing(session: session, in: rect, secondsInStatus: secondsInStatus, context: circle)
    }

    // MARK: - Mascots

    private func drawMascot(
        session: AgentSession,
        in rect: CGRect,
        secondsInStatus: Double,
        context: GraphicsContext
    ) {
        var inner = context
        if session.status == .idle { inner.opacity *= 0.6 }

        switch session.kind {
        case .claude:
            drawClawd(session: session, in: rect, secondsInStatus: secondsInStatus, context: inner)
        case .codex:
            drawPet(session: session, in: rect, secondsInStatus: secondsInStatus, context: inner)
        }
    }

    /// Clawd is a grid of sub-pixels, drawn as one path.
    private func drawClawd(
        session: AgentSession,
        in rect: CGRect,
        secondsInStatus: Double,
        context: GraphicsContext
    ) {
        let animation = ClawdAnimation.animation(for: session.status, secondsInStatus: secondsInStatus)
        let sprite = ClawdSprite.frame(animation.pose(at: clock))

        // 18 x 6 sub-pixels at 3:2, sized to sit comfortably inside the circle.
        let width = rect.width * 0.66
        let height = width * 2 / 3
        let pixelWidth = width / CGFloat(ClawdSprite.frameWidth)
        let pixelHeight = height / CGFloat(ClawdSprite.frameHeight)
        let motion = clawdOffset(animation.motion, secondsInStatus: secondsInStatus, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let originX = rect.midX - width / 2 + motion.x
        let originY = rect.midY - height / 2 + motion.y

        var path = Path()
        for y in 0..<sprite.height {
            for x in 0..<sprite.width where sprite.isSet(x: x, y: y) {
                path.addRect(
                    CGRect(
                        x: originX + CGFloat(x) * pixelWidth,
                        y: originY + CGFloat(y) * pixelHeight,
                        // A hair of overlap, so neighbouring blocks show no seams.
                        width: pixelWidth + 0.3,
                        height: pixelHeight + 0.3
                    )
                )
            }
        }

        let color: Color = switch session.status {
        case .error: IslandStyle.error
        default: IslandStyle.claude
        }
        context.fill(path, with: .color(color))
    }

    private func clawdOffset(
        _ motion: ClawdAnimation.Motion,
        secondsInStatus: Double,
        pixelWidth: CGFloat,
        pixelHeight: CGFloat
    ) -> CGPoint {
        switch motion {
        case .none:
            .zero
        case .bob(let amplitude, let period):
            CGPoint(x: 0, y: CGFloat(sin(clock / period * 2 * .pi) * amplitude) * pixelHeight * 0.5)
        case .shake(let amplitude, let period):
            CGPoint(
                x: CGFloat(sin(clock / period * 2 * .pi) * amplitude * max(0, 1 - secondsInStatus / 1.6)) * pixelWidth,
                y: 0
            )
        case .hop(let height, let period):
            // A parabola reads as a hop far better than a sine.
            {
                let t = (clock / period).truncatingRemainder(dividingBy: 1)
                return CGPoint(x: 0, y: -CGFloat(4 * t * (1 - t) * height) * pixelHeight * 0.5)
            }()
        }
    }

    /// The Codex pet is one cell of its sprite sheet.
    private func drawPet(
        session: AgentSession,
        in rect: CGRect,
        secondsInStatus: Double,
        context: GraphicsContext
    ) {
        let animation = PetAnimations.animation(for: session.status, secondsInStatus: secondsInStatus)
        let column = animation.frame(at: clock)
        let side = rect.width * 0.8
        let petRect = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )

        guard let cell = PetSpriteStore.shared.cell(pet: petID, row: animation.row, column: column) else {
            // No Codex app, no sprite sheet: draw a plain stand-in.
            let head = petRect.insetBy(dx: side * 0.16, dy: side * 0.24)
            context.fill(
                Path(roundedRect: head, cornerRadius: side * 0.16),
                with: .color(IslandStyle.codex)
            )
            return
        }
        let image = Image(decorative: cell, scale: 1).interpolation(.high)
        context.draw(image, in: petRect)
    }

    // MARK: - Effort light

    private func drawEffortLight(
        session: AgentSession,
        in rect: CGRect,
        isActive: Bool,
        context: GraphicsContext
    ) {
        var light = context
        light.opacity *= isActive ? 1 : 0.25

        let tier = session.effectiveEffort
        let ringRect = rect.insetBy(dx: 1.1, dy: 1.1)

        switch tier {
        case .ultra:
            drawAurora(session: session, in: ringRect, isActive: isActive, context: light)
        case .max:
            drawShimmer(session: session, in: ringRect, isActive: isActive, context: light)
        default:
            drawComets(tier: tier, session: session, in: ringRect, isActive: isActive, context: light)
        }
    }

    /// One to three comets chasing each other around the ring; more and faster with
    /// every effort tier.
    private func drawComets(
        tier: EffortTier,
        session: AgentSession,
        in rect: CGRect,
        isActive: Bool,
        context: GraphicsContext
    ) {
        let spec = Self.cometSpec(for: tier)
        let color = IslandStyle.brand(session.kind)
        let rotation = isActive ? clock / spec.period : 0

        for index in 0..<spec.count {
            let start = rotation + Double(index) / Double(spec.count)
            let arc = Path(ellipseIn: rect).trimmedPath(
                from: start.truncatingRemainder(dividingBy: 1),
                to: (start + spec.arc).truncatingRemainder(dividingBy: 1)
            )
            // Two passes: a faint wide one for the glow, a bright thin one on top.
            if tier >= .high {
                context.stroke(arc, with: .color(color.opacity(spec.opacity * 0.25)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            }
            context.stroke(arc, with: .color(color.opacity(spec.opacity)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }

    private func drawShimmer(
        session: AgentSession,
        in rect: CGRect,
        isActive: Bool,
        context: GraphicsContext
    ) {
        let color = IslandStyle.brand(session.kind)
        let breath = 0.5 + 0.5 * sin(clock * 2.6)
        let angle = Angle.degrees(isActive ? clock * 190 : 0)
        let ring = Path(ellipseIn: rect)

        context.stroke(
            ring,
            with: .conicGradient(
                Gradient(colors: [
                    color.opacity(0.15), color.opacity(0.95), color.opacity(0.2),
                    color.opacity(0.95), color.opacity(0.15),
                ]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                angle: angle
            ),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
        )
        context.stroke(
            ring,
            with: .color(color.opacity(0.18 + 0.2 * breath)),
            style: StrokeStyle(lineWidth: 5.5)
        )
    }

    /// The signature for ultracode and Codex ultra: a full conic sweep in brand hues,
    /// a breathing bloom, and embers coming off the ring.
    private func drawAurora(
        session: AgentSession,
        in rect: CGRect,
        isActive: Bool,
        context: GraphicsContext
    ) {
        let hues = IslandStyle.auroraHues(session.kind)
        let breath = 0.5 + 0.5 * sin(clock * 1.7)
        let angle = Angle.degrees(isActive ? clock * 150 : 0)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ring = Path(ellipseIn: rect)
        let shading = GraphicsContext.Shading.conicGradient(
            Gradient(colors: hues),
            center: center,
            angle: angle
        )

        var bloom = context
        bloom.opacity *= 0.45 + 0.25 * breath
        bloom.stroke(ring, with: shading, style: StrokeStyle(lineWidth: 6 + 2 * breath))
        context.stroke(ring, with: shading, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))

        guard isActive else { return }
        let radius = rect.width / 2
        for index in 0..<6 {
            // Each ember runs its own slightly out-of-step loop.
            let phase = Double(index) * 0.618
            let life = (clock * 0.55 + phase).truncatingRemainder(dividingBy: 1)
            let direction = (phase * 2 * .pi) + clock * 1.1 + life * 0.6
            let distance = radius + CGFloat(life) * radius * 0.55
            let fade = (1 - life) * (1 - life)
            let dot = CGRect(
                x: center.x + cos(direction) * distance - 0.9,
                y: center.y + sin(direction) * distance - 0.9,
                width: 1.8,
                height: 1.8
            )
            context.fill(Path(ellipseIn: dot), with: .color(hues[index % hues.count].opacity(fade * 0.9)))
        }
    }

    // MARK: - Status ring

    private func drawStatusRing(
        session: AgentSession,
        in rect: CGRect,
        secondsInStatus: Double,
        context: GraphicsContext
    ) {
        let color = IslandStyle.ring(for: session)
        let pulse: CGFloat = session.status == .question ? 1 + 0.02 * CGFloat(sin(clock * 2.4)) : 1
        let ringRect = rect.insetBy(dx: 1.1 - (pulse - 1) * rect.width / 2, dy: 1.1 - (pulse - 1) * rect.height / 2)
        let ring = Path(ellipseIn: ringRect)

        let opacity: Double = switch session.status {
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

        // The glow is a wider, fainter stroke rather than a shadow.
        if session.status.demandsAttention || session.status == .complete {
            context.stroke(ring, with: .color(color.opacity(opacity * 0.22)), style: StrokeStyle(lineWidth: 5.5))
        }
        context.stroke(ring, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: 1.9))

        if session.status == .complete, secondsInStatus < 0.75 {
            // A single sweep around the ring when a turn lands.
            let sweep = Path(ellipseIn: ringRect).trimmedPath(from: 0, to: min(1, secondsInStatus / 0.6))
            context.stroke(sweep, with: .color(IslandStyle.complete), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
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
