import IslandCore
import SwiftUI

/// The island itself, with no dependency on the model or on wall-clock time, so it
/// can be rendered live inside a TimelineView or offscreen by `--render`.
struct IslandContent: View {
    let geometry: NotchGeometry
    let layouts: [BubbleLayout]
    let clock: Double
    /// Wall clock, for "how long has this status been up" decisions.
    var now: Date = Date()
    let petID: String
    let hoveredID: String?
    let expandedID: String?
    var onTap: ((String) -> Void)?

    var body: some View {
        let expanded = layouts.first { $0.id == expandedID && $0.progress > 0.8 }
        let cardRect = expanded.map { IslandLayout.cardRect(around: $0.center.x, geometry: geometry) }

        let _ = Diagnostics.count("island-body")
        ZStack(alignment: .topLeading) {
            let shape = LiquidShape(geometry: geometry, layouts: layouts, card: cardRect)
            LiquidLayer(shape: shape)
                .equatable()
                .frame(width: shape.size.width, height: shape.size.height)
                .offset(x: shape.origin.x, y: shape.origin.y)

            IslandCanvas(
                layouts: layouts,
                petID: petID,
                clock: clock,
                now: now,
                hoveredID: hoveredID
            )

            // A click target per circle; the drawing itself is in the canvas above.
            ForEach(layouts) { layout in
                Color.clear
                    .frame(width: layout.diameter + 6, height: layout.diameter + 6)
                    .contentShape(Circle())
                    .position(layout.center)
                    .onTapGesture { onTap?(layout.id) }
            }

            if let expanded, let cardRect {
                ExpandedCard(session: expanded.session, clock: clock)
                    .frame(width: cardRect.width, height: cardRect.height)
                    .position(x: cardRect.midX, y: cardRect.midY)
                    .onTapGesture { onTap?(expanded.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// What the overlay window hosts: the island, driven by one animation clock.
struct IslandRootView: View {
    let geometry: NotchGeometry
    @Bindable var model: IslandModel

    /// One clock for the whole island, so mascots, rings, and sparks stay in step.
    private static let epoch = Date()

    var body: some View {
        // Reading the mode here is what re-creates the TimelineView when the island
        // speeds up or settles down; a schedule is fixed once its body has run.
        let mode = model.animationMode
        TimelineView(.animation(minimumInterval: mode.minimumInterval, paused: mode.isPaused)) { timeline in
            let now = timeline.date
            IslandContent(
                geometry: geometry,
                layouts: IslandLayout.layouts(for: model.bubbles, geometry: geometry, now: now),
                clock: now.timeIntervalSince(Self.epoch),
                now: now,
                petID: model.settings.codexPetID,
                hoveredID: model.hoveredID,
                expandedID: model.expandedID,
                onTap: { model.open(id: $0) }
            )
        }
        .ignoresSafeArea()
    }
}
