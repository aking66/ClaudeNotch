import Foundation
import Darwin

// ClaudeNotchBridge
// =================
// Invoked by Claude Code hooks configured in ~/.claude/settings.json.
// Reads a single JSON event from stdin, forwards it to the running
// ClaudeNotch main app via a Unix domain socket, then exits.
//
// If the main app isn't running (socket doesn't exist or connect fails)
// we just exit silently with 0 — hooks must never block Claude Code.

let socketPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent("Library/Application Support/ClaudeNotch/bridge.sock")
        .path
}()

// 1. Drain stdin. Claude Code writes a single JSON object then closes.
let payload = FileHandle.standardInput.readDataToEndOfFile()
guard !payload.isEmpty else { exit(0) }

// 2. Open a Unix stream socket.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
defer { close(fd) }

// 3. Build sockaddr_un pointing at the well-known path.
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
_ = socketPath.withCString { src in
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPath) { dst in
            strncpy(dst, src, maxPath - 1)
        }
    }
}

// 4. Connect. If the app isn't running, just bail out cleanly.
let connectResult = withUnsafePointer(to: &addr) { addrPtr in
    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connectResult == 0 else { exit(0) }

// 5. Send the payload plus a trailing newline as a framing delimiter.
var remaining = payload
remaining.append(contentsOf: [0x0A])  // "\n"

remaining.withUnsafeBytes { rawBuffer in
    guard let base = rawBuffer.baseAddress else { return }
    var offset = 0
    let total = rawBuffer.count
    while offset < total {
        let sent = send(fd, base.advanced(by: offset), total - offset, 0)
        if sent <= 0 { break }
        offset += sent
    }
}

exit(0)
