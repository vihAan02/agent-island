import Foundation

/// Thin FSEvents wrapper: calls back whenever anything under `paths` changes.
///
/// The callback is coalesced by FSEvents itself (`latency`), and each watcher also
/// runs a slow poll so a missed event never leaves the island stale.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var pollTimer: DispatchSourceTimer?

    public init(
        paths: [String],
        latency: TimeInterval = 0.08,
        pollInterval: TimeInterval = 2.0,
        queue: DispatchQueue = DispatchQueue(label: "island.fswatch", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.onChange = onChange

        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        if !existing.isEmpty {
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = UInt32(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
            stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                    watcher.onChange()
                },
                &context,
                existing as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
            if let stream {
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
            }
        }

        if pollInterval > 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [onChange] in onChange() }
            timer.resume()
            pollTimer = timer
        }
    }

    deinit {
        pollTimer?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Standard locations, in one place.
public enum IslandPaths {
    public static var home: String { NSHomeDirectory() }

    public static var claudeDirectory: String { (home as NSString).appendingPathComponent(".claude") }
    public static var claudeSessions: String { (claudeDirectory as NSString).appendingPathComponent("sessions") }
    public static var claudeProjects: String { (claudeDirectory as NSString).appendingPathComponent("projects") }
    public static var claudeSettings: String { (claudeDirectory as NSString).appendingPathComponent("settings.json") }

    public static var codexDirectory: String {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return override
        }
        return (home as NSString).appendingPathComponent(".codex")
    }
    public static var codexSessions: String { (codexDirectory as NSString).appendingPathComponent("sessions") }
    public static var codexHooks: String {
        (codexDirectory as NSString).appendingPathComponent("hooks/hooks.json")
    }
    public static var codexPets: String { (codexDirectory as NSString).appendingPathComponent("pets") }

    public static var supportDirectory: String {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
            ?? (home as NSString).appendingPathComponent("Library/Application Support")
        return (base as NSString).appendingPathComponent("AgentIsland")
    }

    public static var socketPath: String {
        (supportDirectory as NSString).appendingPathComponent("island.sock")
    }

    public static var cacheDirectory: String {
        let base = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? (home as NSString).appendingPathComponent("Library/Caches")
        return (base as NSString).appendingPathComponent("AgentIsland")
    }

    public static var chatGPTApp: String { "/Applications/ChatGPT.app" }
    public static var chatGPTAsar: String { (chatGPTApp as NSString).appendingPathComponent("Contents/Resources/app.asar") }

    public static func ensureDirectory(_ path: String) {
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
