import Darwin
import Foundation

/// Listens on a Unix socket for payloads forwarded by `agent-island-hook`.
///
/// One connection carries one hook payload and is closed immediately, so the agent
/// never waits on this app.
public final class HookSocketServer: @unchecked Sendable {
    public enum StartError: Error, CustomStringConvertible {
        case socketFailed(Int32)
        case bindFailed(Int32, String)
        case listenFailed(Int32)

        public var description: String {
            switch self {
            case .socketFailed(let code): "socket() failed: \(String(cString: strerror(code)))"
            case .bindFailed(let code, let path): "bind(\(path)) failed: \(String(cString: strerror(code)))"
            case .listenFailed(let code): "listen() failed: \(String(cString: strerror(code)))"
            }
        }
    }

    private let path: String
    private let onEvent: @Sendable (HookEvent) -> Void
    private let queue = DispatchQueue(label: "island.hook.accept")
    private let readQueue = DispatchQueue(label: "island.hook.read", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String = IslandPaths.socketPath, onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    deinit { stop() }

    public func start() throws {
        IslandPaths.ensureDirectory((path as NSString).deletingLastPathComponent)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socketFailed(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, path, capacity)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.bindFailed(code, path)
        }
        chmod(path, 0o600)

        guard listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw StartError.listenFailed(code)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            readQueue.async { [weak self] in self?.readPayload(from: client) }
        }
    }

    private func readPayload(from fd: Int32) {
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 1_000_000 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard !data.isEmpty, let event = HookEvent.decode(envelope: data) else { return }
        onEvent(event)
    }
}
