import IslandCore
import SwiftUI

/// The hover card: the circle grows into a panel hanging just under the menu bar.
struct ExpandedCard: View {
    let session: AgentSession
    let clock: Double

    static let size = CGSize(width: 268, height: 74)

    var body: some View {
        let accent = IslandStyle.ring(for: session)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(IslandStyle.brand(session.kind))
                    .frame(width: 6, height: 6)
                Text(session.repo.isEmpty ? session.kind.rawValue.capitalized : session.repo)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                if let branch = session.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(session.effortLabel)
                    .font(.system(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(accent.opacity(0.16), in: Capsule())
            }

            Text(session.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            HStack(spacing: 5) {
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(elapsed)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.black.opacity(0.001)) // keeps the whole card clickable
        .contentShape(Rectangle())
    }

    private var statusText: String {
        if let detail = session.detail, !detail.isEmpty { return detail }
        switch session.status {
        case .working: return "Working\u{2026}"
        case .question: return "Waiting for you"
        case .plan: return session.planMode ? "Planning" : "Plan ready for review"
        case .error: return "Something failed"
        case .complete: return "Done"
        case .idle: return "Idle"
        case .waiting: return "Ready"
        }
    }

    private var elapsed: String {
        let seconds = Int(max(0, Date().timeIntervalSince(session.statusChangedAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
