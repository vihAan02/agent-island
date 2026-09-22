import Foundation

/// Minimal reader for Electron `.asar` archives.
///
/// Layout: four little-endian UInt32 fields (pickle bookkeeping, header size,
/// payload size, JSON length), the header JSON, then the file bytes starting at
/// `8 + headerSize`. Each entry's `offset` is relative to that base.
public struct AsarReader {
    public struct Entry: Sendable {
        public var offset: UInt64
        public var size: Int
    }

    private let path: String
    private let base: UInt64
    private let header: [String: Any]

    public init?(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        guard
            let prefix = try? handle.read(upToCount: 16), prefix.count == 16
        else { return nil }

        func word(_ index: Int) -> UInt32 {
            prefix.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian
            }
        }
        let headerSize = word(1)
        let jsonLength = Int(word(3))
        guard jsonLength > 0, jsonLength < 64 * 1024 * 1024 else { return nil }

        guard
            let jsonData = try? handle.read(upToCount: jsonLength), jsonData.count == jsonLength,
            let object = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
        else { return nil }

        self.path = path
        self.base = UInt64(8 + headerSize)
        self.header = object
    }

    /// Looks up one path inside the archive, e.g. `webview/assets/pet.webp`.
    public func entry(at archivePath: String) -> Entry? {
        var node = header
        let components = archivePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            guard let files = node["files"] as? [String: Any],
                  let child = files[component] as? [String: Any] else { return nil }
            if index == components.count - 1 {
                guard let size = child["size"] as? Int else { return nil }
                let offset = UInt64((child["offset"] as? String).flatMap(UInt64.init) ?? 0)
                return Entry(offset: offset, size: size)
            }
            node = child
        }
        return nil
    }

    /// Names of the files in one directory of the archive.
    public func names(inDirectory directory: String) -> [String] {
        var node = header
        for component in directory.split(separator: "/").map(String.init) {
            guard let files = node["files"] as? [String: Any],
                  let child = files[component] as? [String: Any] else { return [] }
            node = child
        }
        return ((node["files"] as? [String: Any])?.keys).map(Array.init) ?? []
    }

    public func data(at archivePath: String) -> Data? {
        guard let entry = entry(at: archivePath), let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: base + entry.offset)
        return try? handle.read(upToCount: entry.size)
    }
}
