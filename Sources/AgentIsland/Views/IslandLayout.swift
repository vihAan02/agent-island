import Foundation
import IslandCore
import SwiftUI

/// Where one circle is right now, and how far out of the notch it has come.
struct BubbleLayout: Identifiable, Equatable {
    var id: String
    var session: AgentSession
    var side: IslandSide
    /// Places out from the notch, among the circles showing on its side.
    var rank: Int
    var center: CGPoint
    var diameter: CGFloat
    /// 0 = fully tucked inside the notch, 1 = fully out.
    var progress: Double
    /// Grows a touch while the pointer rests on it.
    var hoverScale: Double = 1

    var isOnRightSide: Bool { side == .right }

    /// Content fades in only once the circle has pulled clear of the notch.
    var contentOpacity: Double { Spring.smoothstep(progress, from: 0.45, to: 0.85) }
    var scale: Double { 0.62 + 0.38 * min(max(progress, 0), 1) }
    var rect: CGRect {
        let size = diameter * CGFloat(hoverScale)
        return CGRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
    }
}

/// The circle under the pointer while it is being dragged.
struct IslandDrag: Equatable {
    var id: String
    var center: CGPoint
}

/// Turns bubbles plus a clock into laid-out circles.
enum IslandLayout {
    static let emergeResponse: Double = 0.5
    static let emergeDamping: Double = 0.62
    static let retractDuration: Double = 0.55

    static func layouts(
        for bubbles: [Bubble],
        geometry: NotchGeometry,
        now: Date,
        drag: IslandDrag? = nil
    ) -> [BubbleLayout] {
        let laidOut = bubbles.compactMap { bubble -> BubbleLayout? in
            // A circle with no room on either side stays inside the notch.
            guard let side = bubble.side else { return nil }

            let hoverScale = bubble.hover.value(at: now)

            if let drag, drag.id == bubble.id {
                return BubbleLayout(
                    id: bubble.id,
                    session: bubble.session,
                    side: side,
                    rank: bubble.rank,
                    center: drag.center,
                    diameter: geometry.circleDiameter,
                    progress: 1,
                    hoverScale: hoverScale
                )
            }

            // Out of the notch wall along the emerge spring, towards a resting place
            // that has its own spring, so circles glide when they make room.
            let progress = progress(for: bubble, now: now)
            let start = geometry.slotOrigin(side: side)
            let end = CGPoint(x: bubble.x.value(at: now), y: bubble.y.value(at: now))
            return BubbleLayout(
                id: bubble.id,
                session: bubble.session,
                side: side,
                rank: bubble.rank,
                center: CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                ),
                diameter: geometry.circleDiameter,
                progress: progress,
                hoverScale: hoverScale
            )
        }
        // The dragged circle is drawn last, so it passes over the others.
        guard let drag else { return laidOut }
        return laidOut.filter { $0.id != drag.id } + laidOut.filter { $0.id == drag.id }
    }

    static func progress(for bubble: Bubble, now: Date) -> Double {
        if let retracting = bubble.retractingSince {
            let elapsed = now.timeIntervalSince(retracting)
            let t = min(max(elapsed / retractDuration, 0), 1)
            // Ease in, so the circle accelerates back into the notch.
            return 1 - (t * t * (3 - 2 * t))
        }
        return Spring.value(
            time: now.timeIntervalSince(bubble.appearedAt),
            response: emergeResponse,
            damping: emergeDamping
        )
    }

    /// The hover card hangs under the menu bar, centred on its circle but kept on screen.
    static func cardRect(around centerX: CGFloat, geometry: NotchGeometry) -> CGRect {
        let size = ExpandedCard.size
        let minX: CGFloat = 12
        let maxX = max(minX, geometry.panelFrame.width - size.width - 12)
        return CGRect(
            x: min(max(centerX - size.width / 2, minX), maxX),
            // Far enough below the row that the open card does not fuse with the
            // circles beside the one it came from.
            y: geometry.notchRect.maxY + 9,
            width: size.width,
            height: size.height
        )
    }

    /// The card as it pours out of its circle: `openness` 0 is the circle itself,
    /// 1 the full card below the menu bar. A spring can carry it a little past 1.
    static func cardFrame(
        for layout: BubbleLayout,
        openness: Double,
        geometry: NotchGeometry
    ) -> (rect: CGRect, cornerRadius: CGFloat) {
        let target = cardRect(around: layout.center.x, geometry: geometry)
        let start = layout.rect
        let t = CGFloat(max(0, openness))
        let rect = CGRect(
            x: start.minX + (target.minX - start.minX) * t,
            y: start.minY + (target.minY - start.minY) * t,
            width: start.width + (target.width - start.width) * t,
            height: start.height + (target.height - start.height) * t
        )
        let radius = start.width / 2 + (cardCornerRadius - start.width / 2) * min(t, 1)
        return (rect, radius)
    }

    static let cardCornerRadius: CGFloat = 18

    /// How far the notch wall swells on each side while a circle is pulling away.
    /// This is the part that reads as the bezel stretching.
    static func bulge(layouts: [BubbleLayout], rightSide: Bool) -> CGFloat {
        let candidates = layouts.filter { $0.isOnRightSide == rightSide && $0.rank == 0 }
        let peak = candidates.map { layout -> Double in
            let t = min(max(layout.progress / 0.65, 0), 1)
            return sin(t * .pi)
        }.max() ?? 0
        return CGFloat(peak) * 7
    }
}
