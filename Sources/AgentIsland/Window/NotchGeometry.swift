import AppKit
import IslandCore
import SwiftUI

/// Where the notch is, and where the circles sit beside it.
///
/// The overlay window is only as wide as the island needs, and everything here is in
/// panel coordinates: origin at the window's top-left, y growing downward, which is
/// what SwiftUI wants.
struct NotchGeometry: Equatable {
    /// Tall enough for the menu bar strip plus the card, dropped down.
    static let panelHeight: CGFloat = 500
    /// Everyday height: just the strip the circles live in. Compositing a small
    /// window every frame costs far less than a tall, mostly empty one.
    var compactHeight: CGFloat { notchRect.height + 22 }
    /// Used on screens with no notch.
    static let syntheticNotchWidth: CGFloat = 190
    /// How many circles fit on one side before they cover too many menu items.
    static let maximumPerSide = 4

    /// The screen the island lives on.
    var screenFrame: CGRect
    /// The window's frame, in AppKit screen coordinates.
    var panelFrame: CGRect
    /// The notch, in panel coordinates.
    var notchRect: CGRect
    var hasRealNotch: Bool

    var circleDiameter: CGFloat { max(20, min(34, notchRect.height - 4)) }
    /// Wide enough that a settled circle reads as separate from the notch, given the
    /// blur radius the liquid layer uses.
    var gapFromNotch: CGFloat { 12 }
    var circleSpacing: CGFloat { 8 }

    /// How far out from the notch the furthest circle can sit.
    var sideExtent: CGFloat { Self.sideExtent(circleDiameter: circleDiameter) }

    private static func sideExtent(circleDiameter: CGFloat) -> CGFloat {
        12 + CGFloat(maximumPerSide) * (circleDiameter + 8) + 16
    }

    static func current(screen: NSScreen? = nil) -> NotchGeometry {
        let target = screen ?? notchScreen()
        let frame = target.frame

        var notchWidth = syntheticNotchWidth
        var notchHeight = max(NSStatusBar.system.thickness, 24)
        var notchMinX = (frame.width - syntheticNotchWidth) / 2
        var real = false

        if let topLeft = target.auxiliaryTopLeftArea,
           let topRight = target.auxiliaryTopRightArea,
           target.safeAreaInsets.top > 0 {
            notchWidth = frame.width - topLeft.width - topRight.width
            notchHeight = target.safeAreaInsets.top
            notchMinX = topLeft.width
            real = true
        }

        // The window hugs the island: the notch plus room for the circles on each side.
        let diameter = max(20, min(34, notchHeight - 4))
        let extent = sideExtent(circleDiameter: diameter)
        let width = min(frame.width, notchWidth + extent * 2)
        let originX = min(max(0, notchMinX - extent), max(0, frame.width - width))

        return NotchGeometry(
            screenFrame: frame,
            panelFrame: CGRect(
                x: frame.minX + originX,
                y: frame.maxY - panelHeight,
                width: width,
                height: panelHeight
            ),
            notchRect: CGRect(x: notchMinX - originX, y: 0, width: notchWidth, height: notchHeight),
            hasRealNotch: real
        )
    }

    /// Prefers a screen that actually has a notch, then the main screen.
    static func notchScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    /// The strip the liquid draws in. Keeping it small matters: the layer is blurred
    /// and thresholded every frame, and the window damage follows it.
    func bandRect(cardBottom: CGFloat? = nil) -> CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: panelFrame.width,
            height: max(notchRect.height + 16, (cardBottom ?? 0) + 8)
        )
    }

    /// The centre of the circle `rank` places out from the notch on one side.
    func slotCenter(side: IslandSide, rank: Int) -> CGPoint {
        let offset = gapFromNotch + circleDiameter / 2 + CGFloat(rank) * (circleDiameter + circleSpacing)
        let x = side == .right ? notchRect.maxX + offset : notchRect.minX - offset
        return CGPoint(x: x, y: notchRect.midY)
    }

    /// Where a circle hides: tucked just inside that side's notch wall.
    func slotOrigin(side: IslandSide) -> CGPoint {
        let x = side == .right
            ? notchRect.maxX - circleDiameter * 0.35
            : notchRect.minX + circleDiameter * 0.35
        return CGPoint(x: x, y: notchRect.midY)
    }

    /// Which side of the notch a point is on.
    func side(for x: CGFloat) -> IslandSide {
        x < notchRect.midX ? .left : .right
    }

    /// How many places out from the notch a point is on its side, as a fraction:
    /// 0 is the first place, 1 the second, negative is inside the notch.
    func fractionalRank(for x: CGFloat, side: IslandSide) -> CGFloat {
        let distance = side == .right ? x - notchRect.maxX : notchRect.minX - x
        return (distance - gapFromNotch - circleDiameter / 2) / (circleDiameter + circleSpacing)
    }
}
