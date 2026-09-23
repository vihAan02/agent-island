import Foundation

/// Lines added and removed in a working tree, against its last commit.
public struct DiffStat: Equatable, Sendable {
    public var added: Int
    public var removed: Int
    public var files: Int

    public init(added: Int = 0, removed: Int = 0, files: Int = 0) {
        self.added = added
        self.removed = removed
        self.files = files
    }

    public var isEmpty: Bool { files == 0 }
}

/// The quick `+x −y` for a session's folder: uncommitted changes to tracked files,
/// plus the lines in new files that are not ignored.
///
/// This runs git, so it blocks; call it off the main thread.
public enum GitDiffStat {
    /// Git's empty tree, for a repository with no commits yet.
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Nil when the folder is not in a git repository, or git is not available.
    public static func compute(in directory: String, timeout: TimeInterval = 2) -> DiffStat? {
        guard !directory.isEmpty, let git = gitExecutable else { return nil }

        var stat: DiffStat
        if let output = run(git, ["diff", "HEAD", "--numstat", "--no-ext-diff", "--no-textconv"], in: directory, timeout: timeout) {
            stat = parse(numstat: output)
        } else if let output = run(git, ["diff", emptyTree, "--numstat", "--no-ext-diff", "--no-textconv"], in: directory, timeout: timeout) {
            stat = parse(numstat: output)
        } else {
            return nil
        }

        if let output = run(git, ["ls-files", "--others", "--exclude-standard", "-z"], in: directory, timeout: timeout) {
            let untracked = output.split(separator: "\0").map(String.init)
            stat.files += untracked.count
            stat.added += untracked.prefix(300).reduce(0) { total, path in
                total + lineCount(ofFileAt: (directory as NSString).appendingPathComponent(path))
            }
        }
        return stat
    }

    /// Sums `git diff --numstat` output: `added<TAB>removed<TAB>path` per file, with
    /// `-` for both counts on binary files.
    public static func parse(numstat: String) -> DiffStat {
        var stat = DiffStat()
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            stat.files += 1
            stat.added += Int(fields[0]) ?? 0
            stat.removed += Int(fields[1]) ?? 0
        }
        return stat
    }

    /// Lines in a new text file. Binary and very large files count as none.
    public static func lineCount(ofFileAt path: String) -> Int {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            (attributes[.size] as? Int ?? 0) <= 512 * 1024,
            let data = FileManager.default.contents(atPath: path),
            !data.isEmpty,
            !data.prefix(8000).contains(0)
        else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
        return data.last == UInt8(ascii: "\n") ? newlines : newlines + 1
    }

    // MARK: - Running git

    /// A real git binary. `/usr/bin/git` is only a shim, and without developer tools
    /// installed it pops up an installer dialog, so it is used only when they are.
    private static let gitExecutable: String? = {
        let manager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        if let found = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) { return found }
        let developerTools = ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app"]
        return developerTools.contains { manager.fileExists(atPath: $0) } ? "/usr/bin/git" : nil
    }()

    /// Runs git and returns what it printed, or nil if it failed or ran too long.
    ///
    /// Nothing a repository configures gets to run: no fsmonitor hook, no external
    /// diff or textconv drivers. And `GIT_OPTIONAL_LOCKS=0` keeps git from taking the
    /// index lock, so it never gets in the way of an agent committing.
    private static func run(_ git: String, _ arguments: [String], in directory: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", directory, "-c", "core.fsmonitor=false", "-c", "core.quotepath=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
