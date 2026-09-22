import Foundation

/// Reads repository facts straight off disk. No `git` process, so it is cheap
/// enough to call whenever a session's working directory changes.
public enum GitInfo {
    /// Walks up from `path` looking for a `.git` entry.
    public static func repositoryRoot(for path: String) -> String? {
        var directory = (path as NSString).standardizingPath
        let manager = FileManager.default
        var depth = 0

        while depth < 24, directory != "/", !directory.isEmpty {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            if manager.fileExists(atPath: dotGit) { return directory }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { break }
            directory = parent
            depth += 1
        }
        return nil
    }

    /// Current branch, or a short SHA when the repository is on a detached head.
    public static func branch(for path: String) -> String? {
        guard let root = repositoryRoot(for: path) else { return nil }
        let dotGit = (root as NSString).appendingPathComponent(".git")

        var headPath = (dotGit as NSString).appendingPathComponent("HEAD")
        // Worktrees and submodules put a `gitdir:` pointer in a plain `.git` file.
        if let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
           pointer.hasPrefix("gitdir:") {
            let target = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = target.hasPrefix("/")
                ? target
                : (root as NSString).appendingPathComponent(target)
            headPath = (resolved as NSString).appendingPathComponent("HEAD")
        }

        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref: refs/heads/") {
            return String(text.dropFirst("ref: refs/heads/".count))
        }
        return text.isEmpty ? nil : String(text.prefix(7))
    }
}
