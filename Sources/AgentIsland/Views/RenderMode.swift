import AppKit
import IslandCore
import SwiftUI

/// `AgentIsland --render <directory>` draws the island offscreen into PNGs.
///
/// Used to check the emerge animation, every status, and every effort tier without
/// having to catch them live on screen.
@MainActor
enum RenderMode {
    /// A stand-in desktop behind the island, so black-on-black is still readable.
    private static let backdrop = Color(red: 0.16, green: 0.17, blue: 0.20)

    static func run(outputDirectory: String) {
        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        write(emergeSheet(), to: directory.appendingPathComponent("emerge.png"))
        write(statusSheet(), to: directory.appendingPathComponent("statuses.png"))
        write(effortSheet(), to: directory.appendingPathComponent("efforts.png"))
        write(cardSheet(), to: directory.appendingPathComponent("card.png"))
        write(mascotSheet(), to: directory.appendingPathComponent("mascots.png"))
    }

    // MARK: - Sheets

    /// The first circle pulling out of the notch, frame by frame.
    private static func emergeSheet() -> some View {
        let geometry = sampleGeometry()
        let session = sampleSession(kind: .claude, status: .working, effort: .xhigh, ultra: true)
        let times: [Double] = [0, 0.06, 0.12, 0.18, 0.26, 0.4, 0.7]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(times, id: \.self) { time in
                labeled("t = \(String(format: "%.2f", time))s") {
                    band(geometry: geometry) {
                        [
                            layout(session: session, slot: 0, geometry: geometry, progress: Spring.value(time: time)),
                        ]
                    }
                }
            }
        }
        .background(backdrop)
    }

    /// Every ring state, for both agents.
    private static func statusSheet() -> some View {
        let geometry = sampleGeometry()
        let statuses: [AgentStatus] = [.working, .question, .plan, .error, .complete, .idle]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(statuses, id: \.self) { status in
                labeled(status.rawValue) {
                    band(geometry: geometry) {
                        [
                            layout(
                                session: sampleSession(kind: .claude, status: status, effort: .high),
                                slot: 0, geometry: geometry, progress: 1
                            ),
                            layout(
                                session: sampleSession(kind: .codex, status: status, effort: .high),
                                slot: 1, geometry: geometry, progress: 1
                            ),
                        ]
                    }
                }
            }
        }
        .background(backdrop)
    }

    /// Every effort tier, Claude on the right of the notch, Codex on the left.
    private static func effortSheet() -> some View {
        let geometry = sampleGeometry()
        let tiers: [EffortTier] = [.low, .medium, .high, .xhigh, .max, .ultra]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(tiers, id: \.self) { tier in
                labeled(tier == .ultra ? "ultra / ultracode" : tier.label) {
                    band(geometry: geometry) {
                        [
                            layout(
                                session: sampleSession(
                                    kind: .claude, status: .working, effort: tier, ultra: tier == .ultra
                                ),
                                slot: 0, geometry: geometry, progress: 1
                            ),
                            layout(
                                session: sampleSession(
                                    kind: .codex, status: .working, effort: tier, ultra: tier == .ultra
                                ),
                                slot: 1, geometry: geometry, progress: 1
                            ),
                        ]
                    }
                }
            }
        }
        .background(backdrop)
    }

    /// A full island with four circles and the hover card open.
    private static func cardSheet() -> some View {
        let geometry = sampleGeometry()
        let sessions = [
            sampleSession(kind: .claude, status: .question, effort: .xhigh, ultra: true,
                          title: "Refactor the liquid layer", detail: "Needs approval: Bash(swift test)"),
            sampleSession(kind: .codex, status: .working, effort: .ultra,
                          title: "Choose F1 prediction model"),
            sampleSession(kind: .claude, status: .plan, effort: .low, title: "Fix flaky test"),
            sampleSession(kind: .codex, status: .complete, effort: .high, title: "Review notebook"),
        ]
        let layouts = sessions.enumerated().map { index, session in
            layout(session: session, slot: index, geometry: geometry, progress: 1)
        }

        return VStack(alignment: .leading, spacing: 0) {
            labeled("four sessions, card open") {
                IslandContent(
                    geometry: geometry,
                    layouts: layouts,
                    clock: 1.1,
                    petID: PetCatalog.preferredPetID(),
                    hoveredID: layouts.first?.id,
                    expandedID: layouts.first?.id
                )
                .frame(height: 130, alignment: .top)
                .clipped()
            }
        }
        .background(backdrop)
    }

    /// Both mascots, drawn large, in every status. This is the sheet to look at when
    /// tuning the sprites themselves.
    private static func mascotSheet() -> some View {
        let statuses: [AgentStatus] = [.working, .question, .plan, .error, .complete, .idle]
        let size: CGFloat = 120

        return VStack(alignment: .leading, spacing: 10) {
            ForEach([0.0, 0.35, 0.7], id: \.self) { clock in
                HStack(spacing: 14) {
                    ForEach(statuses, id: \.self) { status in
                        VStack(spacing: 4) {
                            ZStack {
                                Circle().fill(.black)
                                ClawdView(
                                    status: status,
                                    color: IslandStyle.claude,
                                    clock: clock,
                                    secondsInStatus: 0.9
                                )
                                .frame(width: size * 0.66)
                            }
                            .frame(width: size, height: size)

                            ZStack {
                                Circle().fill(.black)
                                CodexPetView(
                                    petID: PetCatalog.preferredPetID(),
                                    status: status,
                                    clock: clock,
                                    secondsInStatus: 0.9,
                                    fallbackColor: IslandStyle.codex
                                )
                                .frame(width: size * 0.8, height: size * 0.8)
                            }
                            .frame(width: size, height: size)

                            Text(status.rawValue)
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(backdrop)
    }

    // MARK: - Pieces

    private static func band(
        geometry: NotchGeometry,
        layouts: () -> [BubbleLayout]
    ) -> some View {
        IslandContent(
            geometry: geometry,
            layouts: layouts(),
            clock: 1.1,
            petID: PetCatalog.preferredPetID(),
            hoveredID: nil,
            expandedID: nil
        )
        .frame(height: 56, alignment: .top)
        .clipped()
    }

    private static func labeled(_ text: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 10)
            content()
        }
        .padding(.vertical, 5)
    }

    private static func sampleGeometry() -> NotchGeometry {
        // A 14-inch MacBook Pro: 1512pt wide, a 186pt notch, and the island window
        // hugging it with room for four circles a side.
        let extent: CGFloat = 12 + 4 * (28 + 8) + 16
        return NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            panelFrame: CGRect(x: 663 - extent, y: 0, width: 186 + extent * 2, height: NotchGeometry.panelHeight),
            notchRect: CGRect(x: extent, y: 0, width: 186, height: 32),
            hasRealNotch: true
        )
    }

    private static func sampleSession(
        kind: AgentKind,
        status: AgentStatus,
        effort: EffortTier,
        ultra: Bool = false,
        title: String = "Sample session",
        detail: String? = nil
    ) -> AgentSession {
        var session = AgentSession(
            id: "\(kind.rawValue)-\(status.rawValue)-\(effort.rawValue)-\(ultra)",
            kind: kind,
            host: kind == .claude ? .claudeDesktop : .codexDesktop,
            title: title,
            effort: effort,
            isUltra: ultra
        )
        session.status = status
        session.repo = "agent-island"
        session.branch = "main"
        session.detail = detail
        // Push the status change back a little so one-shot animations are past their flash.
        session.statusChangedAt = Date().addingTimeInterval(-0.9)
        return session
    }

    private static func layout(
        session: AgentSession,
        slot: Int,
        geometry: NotchGeometry,
        progress: Double
    ) -> BubbleLayout {
        let start = geometry.slotOrigin(index: slot)
        let end = geometry.slotCenter(index: slot)
        return BubbleLayout(
            id: session.id,
            session: session,
            slot: slot,
            center: CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            ),
            diameter: geometry.circleDiameter,
            progress: progress,
            isOnRightSide: geometry.isOnRightSide(index: slot)
        )
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard
            let image = renderer.cgImage,
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else {
            NSLog("Agent Island: could not render \(url.lastPathComponent)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(url.path)")
    }
}
