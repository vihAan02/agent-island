import Darwin
import Foundation

/// Reads another process's argument vector with `sysctl(KERN_PROCARGS2)`.
///
/// This is how the effort level and the ultracode flag are recovered for a Claude
/// session: the desktop app launches the CLI with `--effort xhigh` and, when
/// ultracode is on, `--settings {"ultracode":true,...}`.
public enum ProcessArgs {
    public static func isAlive(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The full argument list, or nil when the process is gone or not readable.
    public static func arguments(pid: Int32) -> [String]? {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size == 0 { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 { return nil }
        guard size > MemoryLayout<CInt>.size else { return nil }

        // Layout: argc (CInt), the executable path, padding NULs, then argc C strings.
        var argc: CInt = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<MemoryLayout<CInt>.size]))
            }
        }
        guard argc > 0 else { return nil }

        let bytes = buffer.prefix(size).map { UInt8(bitPattern: $0) }
        var index = MemoryLayout<CInt>.size

        // Skip the executable path and any padding after it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        var current: [UInt8] = []
        while index < bytes.count, arguments.count < Int(argc) {
            let byte = bytes[index]
            if byte == 0 {
                arguments.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        return arguments
    }

    /// What the command line says about a Claude session.
    public struct ClaudeLaunchInfo: Sendable, Equatable {
        public var effort: EffortTier?
        public var isUltra: Bool
        public var model: String?
    }

    public static func claudeLaunchInfo(pid: Int32) -> ClaudeLaunchInfo {
        guard let arguments = arguments(pid: pid) else {
            return ClaudeLaunchInfo(effort: nil, isUltra: false, model: nil)
        }
        return parseClaudeLaunchInfo(arguments)
    }

    /// Split out so it can be tested without a live process.
    public static func parseClaudeLaunchInfo(_ arguments: [String]) -> ClaudeLaunchInfo {
        var effort: EffortTier?
        var model: String?
        var isUltra = false

        for (index, argument) in arguments.enumerated() {
            if argument == "--effort", index + 1 < arguments.count {
                effort = EffortTier.parse(arguments[index + 1])
            } else if argument.hasPrefix("--effort=") {
                effort = EffortTier.parse(String(argument.dropFirst("--effort=".count)))
            } else if argument == "--model", index + 1 < arguments.count {
                model = arguments[index + 1]
            } else if argument.hasPrefix("--model=") {
                model = String(argument.dropFirst("--model=".count))
            }

            // `--settings {"ultracode":true,...}` arrives as one JSON argument.
            if argument.contains("\"ultracode\"") {
                let compact = argument.replacingOccurrences(of: " ", with: "")
                if compact.contains("\"ultracode\":true") { isUltra = true }
            } else if argument == "--ultracode" {
                isUltra = true
            }
        }
        return ClaudeLaunchInfo(effort: effort, isUltra: isUltra, model: model)
    }

    /// Walks up the parent chain, used to find the terminal that owns a CLI session.
    public static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
