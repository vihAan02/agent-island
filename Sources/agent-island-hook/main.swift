// Forwards one Claude Code or Codex hook payload to the running AgentIsland app.
//
// Runs on every hook, so it stays tiny: no Foundation, no JSON parsing, no output,
// and it always exits 0 so it can never change a permission decision or slow a turn.

import Darwin

let sendTimeoutMilliseconds: Int32 = 300
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

func send(_ bytes: [UInt8], to path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }

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
    guard connected == 0 else { return }

    var offset = 0
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        while offset < buffer.count {
            let written = write(fd, base + offset, buffer.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}

// argv[1] names the agent: "claude" (default) or "codex".
let agent = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "claude"
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
    "{\"agent\":\"\(jsonEscaped(agent))\",\"pid\":\(getppid()),\"env\":{\(environmentPairs.joined(separator: ","))},\"payload\":".utf8
)
message.append(contentsOf: payload)
message.append(contentsOf: Array("}".utf8))

send(message, to: socketPath())
exit(0)
