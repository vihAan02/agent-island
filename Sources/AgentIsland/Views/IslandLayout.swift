import Foundation
import IslandCore
import SwiftUI

/// Where one circle is right now, and how far out of the notch it has come.
struct BubbleLayout: Identifiable, Equatable {
    var id: String
    var session: AgentSession
    var slot: Int
    var center: CGPoint
    var diameter: CGFloat
    /// 0 = fully tucked inside the notch, 1 = fully out.
    var progress: Double
    var isOnRightSide: Bool

    /// Content fades in only once the circle has pulled clear of the notch.
    var contentOpacity: Double { Spring.smoothstep(progress, from: 0.45, to: 0.85) }
    var scale: Double { 0.62 + 0.38 * min(max(progress, 0), 1) }
    var rect: CGRect {
        CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }
}

/// Turns bubbles plus a clock into laid-out circles.
enum IslandLayout {
    static let emergeResponse: Double = 0.5
    static let emergeDamping: Double = 0.62
    static let retractDuration: Double = 0.55

    static func layouts(
        for bubbles: [Bubble],
        geometry: NotchGeometry,
        now: Date
    ) -> [BubbleLayout] {
        bubbles.compactMap { bubble in
            // Beyond the per-side cap the circle stays inside the notch.
            guard bubble.slot / 2 < NotchGeometry.maximumPerSide else { return nil }

            let progress = progress(for: bubble, now: now)
            let start = geometry.slotOrigin(index: bubble.slot)
            let end = geometry.slotCenter(index: bubble.slot)
            let center = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            return BubbleLayout(
                id: bubble.id,
                session: bubble.session,
                slot: bubble.slot,
                center: center,
                diameter: geometry.circleDiameter,
                progress: progress,
                isOnRightSide: geometry.isOnRightSide(index: bubble.slot)
            )
        }
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
            y: geometry.notchRect.maxY + 5,
            width: size.width,
            height: size.height
        )
    }

    /// How far the notch wall swells on each side while a circle is pulling away.
    /// This is the part that reads as the bezel stretching.
    static func bulge(layouts: [BubbleLayout], rightSide: Bool) -> CGFloat {
        let candidates = layouts.filter { $0.isOnRightSide == rightSide && $0.slot / 2 == 0 }
        let peak = candidates.map { layout -> Double in
            let t = min(max(layout.progress / 0.65, 0), 1)
            return sin(t * .pi)
        }.max() ?? 0
        return CGFloat(peak) * 7
    }
}
