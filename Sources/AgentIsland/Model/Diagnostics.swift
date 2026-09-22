import Foundation

/// Counters for `--diagnose`: how often the model rebuilds and how often the island
/// re-renders. Cheap enough to leave compiled in, and off unless the flag is passed.
@MainActor
enum Diagnostics {
    static let enabled = CommandLine.arguments.contains("--diagnose")

    private static var counts: [String: Int] = [:]
    private static var lastReport = Date()

    static func count(_ what: String) {
        guard enabled else { return }
        counts[what, default: 0] += 1

        let now = Date()
        let elapsed = now.timeIntervalSince(lastReport)
        guard elapsed >= 2 else { return }
        lastReport = now

        let line = counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.1f", Double($0.value) / elapsed))/s" }
            .joined(separator: "  ")
        FileHandle.standardError.write(Data("[diag] \(line)\n".utf8))
        counts.removeAll()
    }
}
