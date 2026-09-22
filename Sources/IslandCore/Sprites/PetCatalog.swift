import Foundation

/// The v2 pet sprite sheet contract: an 8 x 11 grid of 192 x 208 cells.
public struct PetAtlasLayout: Sendable, Equatable {
    public var columns = 8
    public var rows = 11
    public var cellWidth = 192
    public var cellHeight = 208
    public init() {}
}

/// One animation row: which row, which columns, and how long each frame holds.
public struct PetAnimation: Sendable, Equatable {
    public var row: Int
    public var durations: [Double]

    public var frameCount: Int { durations.count }
    public var totalDuration: Double { durations.reduce(0, +) }

    /// The column to draw at `time` seconds into the loop.
    public func frame(at time: Double) -> Int {
        guard totalDuration > 0 else { return 0 }
        var remaining = time.truncatingRemainder(dividingBy: totalDuration)
        for (index, duration) in durations.enumerated() {
            if remaining < duration { return index }
            remaining -= duration
        }
        return durations.count - 1
    }
}

/// Rows and frame timings come from the pet contract shipped with the Codex app
/// (`hatch-pet/references/animation-rows.md`).
public enum PetAnimations {
    public static let idle = PetAnimation(row: 0, durations: [0.28, 0.11, 0.11, 0.14, 0.14, 0.32])
    public static let runningRight = PetAnimation(row: 1, durations: Array(repeating: 0.12, count: 7) + [0.22])
    public static let runningLeft = PetAnimation(row: 2, durations: Array(repeating: 0.12, count: 7) + [0.22])
    public static let waving = PetAnimation(row: 3, durations: [0.14, 0.14, 0.14, 0.28])
    public static let jumping = PetAnimation(row: 4, durations: [0.14, 0.14, 0.14, 0.14, 0.28])
    public static let failed = PetAnimation(row: 5, durations: Array(repeating: 0.14, count: 7) + [0.24])
    public static let waiting = PetAnimation(row: 6, durations: Array(repeating: 0.15, count: 5) + [0.26])
    public static let working = PetAnimation(row: 7, durations: Array(repeating: 0.12, count: 5) + [0.22])
    public static let review = PetAnimation(row: 8, durations: Array(repeating: 0.15, count: 5) + [0.28])

    public static func animation(for status: AgentStatus, secondsInStatus: Double) -> PetAnimation {
        switch status {
        case .working: working
        case .question: waiting
        case .plan: review
        case .error: failed
        // A short celebration, then the pet settles down.
        case .complete: secondsInStatus < 1.4 ? jumping : idle
        case .idle, .waiting: idle
        }
    }
}

/// Finds pet sprite sheets: the built-in ones inside the Codex app, and any custom
/// pet the user hatched into `~/.codex/pets`.
///
/// The art is never copied into this repo. It is read out of the installed app at
/// runtime and cached under `~/Library/Caches/AgentIsland`.
public struct PetCatalog: Sendable {
    /// Results of the archive lookups, which are the expensive part: parsing the
    /// Codex app's index costs megabytes of JSON, and the answers never change while
    /// the app runs.
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var petIDs: [String: [String]] = [:]
        private var imagePaths: [String: String] = [:]

        func petIDs(forArchive path: String, compute: () -> [String]) -> [String] {
            lock.lock()
            if let cached = petIDs[path] { lock.unlock(); return cached }
            lock.unlock()

            let value = compute()
            lock.lock()
            petIDs[path] = value
            lock.unlock()
            return value
        }

        func imagePath(key: String, compute: () -> String?) -> String? {
            lock.lock()
            if let cached = imagePaths[key] { lock.unlock(); return cached }
            lock.unlock()

            let value = compute()
            lock.lock()
            if let value { imagePaths[key] = value }
            lock.unlock()
            return value
        }
    }

    public struct Pet: Sendable, Equatable {
        public var id: String
        public var displayName: String
        /// A file on disk the app can decode. Extracted on demand.
        public var imagePath: String
    }

    private let asarPath: String
    private let petsDirectory: String
    private let cacheDirectory: String

    public init(
        asarPath: String = IslandPaths.chatGPTAsar,
        petsDirectory: String = IslandPaths.codexPets,
        cacheDirectory: String = IslandPaths.cacheDirectory
    ) {
        self.asarPath = asarPath
        self.petsDirectory = petsDirectory
        self.cacheDirectory = cacheDirectory
    }

    /// Custom pets first, then the pets bundled with the Codex app.
    public func availablePets() -> [Pet] {
        customPets() + builtInPetIDs().map {
            Pet(id: $0, displayName: $0.capitalized, imagePath: "")
        }
    }

    public func builtInPetIDs() -> [String] {
        Cache.shared.petIDs(forArchive: asarPath) { uncachedBuiltInPetIDs() }
    }

    private func uncachedBuiltInPetIDs() -> [String] {
        guard let reader = AsarReader(path: asarPath) else { return [] }
        return reader.names(inDirectory: "webview/assets")
            .compactMap { name -> String? in
                guard name.hasSuffix(".webp"), let range = name.range(of: "-spritesheet-v") else { return nil }
                return String(name[name.startIndex..<range.lowerBound])
            }
            .sorted()
    }

    public func customPets() -> [Pet] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: petsDirectory) else { return [] }
        return names.compactMap { name in
            let directory = (petsDirectory as NSString).appendingPathComponent(name)
            let manifestPath = (directory as NSString).appendingPathComponent("pet.json")
            guard
                let data = manager.contents(atPath: manifestPath),
                let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            let sheet = (manifest["spritesheetPath"] as? String) ?? "spritesheet.webp"
            let imagePath = (directory as NSString).appendingPathComponent(sheet)
            guard manager.fileExists(atPath: imagePath) else { return nil }
            return Pet(
                id: (manifest["id"] as? String) ?? name,
                displayName: (manifest["displayName"] as? String) ?? name,
                imagePath: imagePath
            )
        }
    }

    /// Returns a decodable file for `petID`, extracting it from the app archive once.
    public func imagePath(for petID: String) -> String? {
        if let custom = customPets().first(where: { $0.id == petID }) { return custom.imagePath }
        return Cache.shared.imagePath(key: "\(asarPath)#\(petID)") { extractBuiltIn(petID: petID) }
    }

    private func extractBuiltIn(petID: String) -> String? {
        guard let reader = AsarReader(path: asarPath) else { return nil }

        let assets = reader.names(inDirectory: "webview/assets")
        guard let name = assets.first(where: {
            $0.hasPrefix("\(petID)-spritesheet-v") && $0.hasSuffix(".webp")
        }) else { return nil }

        IslandPaths.ensureDirectory(cacheDirectory)
        let cached = (cacheDirectory as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: cached) { return cached }

        guard let data = reader.data(at: "webview/assets/\(name)") else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: cached), options: .atomic)
            return cached
        } catch {
            return nil
        }
    }

    /// The pet the user picked in the Codex app, when that can be read.
    public static func preferredPetID(codexDirectory: String = IslandPaths.codexDirectory) -> String {
        let statePath = (codexDirectory as NSString).appendingPathComponent(".codex-global-state.json")
        guard
            let data = FileManager.default.contents(atPath: statePath),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let persisted = root["electron-persisted-atom-state"] as? [String: Any]
        else { return "codex" }

        for key in ["selected-pet-avatar-id", "pet-avatar-id", "first-awake-pet-notification-avatar-ids"] {
            if let value = persisted[key] as? String, !value.isEmpty { return value }
            if let values = persisted[key] as? [String], let first = values.first, !first.isEmpty { return first }
        }
        return "codex"
    }
}
