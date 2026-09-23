import AppKit
import IslandCore
import SwiftUI

/// The app icon, drawn rather than shipped. The Codex side holds a plain stand-in
/// bot, so none of the Codex app's art ends up inside this bundle.
struct AppIconView: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size.width
            // Apple's icon grid: the tile fills 824 of 1024 points, centred.
            let tile = size * 824 / 1024
            let inset = (size - tile) / 2

            IconArtwork(side: tile)
                .frame(width: tile, height: tile)
                .clipShape(RoundedRectangle(cornerRadius: tile * 0.2237, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: size * 0.012, y: size * 0.01)
                .offset(x: inset, y: inset)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The island: a black pill with a Codex circle out on one side and a Clawd circle
/// still pulling free on a liquid neck on the other.
private struct IconArtwork: View {
    let side: CGFloat

    var body: some View {
        let diameter = side * 0.25
        let top = side * 0.46 - diameter / 2
        let codex = CGRect(x: side * 0.05, y: top, width: diameter, height: diameter)
        let island = CGRect(x: side * 0.34, y: top, width: side * 0.28, height: diameter)
        let claude = CGRect(x: side * 0.68, y: top, width: diameter, height: diameter)

        ZStack(alignment: .topLeading) {
            // A dusk wallpaper, so the black notch reads against it.
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.09, blue: 0.14),
                    Color(red: 0.16, green: 0.13, blue: 0.26),
                    Color(red: 0.34, green: 0.19, blue: 0.27),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [IslandStyle.claude.opacity(0.7), .clear],
                center: UnitPoint(x: 0.8, y: 1.05),
                startRadius: 0,
                endRadius: side * 0.75
            )
            RadialGradient(
                colors: [IslandStyle.codex.opacity(0.5), .clear],
                center: UnitPoint(x: 0.05, y: 0.9),
                startRadius: 0,
                endRadius: side * 0.6
            )

            // The black parts, fused the way the island's liquid layer fuses them.
            Canvas { context, _ in
                context.addFilter(.alphaThreshold(min: 0.5, color: .black))
                context.addFilter(.blur(radius: side * 0.022))
                context.drawLayer { layer in
                    layer.fill(
                        Path(roundedRect: island, cornerRadius: diameter / 2, style: .continuous),
                        with: .color(.black)
                    )
                    layer.fill(Path(ellipseIn: claude), with: .color(.black))
                    // The neck the circle is pulling free of.
                    let neck = CGRect(
                        x: island.maxX - side * 0.03,
                        y: claude.midY - side * 0.03,
                        width: claude.minX - island.maxX + side * 0.06,
                        height: side * 0.06
                    )
                    layer.fill(Path(roundedRect: neck, cornerRadius: side * 0.03), with: .color(.black))
                    layer.fill(Path(ellipseIn: codex), with: .color(.black))
                }
            }

            IconRing(kind: .claude, rect: claude, side: side) {
                ClawdView(status: .complete, color: IslandStyle.claude, clock: 0, secondsInStatus: 10)
                    .frame(width: claude.width * 0.64)
            }
            IconRing(kind: .codex, rect: codex, side: side) {
                StandInBot(color: IslandStyle.codex)
                    .frame(width: codex.width * 0.52)
            }
        }
        .frame(width: side, height: side)
    }
}

/// A status ring in the agent's aurora colours, with a glow behind it.
private struct IconRing<Content: View>: View {
    let kind: AgentKind
    let rect: CGRect
    let side: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content
            Circle()
                .strokeBorder(
                    AngularGradient(colors: IslandStyle.brandHues(kind), center: .center, angle: .degrees(-40)),
                    lineWidth: rect.width * 0.08
                )
                .shadow(color: IslandStyle.brand(kind).opacity(0.8), radius: side * 0.02)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// The same plain bot the island falls back to when no Codex pet can be loaded.
private struct StandInBot: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height)
            let head = CGRect(x: 0, y: unit * 0.12, width: unit, height: unit * 0.76)
            context.fill(Path(roundedRect: head, cornerRadius: unit * 0.24), with: .color(color))
            let eye = unit * 0.13
            for dx in [-0.2, 0.2] as [CGFloat] {
                let rect = CGRect(
                    x: head.midX + dx * unit - eye / 2,
                    y: head.midY - eye / 2,
                    width: eye,
                    height: eye
                )
                context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.85)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

@MainActor
enum AppIcon {
    /// The icon at an exact pixel size.
    static func image(pixels: Int) -> CGImage? {
        let renderer = ImageRenderer(
            content: AppIconView().frame(width: CGFloat(pixels), height: CGFloat(pixels))
        )
        renderer.scale = 1
        return renderer.cgImage
    }

    /// For the Dock, when the bundle carries no icon file (a plain `swift build`).
    static func applyIfBundleHasNone() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
              let image = image(pixels: 512)
        else { return }
        NSApp.applicationIconImage = NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
    }

    /// `AgentIsland --render-icon <dir>.iconset` writes every size `iconutil` wants.
    static func writeIconset(to path: String) {
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                let url = directory.appendingPathComponent(name)
                guard
                    let image = image(pixels: points * scale),
                    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
                else {
                    print("could not render \(name)")
                    continue
                }
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        print("wrote \(directory.path)")
    }
}
