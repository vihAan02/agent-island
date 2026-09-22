import AppKit
import IslandCore
import SwiftUI

/// Clawd, drawn as the sub-pixel grid the CLI draws him with.
struct ClawdView: View {
    let status: AgentStatus
    let color: Color
    /// Seconds on the shared island clock, so every mascot animates in step.
    let clock: Double
    let secondsInStatus: Double

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let animation = ClawdAnimation.animation(for: status, secondsInStatus: secondsInStatus)
            let frame = ClawdSprite.frame(animation.pose(at: clock))

            let pixelWidth = size.width / CGFloat(ClawdSprite.frameWidth)
            let pixelHeight = size.height / CGFloat(ClawdSprite.frameHeight)
            let offset = motionOffset(animation.motion, pixelWidth: pixelWidth, pixelHeight: pixelHeight)

            var path = Path()
            for y in 0..<frame.height {
                for x in 0..<frame.width where frame.isSet(x: x, y: y) {
                    // A hair of overlap keeps neighbouring blocks from showing seams.
                    path.addRect(
                        CGRect(
                            x: CGFloat(x) * pixelWidth + offset.x,
                            y: CGFloat(y) * pixelHeight + offset.y,
                            width: pixelWidth + 0.35,
                            height: pixelHeight + 0.35
                        )
                    )
                }
            }
            context.fill(path, with: .color(color))
        }
        .aspectRatio(CGSize(width: 3, height: 2), contentMode: .fit)
    }

    private func motionOffset(
        _ motion: ClawdAnimation.Motion,
        pixelWidth: CGFloat,
        pixelHeight: CGFloat
    ) -> CGPoint {
        switch motion {
        case .none:
            return .zero
        case .bob(let amplitude, let period):
            let phase = sin(clock / period * 2 * .pi)
            return CGPoint(x: 0, y: CGFloat(phase * amplitude) * pixelHeight * 0.5)
        case .shake(let amplitude, let period):
            let phase = sin(clock / period * 2 * .pi)
            let decay = max(0, 1 - secondsInStatus / 1.6)
            return CGPoint(x: CGFloat(phase * amplitude * decay) * pixelWidth, y: 0)
        case .hop(let height, let period):
            let t = (clock / period).truncatingRemainder(dividingBy: 1)
            // A parabola reads as a hop far better than a sine.
            let lift = 4 * t * (1 - t)
            return CGPoint(x: 0, y: -CGFloat(lift * height) * pixelHeight * 0.5)
        }
    }
}

/// The Codex pet, drawn from the sprite sheet inside the installed Codex app.
struct CodexPetView: View {
    let petID: String
    let status: AgentStatus
    let clock: Double
    let secondsInStatus: Double
    /// Shown when the sprite sheet cannot be found.
    let fallbackColor: Color

    var body: some View {
        let animation = PetAnimations.animation(for: status, secondsInStatus: secondsInStatus)
        let column = animation.frame(at: clock)

        Group {
            if let image = PetSpriteStore.shared.cell(pet: petID, row: animation.row, column: column) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                FallbackBotView(color: fallbackColor)
            }
        }
    }
}

/// Stand-in mascot for when the Codex app is not installed.
private struct FallbackBotView: View {
    let color: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let unit = min(size.width, size.height)
            let head = CGRect(
                x: size.width / 2 - unit * 0.34,
                y: size.height / 2 - unit * 0.32,
                width: unit * 0.68,
                height: unit * 0.52
            )
            context.fill(Path(roundedRect: head, cornerRadius: unit * 0.16), with: .color(color))
            let eyeSize = unit * 0.08
            for dx in [-0.14, 0.14] as [CGFloat] {
                let eye = CGRect(
                    x: head.midX + dx * unit - eyeSize / 2,
                    y: head.midY - eyeSize / 2,
                    width: eyeSize,
                    height: eyeSize
                )
                context.fill(Path(ellipseIn: eye), with: .color(.black.opacity(0.8)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Loads pet sprite sheets once and hands out cropped cells.
///
/// The art stays where it was installed: this reads it out of the Codex app's asar
/// (or `~/.codex/pets`) and caches the extracted sheet under `~/Library/Caches`.
@MainActor
final class PetSpriteStore {
    static let shared = PetSpriteStore()

    private let catalog = PetCatalog()
    private var atlases: [String: CGImage?] = [:]
    private var cells: [String: CGImage] = [:]
    private let layout = PetAtlasLayout()

    func cell(pet: String, row: Int, column: Int) -> CGImage? {
        let key = "\(pet)#\(row)#\(column)"
        if let cached = cells[key] { return cached }
        guard let atlas = atlas(for: pet) else { return nil }

        let cellWidth = atlas.width / layout.columns
        let cellHeight = atlas.height / layout.rows
        let rect = CGRect(
            x: column * cellWidth,
            y: row * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        guard let cropped = atlas.cropping(to: rect) else { return nil }
        cells[key] = cropped
        return cropped
    }

    private func atlas(for pet: String) -> CGImage? {
        if let cached = atlases[pet] { return cached }

        var image: CGImage?
        if let path = catalog.imagePath(for: pet),
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           CGImageSourceGetCount(source) > 0 {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        atlases[pet] = image
        return image
    }

    private var petIDs: [String]?

    /// Pets the user can pick in settings. Computed once: the menu asks for this
    /// every time it re-renders.
    func availablePetIDs() -> [String] {
        if let petIDs { return petIDs }
        let custom = catalog.customPets().map(\.id)
        let all = custom + catalog.builtInPetIDs().filter { !custom.contains($0) }
        petIDs = all
        return all
    }
}
