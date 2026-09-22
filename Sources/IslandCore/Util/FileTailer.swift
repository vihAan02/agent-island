import Foundation

/// Follows append-only JSONL files (Claude transcripts, Codex rollouts).
///
/// Remembers a byte offset per file, hands back whole lines only, and keeps any
/// half-written trailing line until the rest of it lands.
public struct FileTailer: Sendable {
    /// How much of an already-large file to read the first time it is seen.
    public var initialTailBytes: Int = 256 * 1024

    private var offsets: [String: UInt64] = [:]
    private var partials: [String: Data] = [:]

    public init() {}

    public func hasSeen(_ path: String) -> Bool { offsets[path] != nil }

    /// Resets a file, for example when it was truncated or replaced.
    public mutating func forget(_ path: String) {
        offsets.removeValue(forKey: path)
        partials.removeValue(forKey: path)
    }

    /// Returns whole lines appended since the last call.
    ///
    /// - Parameter readFromStart: for a file seen for the first time, read all of it
    ///   (capped by `initialTailBytes`) instead of only what arrives from now on.
    public mutating func newLines(at path: String, readFromStart: Bool) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            forget(path)
            return []
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var offset = offsets[path] ?? {
            guard readFromStart else { return size }
            return size > UInt64(initialTailBytes) ? size - UInt64(initialTailBytes) : 0
        }()

        // The file was replaced or truncated.
        if offset > size {
            offset = 0
            partials[path] = nil
        }
        guard offset < size else {
            offsets[path] = offset
            return []
        }

        try? handle.seek(toOffset: offset)
        let chunk = (try? handle.read(upToCount: Int(size - offset))) ?? Data()
        offsets[path] = size

        var buffer = partials[path] ?? Data()
        buffer.append(chunk)

        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        partials[path] = start < buffer.endIndex ? Data(buffer[start...]) : Data()
        // A first read that starts mid-file can begin inside a line. That fragment is
        // not valid JSON, and every parser here skips lines it cannot decode.
        return lines
    }
}
