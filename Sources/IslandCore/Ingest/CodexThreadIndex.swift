import Foundation
import SQLite3

/// Read-only lookups into Codex's local thread database, for chat titles and branches.
///
/// Falls back to `session_index.jsonl` when the database is missing or its schema moved.
public struct CodexThreadIndex: Sendable {
    public struct Row: Sendable, Equatable {
        public var title: String?
        public var cwd: String?
        public var branch: String?
        public var effort: EffortTier?
    }

    private let databasePath: String?
    private let indexPath: String

    public init(codexDirectory: String = IslandPaths.codexDirectory) {
        self.databasePath = Self.newestStateDatabase(in: codexDirectory)
        self.indexPath = (codexDirectory as NSString).appendingPathComponent("session_index.jsonl")
    }

    /// `state_5.sqlite`, `state_6.sqlite`, and so on: take the most recently written one.
    private static func newestStateDatabase(in directory: String) -> String? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return nil }
        let candidates = names.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        let paths = candidates.map { (directory as NSString).appendingPathComponent($0) }
        return paths.max { left, right in
            let leftDate = (try? manager.attributesOfItem(atPath: left)[.modificationDate] as? Date) ?? nil
            let rightDate = (try? manager.attributesOfItem(atPath: right)[.modificationDate] as? Date) ?? nil
            return (leftDate ?? .distantPast) < (rightDate ?? .distantPast)
        }
    }

    public func row(threadID: String) -> Row? {
        if let row = sqliteRow(threadID: threadID) { return row }
        if let title = indexTitle(threadID: threadID) { return Row(title: title, cwd: nil, branch: nil, effort: nil) }
        return nil
    }

    private func sqliteRow(threadID: String) -> Row? {
        guard let databasePath else { return nil }

        var handle: OpaquePointer?
        let uri = "file:\(databasePath)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)

        let sql = """
            SELECT COALESCE(NULLIF(name, ''), NULLIF(title, ''), NULLIF(first_user_message, '')),
                   cwd, git_branch, reasoning_effort
            FROM threads WHERE id = ? LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, threadID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        func text(_ column: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, column) else { return nil }
            let value = String(cString: raw)
            return value.isEmpty ? nil : value
        }

        return Row(
            title: text(0).map { String($0.prefix(60)) },
            cwd: text(1),
            branch: text(2),
            effort: EffortTier.parse(text(3))
        )
    }

    private func indexTitle(threadID: String) -> String? {
        guard let contents = try? String(contentsOfFile: indexPath, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n").reversed() {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["id"] as? String == threadID
            else { continue }
            return object["thread_name"] as? String
        }
        return nil
    }
}
