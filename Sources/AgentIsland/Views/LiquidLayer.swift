import SwiftUI

/// Exactly what the liquid needs to draw itself, and nothing that changes every frame.
///
/// Values are rounded to a quarter point so a settled island produces an identical
/// input frame after frame, which lets SwiftUI skip the canvas entirely.
struct LiquidShape: Equatable {
    /// Top-left of the band the canvas draws into, in panel coordinates.
    var origin: CGPoint
    var size: CGSize
    var notchRect: CGRect
    var leftBulge: CGFloat
    var rightBulge: CGFloat
    var circles: [CGRect]
    var card: CGRect?

    init(geometry: NotchGeometry, layouts: [BubbleLayout], card: CGRect?) {
        func round(_ value: CGFloat) -> CGFloat { (value * 4).rounded() / 4 }
        func round(_ rect: CGRect) -> CGRect {
            CGRect(x: round(rect.minX), y: round(rect.minY), width: round(rect.width), height: round(rect.height))
        }

        let band = geometry.bandRect(cardBottom: card?.maxY)
        origin = band.origin
        size = band.size

        func shifted(_ rect: CGRect) -> CGRect {
            round(rect.offsetBy(dx: -band.minX, dy: -band.minY))
        }
        notchRect = shifted(geometry.notchRect)
        leftBulge = round(IslandLayout.bulge(layouts: layouts, rightSide: false))
        rightBulge = round(IslandLayout.bulge(layouts: layouts, rightSide: true))
        circles = layouts.filter { $0.progress > 0.01 }.map { shifted($0.rect) }
        self.card = card.map(shifted)
    }
}

/// The black liquid: the notch itself plus one blob per circle, blurred together and
/// then hard-thresholded so they fuse and separate like a droplet pulling off the bezel.
struct LiquidLayer: View, @MainActor Equatable {
    let shape: LiquidShape

    /// Bigger blur means a longer, stringier neck.
    private let blurRadius: CGFloat = 5.5
    private let threshold: Double = 0.42

    static func == (lhs: LiquidLayer, rhs: LiquidLayer) -> Bool {
        lhs.shape == rhs.shape
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            context.addFilter(.alphaThreshold(min: threshold, color: .black))
            context.addFilter(.blur(radius: blurRadius))

            context.drawLayer { layer in
                layer.fill(notchPath, with: .color(.black))

                for circle in shape.circles {
                    layer.fill(Path(ellipseIn: circle), with: .color(.black))
                }

                if let card = shape.card {
                    layer.fill(
                        Path(roundedRect: card, cornerRadius: 16, style: .continuous),
                        with: .color(.black)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The notch body. It runs off the top of the view so the blur cannot round the
    /// edge that meets the bezel, and swells sideways while a circle is emerging.
    private var notchPath: Path {
        let notch = shape.notchRect
        let rect = CGRect(
            x: notch.minX - shape.leftBulge,
            y: -24,
            width: notch.width + shape.leftBulge + shape.rightBulge,
            height: notch.height + 24
        )
        return Path(roundedRect: rect, cornerRadius: 10, style: .continuous)
    }
}
