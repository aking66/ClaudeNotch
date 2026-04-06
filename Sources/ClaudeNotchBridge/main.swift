import Foundation
import Darwin

// ClaudeNotchBridge
// =================
// Invoked by Claude Code hooks configured in ~/.claude/settings.json.
// Reads a single JSON event from stdin, forwards it to the running
// ClaudeNotch main app via a Unix domain socket.
//
// For most events: fire-and-forget — send and exit immediately.
// For PermissionRequest: the bridge WAITS for the main app to send
// back a decision (allow / deny) and writes it to stdout so Claude
// Code can act on it without the user touching the terminal.
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

// Detect if this is a PermissionRequest (needs a blocking response).
let isPermissionRequest: Bool = {
    guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
        return false
    }
    return (obj["hook_event_name"] as? String) == "PermissionRequest"
}()

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
var outgoing = payload
outgoing.append(contentsOf: [0x0A])  // "\n"

outgoing.withUnsafeBytes { rawBuffer in
    guard let base = rawBuffer.baseAddress else { return }
    var offset = 0
    let total = rawBuffer.count
    while offset < total {
        let sent = send(fd, base.advanced(by: offset), total - offset, 0)
        if sent <= 0 { break }
        offset += sent
    }
}

if isPermissionRequest {
    // 6a. PermissionRequest: shut down the write direction so the server
    //     sees EOF and knows the event payload is complete, but keep the
    //     read direction open so we can receive the decision.
    shutdown(fd, SHUT_WR)

    // 7. Block until the main app writes a decision (or the socket dies).
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &chunk, chunk.count, 0)
        if n <= 0 { break }
        response.append(chunk, count: n)
    }

    // 8. Write the decision to stdout. Claude Code reads it and either
    //    proceeds with the tool call or shows its built-in prompt.
    if !response.isEmpty {
        FileHandle.standardOutput.write(response)
    }
} else {
    // 6b. Non-blocking events: nothing to wait for.
    shutdown(fd, SHUT_WR)
}

exit(0)
