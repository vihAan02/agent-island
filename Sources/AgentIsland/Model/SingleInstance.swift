import Darwin
import Foundation
import IslandCore

/// Keeps a single copy of the app running.
///
/// Two copies would fight over the hook socket, and the island would show every
/// circle twice. The lock is held for the lifetime of the process and released by
/// the kernel when it exits.
enum SingleInstance {
    private nonisolated(unsafe) static var lockDescriptor: Int32 = -1

    static func acquire() -> Bool {
        IslandPaths.ensureDirectory(IslandPaths.supportDirectory)
        let path = (IslandPaths.supportDirectory as NSString).appendingPathComponent("instance.lock")

        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return true } // Cannot lock: let the app run anyway.

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }
}
