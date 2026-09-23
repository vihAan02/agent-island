import AppKit
import Foundation
import IslandCore

/// `AgentIsland --probe [seconds]` runs the watchers for a few seconds with no window
/// and prints what they found. It is the quickest way to see whether sessions are
/// being detected, and what status, effort, and titles they carry.
///
/// After the first second it only prints when the picture changes, so a long probe
/// alongside `scripts/simulate.sh` reads as a list of transitions.
@MainActor
enum ProbeMode {
    static func run(seconds: Int = 6) async {
        let model = IslandModel(settings: AppEnvironment.shared.settings)
        model.start()
        reportScreen(model)
        print("watching \(IslandPaths.claudeSessions) and \(IslandPaths.codexSessions)")
        print("hook socket: \(IslandPaths.socketPath)")
        print("claude hooks: \(HookManager().state(for: .claude))")

        var lastReport: [String] = []
        let ticks = max(1, seconds) * 4
        for tick in 1...ticks {
            try? await Task.sleep(for: .milliseconds(250))
            let report = model.bubbles.map { bubble in
                let session = bubble.session
                let motion = session.isRetiring ? " (leaving)" : bubble.isRetracting ? " (tucked)" : ""
                let command = session.command.map { " /\($0.name)" + (session.isRunningCommand ? " spinner" : "") } ?? ""
                let waiting = model.asks[bubble.id].map { pending -> String in
                    if case .plan = pending.ask { " [plan waiting]" } else { " [question waiting]" }
                } ?? ""
                let replies = model.wakeChannels[bubble.id]?.isOpen == true ? " [takes a message]" : ""
                let state = motion + command + waiting + replies
                let place = bubble.side.map { "\($0.rawValue) \(bubble.rank)" } ?? "waiting"
                return "  \(place)  \(session.kind.rawValue)  \(session.status.rawValue)\(state)"
                    + "  effort=\(session.effortLabel)"
                    + "  repo=\(session.repo)"
                    + "  title=\(session.displayTitle)"
                    + (session.detail.map { "  detail=\($0)" } ?? "")
            }
            let header = "\(report.count) circle(s), animating: \(model.animationMode)"
            guard tick == 4 || (tick > 4 && [header] + report != lastReport) else { continue }
            lastReport = [header] + report
            print(String(format: "\n[%.2fs] ", Double(tick) / 4) + header)
            report.forEach { print($0) }
            fflush(stdout)
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
        for side in IslandSide.allCases {
            let centers = (0..<NotchGeometry.maximumPerSide).map { geometry.slotCenter(side: side, rank: $0) }
            print("  \(side.rawValue) places: " + centers.map { "(\(Int($0.x)), \(Int($0.y)))" }.joined(separator: " "))
        }
    }
}
