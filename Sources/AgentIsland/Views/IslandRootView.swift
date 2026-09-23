import IslandCore
import SwiftUI

/// The card showing for one circle, and how far it has opened.
struct IslandCardState {
    var id: String
    /// 0 is the circle, 1 the full card; on a spring, so it can pass 1 a little.
    var openness: Double
    /// 0 folded, 1 dropped down, also on a spring.
    var details: Double = 0
    var diff: DiffState
    var conversation: CardConversation = .empty
}

/// The island itself, with no dependency on the model or on wall-clock time, so it
/// can be rendered live inside a TimelineView or offscreen by `--render`.
struct IslandContent: View {
    let geometry: NotchGeometry
    let layouts: [BubbleLayout]
    let clock: Double
    /// Wall clock, for "how long has this status been up" decisions.
    var now: Date = Date()
    let petID: String
    var card: IslandCardState?
    /// What the card's controls do; offscreen, nothing.
    var actions: CardActions = .inert

    var body: some View {
        let cardLayout = card.flatMap { card in layouts.first { $0.id == card.id } }
        let frame = cardLayout.map { layout in
            IslandLayout.cardFrame(for: layout, openness: card?.openness ?? 0, details: card?.details ?? 0, geometry: geometry)
        }

        let _ = Diagnostics.count("island-body")
        ZStack(alignment: .topLeading) {
            let shape = LiquidShape(
                geometry: geometry,
                layouts: layouts,
                card: frame?.rect,
                cardCornerRadius: frame?.cornerRadius ?? IslandLayout.cardCornerRadius
            )
            LiquidLayer(shape: shape)
                .equatable()
                .frame(width: shape.size.width, height: shape.size.height)
                .offset(x: shape.origin.x, y: shape.origin.y)

            IslandCanvas(
                layouts: layouts,
                petID: petID,
                clock: clock,
                now: now
            )

            // Presses on circles are handled by the panel's hosting view in AppKit.
            // The open card is ordinary SwiftUI: its buttons and field take clicks.
            if let card, let cardLayout, let frame {
                let target = IslandLayout.cardRect(around: cardLayout.center.x, geometry: geometry, details: card.details)
                ExpandedCard(
                    session: cardLayout.session,
                    diff: card.diff,
                    now: now,
                    details: card.details,
                    conversation: card.conversation,
                    actions: actions
                )
                    .frame(width: target.width, height: target.height, alignment: .topLeading)
                    .clipped()
                    // Words never show outside the liquid, even mid-pour.
                    .mask(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: frame.cornerRadius, style: .continuous)
                            .frame(width: frame.rect.width, height: frame.rect.height)
                            .offset(x: frame.rect.minX - target.minX, y: frame.rect.minY - target.minY)
                    }
                    .position(x: target.midX, y: target.midY)
                    // And they arrive once the liquid has nearly finished pouring.
                    .opacity(Spring.smoothstep(card.openness, from: 0.75, to: 0.98))
                    .allowsHitTesting(card.openness > 0.9)
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
                layouts: IslandLayout.layouts(for: model.bubbles, geometry: geometry, now: now, drag: model.liveDrag),
                clock: now.timeIntervalSince(Self.epoch),
                now: now,
                petID: model.settings.codexPetID,
                card: model.cardID.map { id in
                    IslandCardState(
                        id: id,
                        openness: model.cardOpenness.value(at: now),
                        details: model.detailsOpenness.value(at: now),
                        diff: model.diffState(forSession: id),
                        conversation: model.conversation(for: id)
                    )
                },
                actions: model.cardID.map { model.cardActions(for: $0) } ?? .inert
            )
        }
        .ignoresSafeArea()
    }
}
