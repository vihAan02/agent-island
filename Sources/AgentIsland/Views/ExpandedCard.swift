import IslandCore
import SwiftUI

/// What a card reports about the working tree.
enum DiffState: Equatable {
    case loading
    /// The session's folder is not in a git repository.
    case unavailable
    case ready(DiffStat)
}

/// The card a circle pours into when clicked: what the agent is doing right now,
/// how much it has changed, and the mode it is in. Clicking the card opens the chat.
struct ExpandedCard: View {
    let session: AgentSession
    let diff: DiffState
    var now: Date = Date()

    nonisolated static let size = CGSize(width: 300, height: 102)

    var body: some View {
        let accent = IslandStyle.ring(for: session)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(IslandStyle.brand(session.kind))
                    .frame(width: 6, height: 6)
                Text(session.repo.isEmpty ? session.kind.rawValue.capitalized : session.repo)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let branch = session.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Chip(text: session.effortLabel, color: accent, monospaced: true)
            }

            Text(session.displayTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)

            HStack(spacing: 5) {
                Image(systemName: activitySymbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(session.statusLine)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(accent)

            HStack(spacing: 8) {
                DiffLine(diff: diff)
                if let mode = session.modeLabel {
                    Chip(text: mode, color: .white.opacity(0.75), monospaced: false)
                }
                Spacer(minLength: 4)
                Text(session.elapsedText(now: now))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                HStack(spacing: 2) {
                    Text("Open")
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private var activitySymbol: String {
        if session.isRunningCommand {
            return session.command?.name == SlashCommand.compact ? "arrow.down.right.and.arrow.up.left" : "slash.circle"
        }
        return switch session.status {
        case .question: "questionmark.circle.fill"
        case .plan: "list.bullet.clipboard"
        case .error: "exclamationmark.triangle.fill"
        case .complete: "checkmark.circle.fill"
        case .working, .idle, .waiting: "bolt.fill"
        }
    }
}

/// `+128 −14  3 files`, in the colors a diff uses.
private struct DiffLine: View {
    let diff: DiffState

    var body: some View {
        HStack(spacing: 4) {
            switch diff {
            case .loading:
                Text("\u{2026}").foregroundStyle(.white.opacity(0.45))
            case .unavailable:
                Text("No repo").foregroundStyle(.white.opacity(0.45))
            case .ready(let stat) where stat.isEmpty:
                Text("No changes").foregroundStyle(.white.opacity(0.45))
            case .ready(let stat):
                Text("+\(Self.compact(stat.added))").foregroundStyle(IslandStyle.complete)
                Text("\u{2212}\(Self.compact(stat.removed))").foregroundStyle(IslandStyle.error)
                Text("\(stat.files) file\(stat.files == 1 ? "" : "s")").foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
    }

    /// 1234 reads as 1.2k.
    static func compact(_ value: Int) -> String {
        value < 1000 ? "\(value)" : String(format: "%.1fk", Double(value) / 1000)
    }
}

private struct Chip: View {
    let text: String
    let color: Color
    let monospaced: Bool

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 9, weight: .medium).monospaced() : .system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: Capsule())
            .lineLimit(1)
    }
}
