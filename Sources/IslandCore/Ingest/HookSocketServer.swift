import Darwin
import Foundation

/// A hook that is waiting to hear back: a question or a plan Claude wants answered,
/// or a finished turn that can take the user's next message.
///
/// The connection stays open until the app answers, cancels, or lets it go. Closing
/// it without an answer lets the hook exit quietly, changing nothing.
public final class HookReplyChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit { cancel() }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    /// Tells the hook the app will answer, so it keeps waiting.
    func hold() -> Bool {
        write(Data([HookReply.holdByte]))
    }

    /// Answers the hook and closes the connection. False if it had already gone.
    @discardableResult
    public func send(_ reply: HookReply) -> Bool {
        defer { cancel() }
        return write(reply.wire)
    }

    /// Lets the hook go without an answer.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    private func write(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}

/// Listens on a Unix socket for payloads forwarded by `agent-island-hook`.
///
/// One connection carries one hook payload. Most are closed at once, so the agent
/// never waits on this app. A payload that asks for a reply keeps its connection,
/// handed over as a `HookReplyChannel`.
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
    private let onEvent: @Sendable (HookEvent, HookReplyChannel?) -> Void
    private let queue = DispatchQueue(label: "island.hook.accept")
    private let readQueue = DispatchQueue(label: "island.hook.read", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String = IslandPaths.socketPath, onEvent: @escaping @Sendable (HookEvent, HookReplyChannel?) -> Void) {
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
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // A hook that gave up must not take the app down with SIGPIPE when it answers.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // The helper half-closes once it has written, so this ends at its payload.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 1_000_000 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard !data.isEmpty, let event = HookEvent.decode(envelope: data) else {
            close(fd)
            return
        }
        guard event.wantsReply else {
            close(fd)
            onEvent(event, nil)
            return
        }
        let channel = HookReplyChannel(fd: fd)
        onEvent(event, channel.hold() ? channel : nil)
    }
}
