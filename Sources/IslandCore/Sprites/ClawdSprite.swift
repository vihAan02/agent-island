import Foundation

/// Claude's mascot, rebuilt from the quadrant-block shapes the CLI draws it with.
///
/// Each character cell is two sub-pixels wide and two tall, and a terminal cell is
/// about twice as tall as it is wide, so a sub-pixel is drawn half a unit wide and
/// one unit tall. The result is an 18 x 6 grid of sub-pixels.
public enum ClawdPose: String, Sendable, CaseIterable {
    case standing
    case lookLeft
    case lookRight
    case armsUp
}

public struct ClawdFrame: Sendable, Equatable {
    /// Sub-pixel columns (18) and rows (6).
    public let width: Int
    public let height: Int
    /// Row-major, true where the body is drawn. The gaps are Clawd's eyes.
    public let pixels: [Bool]

    public func isSet(x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return pixels[y * width + x]
    }
}

public enum ClawdSprite {
    /// Body rows, exactly as the CLI composes them: two shoulder segments around a
    /// middle run, then the torso, then the feet.
    private static let poseRows: [ClawdPose: [String]] = [
        .standing: [" \u{2590}\u{259B}\u{2588}\u{2588}\u{2588}\u{259B}\u{2588}",
                    "\u{259D}\u{259C}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2580}",
                    " \u{2597}   \u{2596} "],
        .lookLeft: [" \u{2590}\u{259F}\u{2588}\u{2588}\u{2588}\u{259F}\u{2588}",
                    "\u{259D}\u{259C}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2580}",
                    " \u{2598}   \u{2598} "],
        .lookRight: [" \u{2590}\u{2588}\u{259F}\u{2588}\u{2588}\u{2588}\u{259F}",
                     "\u{259D}\u{259C}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2580}",
                     " \u{259D}   \u{259D} "],
        .armsUp: ["\u{2597}\u{259F}\u{259B}\u{2588}\u{2588}\u{2588}\u{259B}\u{2588}\u{2584}",
                  " \u{259C}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2598}",
                  " \u{2597}   \u{2596} "],
    ]

    /// Quadrant coverage for each block character: upper-left, upper-right,
    /// lower-left, lower-right.
    private static let quadrants: [Character: (Bool, Bool, Bool, Bool)] = [
        " ": (false, false, false, false),
        "\u{2598}": (true, false, false, false),   // ▘
        "\u{259D}": (false, true, false, false),   // ▝
        "\u{2596}": (false, false, true, false),   // ▖
        "\u{2597}": (false, false, false, true),   // ▗
        "\u{2580}": (true, true, false, false),    // ▀
        "\u{2584}": (false, false, true, true),    // ▄
        "\u{258C}": (true, false, true, false),    // ▌
        "\u{2590}": (false, true, false, true),    // ▐
        "\u{259A}": (true, false, false, true),    // ▚
        "\u{259E}": (false, true, true, false),    // ▞
        "\u{259B}": (true, true, true, false),     // ▛
        "\u{259C}": (true, true, false, true),     // ▜
        "\u{2599}": (true, false, true, true),     // ▙
        "\u{259F}": (false, true, true, true),     // ▟
        "\u{2588}": (true, true, true, true),      // █
    ]

    public static let frameWidth = 18
    public static let frameHeight = 6

    private static let cache: [ClawdPose: ClawdFrame] = {
        var built: [ClawdPose: ClawdFrame] = [:]
        for pose in ClawdPose.allCases {
            built[pose] = decode(rows: poseRows[pose] ?? [])
        }
        return built
    }()

    public static func frame(_ pose: ClawdPose) -> ClawdFrame {
        cache[pose] ?? ClawdFrame(width: frameWidth, height: frameHeight, pixels: Array(repeating: false, count: frameWidth * frameHeight))
    }

    /// Expands rows of block characters into the sub-pixel grid.
    public static func decode(rows: [String]) -> ClawdFrame {
        var pixels = [Bool](repeating: false, count: frameWidth * frameHeight)

        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, character) in row.enumerated() {
                guard let mask = quadrants[character] else { continue }
                let x = columnIndex * 2
                let y = rowIndex * 2
                func set(_ dx: Int, _ dy: Int, _ on: Bool) {
                    guard on, x + dx < frameWidth, y + dy < frameHeight else { return }
                    pixels[(y + dy) * frameWidth + (x + dx)] = true
                }
                set(0, 0, mask.0)
                set(1, 0, mask.1)
                set(0, 1, mask.2)
                set(1, 1, mask.3)
            }
        }
        return ClawdFrame(width: frameWidth, height: frameHeight, pixels: pixels)
    }
}

/// How Clawd moves for each status: a pose loop plus a little procedural motion.
public struct ClawdAnimation: Sendable, Equatable {
    public enum Motion: Sendable, Equatable {
        case none
        /// Small vertical bob, in sub-pixel units.
        case bob(amplitude: Double, period: Double)
        case shake(amplitude: Double, period: Double)
        case hop(height: Double, period: Double)
    }

    public var poses: [ClawdPose]
    public var frameDuration: Double
    public var motion: Motion

    public func pose(at time: Double) -> ClawdPose {
        guard !poses.isEmpty else { return .standing }
        let index = Int((time / frameDuration).rounded(.down)) % poses.count
        return poses[index < 0 ? 0 : index]
    }

    public static func animation(for status: AgentStatus, secondsInStatus: Double) -> ClawdAnimation {
        switch status {
        case .working:
            // Head flicks left and right like it is reading, with a typing bob.
            ClawdAnimation(
                poses: [.lookLeft, .standing, .lookRight, .standing],
                frameDuration: 0.34,
                motion: .bob(amplitude: 0.5, period: 0.68)
            )
        case .question:
            ClawdAnimation(poses: [.armsUp, .standing], frameDuration: 0.42, motion: .bob(amplitude: 0.35, period: 0.84))
        case .plan:
            ClawdAnimation(
                poses: [.lookLeft, .lookLeft, .standing, .lookRight, .lookRight, .standing],
                frameDuration: 0.5,
                motion: .none
            )
        case .error:
            ClawdAnimation(poses: [.standing], frameDuration: 1, motion: .shake(amplitude: 0.6, period: 0.16))
        case .complete:
            secondsInStatus < 1.4
                ? ClawdAnimation(poses: [.armsUp], frameDuration: 1, motion: .hop(height: 1.6, period: 0.46))
                : ClawdAnimation(poses: [.standing], frameDuration: 1, motion: .bob(amplitude: 0.25, period: 2.4))
        case .idle, .waiting:
            ClawdAnimation(poses: [.standing], frameDuration: 1, motion: .bob(amplitude: 0.25, period: 2.4))
        }
    }
}
