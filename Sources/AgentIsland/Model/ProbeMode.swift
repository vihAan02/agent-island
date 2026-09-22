import AppKit
import Foundation
import IslandCore

/// `AgentIsland --probe` runs the watchers for a few seconds with no window and
/// prints what they found. It is the quickest way to see whether sessions are being
/// detected, and what status, effort, and titles they carry.
@MainActor
enum ProbeMode {
    static func run() async {
        let model = IslandModel(settings: AppEnvironment.shared.settings)
        model.start()
        reportScreen(model)
        print("watching \(IslandPaths.claudeSessions) and \(IslandPaths.codexSessions)")
        print("hook socket: \(IslandPaths.socketPath)")
        print("claude hooks installed: \(AppEnvironment.shared.settings.claudeHooksInstalled)")

        for step in 1...6 {
            try? await Task.sleep(for: .seconds(1))
            print("\n[\(step)s] \(model.bubbles.count) circle(s)")
            for bubble in model.bubbles {
                let session = bubble.session
                print(
                    "  slot \(bubble.slot)  \(session.kind.rawValue)  \(session.status.rawValue)"
                        + "  effort=\(session.effortLabel)"
                        + "  repo=\(session.repo)"
                        + "  title=\(session.displayTitle)"
                        + (session.detail.map { "  detail=\($0)" } ?? "")
                )
            }
        }
        NSApp.terminate(nil)
    }

    /// Prints the notch measurements and where the circles will sit, so the overlay's
    /// placement can be checked without taking a screenshot.
    private static func reportScreen(_ model: IslandModel) {
        let geometry = NotchGeometry.current()
        let screen = NotchGeometry.notchScreen()
        print(
            "\nscreen \(Int(screen.frame.width))x\(Int(screen.frame.height))"
                + "  notch=\(geometry.hasRealNotch ? "real" : "synthetic")"
                + "  safeAreaTop=\(screen.safeAreaInsets.top)"
        )
        print(
            "notch rect \(Int(geometry.notchRect.minX))..\(Int(geometry.notchRect.maxX))"
                + " x \(Int(geometry.notchRect.height))pt"
                + "  circle=\(Int(geometry.circleDiameter))pt"
        )
        print("panel frame \(geometry.panelFrame)")
        for slot in 0..<4 {
            let center = geometry.slotCenter(index: slot)
            print("  slot \(slot) \(geometry.isOnRightSide(index: slot) ? "right" : "left ") center=(\(Int(center.x)), \(Int(center.y)))")
        }
    }
}
