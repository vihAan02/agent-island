// Forwards one Claude Code or Codex hook payload to the running AgentIsland app.
//
// Runs on every hook, so it stays tiny: no Foundation and no JSON parsing. It prints
// nothing and exits 0, so it never changes a permission decision or slows a turn.
//
// The one exception is `--reply`, used only by the hooks that can be answered from
// the island: AskUserQuestion and ExitPlanMode, and the end of a turn. Those wait
// for the app and print what it sends back, which is only ever something the user
// chose in the island. If the app does not say at once that it will answer, they
// give up and exit 0 like the rest.

import Darwin

let sendTimeoutMilliseconds: Int32 = 300
/// How long to wait for the app to say it will answer.
let holdTimeoutSeconds = 2
let holdByte = UInt8(ascii: "K")
let maximumPayloadBytes = 1 << 20

func environmentValue(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    return String(cString: raw)
}

func jsonEscaped(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count + 8)
    for character in value.unicodeScalars {
        switch character {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if character.value < 0x20 {
                let digits = Array("0123456789abcdef")
                let value = Int(character.value)
                out += "\\u00"
                out.append(digits[(value >> 4) & 0xF])
                out.append(digits[value & 0xF])
            } else {
                out.unicodeScalars.append(character)
            }
        }
    }
    return out
}

func readStandardInput() -> [UInt8] {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while bytes.count < maximumPayloadBytes {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count <= 0 { break }
        bytes.append(contentsOf: buffer[0..<count])
    }
    return bytes
}

func socketPath() -> String {
    if let override = environmentValue("AGENT_ISLAND_SOCKET"), !override.isEmpty { return override }
    let home = environmentValue("HOME") ?? "/tmp"
    return home + "/Library/Application Support/AgentIsland/island.sock"
}

/// Sends the payload. With `keepOpen`, returns the connection, half-closed, to read
/// the app's answer from; otherwise closes it and returns -1.
func send(_ bytes: [UInt8], to path: String, keepOpen: Bool) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var handedOver = false
    defer { if !handedOver { close(fd) } }

    var timeout = timeval(tv_sec: 0, tv_usec: Int32(sendTimeoutMilliseconds) * 1000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { raw in
        raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            _ = strlcpy(destination, path, capacity)
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    // The app is not running. That is fine: hooks must never fail because of us.
    guard connected == 0 else { return -1 }

    let sent = bytes.withUnsafeBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, base + offset, buffer.count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
    guard sent, keepOpen else { return -1 }
    // The app reads to the end of the payload before answering.
    shutdown(fd, SHUT_WR)
    handedOver = true
    return fd
}

func writeAll(_ fd: Int32, _ bytes: ArraySlice<UInt8>) {
    var rest = bytes
    while !rest.isEmpty {
        let written = rest.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        if written <= 0 { return }
        rest = rest.dropFirst(written)
    }
}

/// Waits for the app's answer and acts on it. `O` prints a permission decision to
/// stdout; `W` prints a message for the model to stderr and exits 2, which wakes an
/// `asyncRewake` hook's session. Anything else, or the app letting go, changes nothing.
func awaitReply(on fd: Int32) -> Never {
    var timeout = timeval(tv_sec: holdTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var first: UInt8 = 0
    guard read(fd, &first, 1) == 1, first == holdByte else { exit(0) }

    // From here the wait is open-ended: the user answers, the app lets go, or the
    // agent's own hook timeout ends it.
    timeout = timeval(tv_sec: 0, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var reply: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while reply.count < maximumPayloadBytes {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        reply.append(contentsOf: buffer[0..<count])
    }
    guard let kind = reply.first else { exit(0) }
    switch kind {
    case UInt8(ascii: "O"):
        writeAll(STDOUT_FILENO, reply.dropFirst())
        exit(0)
    case UInt8(ascii: "W"):
        writeAll(STDERR_FILENO, reply.dropFirst())
        exit(2)
    default:
        exit(0)
    }
}

// argv[1] names the agent: "claude" (default) or "codex". `--reply` waits for an answer.
let agent = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "claude"
let wantsReply = CommandLine.arguments.dropFirst(2).contains("--reply")
let payload = readStandardInput()

// The payload is passed through untouched, wrapped in an envelope with the bits of
// environment that say which app the session belongs to.
guard let first = payload.first, first == UInt8(ascii: "{") else { exit(0) }

let interestingVariables = [
    "CLAUDE_EFFORT",
    "CLAUDE_PROJECT_DIR",
    "CODEX_HOME",
    "TERM_PROGRAM",
    "TERM",
    "__CFBundleIdentifier",
]
var environmentPairs: [String] = []
for name in interestingVariables {
    if let value = environmentValue(name) {
        environmentPairs.append("\"\(jsonEscaped(name))\":\"\(jsonEscaped(value))\"")
    }
}

var message = Array(
    "{\"agent\":\"\(jsonEscaped(agent))\",\"pid\":\(getppid()),\"reply\":\(wantsReply),\"env\":{\(environmentPairs.joined(separator: ","))},\"payload\":".utf8
)
message.append(contentsOf: payload)
message.append(contentsOf: Array("}".utf8))

let connection = send(message, to: socketPath(), keepOpen: wantsReply)
if connection >= 0 { awaitReply(on: connection) }
exit(0)
