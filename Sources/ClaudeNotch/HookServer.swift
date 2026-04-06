import Foundation
import Darwin

/// Unix-domain-socket server that listens for Claude Code hook events
/// forwarded by the `ClaudeNotchBridge` helper binary. Each connection
/// delivers exactly one JSON-line payload; the server parses it and
/// hands it to `handler` on the main actor.
@MainActor
final class HookServer {
    /// Parsed event delivered to the handler.
    struct Event {
        let hookEventName: String          // e.g. "Stop", "PreToolUse"
        let sessionId: String?             // uuid of the session
        let cwd: String?                   // session working directory
        let transcriptPath: String?        // absolute path to the .jsonl
        let toolName: String?              // tool_use events
        let toolInput: [String: Any]?      // tool parameters (PreToolUse)
        let raw: [String: Any]             // full payload for future use
    }

    private var listenFd: Int32 = -1
    private var running = false
    private let handler: (Event) -> Void

    /// Open client fds for PermissionRequest hooks that are blocking,
    /// waiting for a decision from the UI. Keyed by session_id.
    private var pendingApprovals: [String: Int32] = [:]

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    // MARK: - Public

    static var socketURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/ClaudeNotch/bridge.sock")
    }

    func start() {
        let socketURL = Self.socketURL
        let dir = socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = socketURL.path
        // Remove any stale socket from a previous run.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("ClaudeNotch: socket() failed (errno=\(errno))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPath else {
            NSLog("ClaudeNotch: socket path too long: \(path)")
            close(fd); return
        }
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPath) { dst in
                    strncpy(dst, src, maxPath - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("ClaudeNotch: bind() failed (errno=\(errno))")
            close(fd); return
        }

        // Tighten permissions: only the current user can talk to us.
        chmod(path, 0o600)

        guard listen(fd, 32) == 0 else {
            NSLog("ClaudeNotch: listen() failed (errno=\(errno))")
            close(fd); return
        }

        self.listenFd = fd
        self.running = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }

        NSLog("ClaudeNotch: HookServer listening at \(path)")
    }

    func stop() {
        running = false
        if listenFd >= 0 {
            shutdown(listenFd, SHUT_RDWR)
            close(listenFd)
            listenFd = -1
        }
        // Close any pending approval connections.
        for (_, clientFd) in pendingApprovals {
            close(clientFd)
        }
        pendingApprovals.removeAll()
        unlink(Self.socketURL.path)
    }

    // MARK: - Permission approval resolution

    /// Called from the UI when the user clicks Allow / Deny on a pending
    /// permission prompt. Writes the decision JSON back to the bridge
    /// process that's blocking on the socket, which in turn writes it to
    /// stdout for Claude Code to read.
    func resolvePermission(sessionId: String, decision: String) {
        guard let clientFd = pendingApprovals.removeValue(forKey: sessionId) else {
            NSLog("ClaudeNotch: no pending approval for session \(sessionId)")
            return
        }

        let response: [String: Any] = [
            "hookSpecificOutput": ["decision": decision]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                _ = send(clientFd, base, buf.count, 0)
            }
        }
        close(clientFd)
        NSLog("ClaudeNotch: resolved permission for \(sessionId) → \(decision)")
    }

    // MARK: - Accept loop (runs on background queue)

    private nonisolated func acceptLoop() {
        while true {
            let fd = Self.captureListenFd(owner: self)
            guard fd >= 0 else { return }

            let clientFd = accept(fd, nil, nil)
            if clientFd < 0 {
                if errno == EBADF || errno == EINVAL { return }
                continue
            }

            // The bridge sends the JSON payload then shuts down its write
            // end (SHUT_WR). Our drain sees EOF and returns the full data.
            let data = Self.drain(clientFd: clientFd)

            guard !data.isEmpty,
                  let event = Self.parseEvent(data)
            else {
                close(clientFd)
                continue
            }

            let isPermission = event.hookEventName == "PermissionRequest"

            if !isPermission {
                // Fire-and-forget: close the connection immediately.
                close(clientFd)
            }
            // PermissionRequest: keep clientFd OPEN so the bridge blocks
            // on read until we write the decision back (resolvePermission).

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if isPermission, let sid = event.sessionId {
                    // Close any stale pending fd for this session before
                    // storing the new one (e.g. user cancelled and retried).
                    if let old = self.pendingApprovals[sid] {
                        close(old)
                    }
                    self.pendingApprovals[sid] = clientFd
                }

                self.handler(event)
            }
        }
    }

    /// Thread-safe readout of the listen fd. `acceptLoop` is nonisolated
    /// so we hop to the main actor just to read the value.
    private nonisolated static func captureListenFd(owner: HookServer?) -> Int32 {
        var fd: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak owner] in
            // Reading a stored property from the main actor is safe.
            MainActor.assumeIsolated {
                fd = owner?.listenFd ?? -1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return fd
    }

    private nonisolated static func drain(clientFd: Int32) -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(clientFd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
        }
        return buffer
    }

    private nonisolated static func parseEvent(_ data: Data) -> Event? {
        // A payload may contain a trailing newline — tolerate it.
        let trimmed: Data = {
            if let last = data.last, last == 0x0A {
                return data.dropLast()
            }
            return data
        }()

        guard let obj = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any]
        else { return nil }

        let name = (obj["hook_event_name"] as? String) ?? ""
        return Event(
            hookEventName: name,
            sessionId: obj["session_id"] as? String,
            cwd: obj["cwd"] as? String,
            transcriptPath: obj["transcript_path"] as? String,
            toolName: obj["tool_name"] as? String,
            toolInput: obj["tool_input"] as? [String: Any],
            raw: obj
        )
    }
}
