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
        let permissionSuggestions: [[String: Any]]  // PermissionRequest only
        let raw: [String: Any]             // full payload for future use
    }

    private var listenFd: Int32 = -1
    private var running = false
    private let handler: (Event) -> Void

    /// Open client fds for PermissionRequest hooks that are blocking,
    /// waiting for a decision from the UI. Keyed by session_id.
    private var pendingApprovals: [String: Int32] = [:]

    /// Tracks which sessions had their permission resolved via the UI
    /// (resolvePermission was called). When PostToolUse arrives and the
    /// session is NOT in this set, the user answered from the terminal.
    private var resolvedViaUI: Set<String> = []

    /// Sessions that currently have or recently had a pending permission.
    /// Used to distinguish "answered from terminal" vs "never had a prompt".
    private var hadPendingApproval: Set<String> = []

    /// When each pending approval was stored, for timeout-based cleanup.
    private var pendingApprovalTimes: [String: Date] = [:]

    /// Counter per session, incremented on each new PermissionRequest.
    /// Used to ensure the 10s fallback timer doesn't clear a NEWER permission.
    private var permissionGeneration: [String: Int] = [:]

    /// TTY per session, discovered from the bridge process's parent.
    /// Used to focus the correct terminal tab.
    private(set) var sessionTTY: [String: String] = [:]

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    /// Returns a summary of known TTY→session mappings for logging.
    var terminalSummary: String {
        if sessionTTY.isEmpty { return "no active TTYs" }
        return sessionTTY.map { "\(CNLog.sessionLabel($0.key))=\($0.value)" }.joined(separator: ", ")
    }

    /// Number of pending permission prompts.
    var pendingCount: Int { pendingApprovals.count }

    /// Check if a specific session has a pending approval fd.
    func hasPendingApproval(sessionId: String) -> Bool {
        pendingApprovals[sessionId] != nil
    }

    // MARK: - Public

    static var socketURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/ClaudeNotch/bridge.sock")
    }

    private var fdCheckTimer: Timer?

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

        // Poll pending approval fds every 2s to detect when the bridge
        // dies (user answered from terminal). When the fd is dead, clear
        // the pending approval so the UI stops showing the permission card.
        fdCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPendingFds() }
        }
    }

    /// Check if pending approval fds are stale. The bridge does
    /// shutdown(SHUT_WR) after sending the payload, so recv() sees EOF
    /// even when the bridge is alive and waiting. Instead, we track
    /// the time each pending approval was stored and clear it if no
    /// PostToolUse arrives within a generous window (30s).
    /// Real permissions are fast: user clicks within seconds. If 30s
    /// passes without PostToolUse, the user answered from terminal.
    private func checkPendingFds() {
        let now = Date()
        for (sid, storedAt) in pendingApprovalTimes {
            guard pendingApprovals[sid] != nil else {
                pendingApprovalTimes.removeValue(forKey: sid)
                continue
            }
            let age = now.timeIntervalSince(storedAt)
            // Don't clear too early — give the user time to respond via UI.
            // But after 30s with no PostToolUse, assume terminal-answered.
            if age > 30 {
                CNLog.perm("pending approval timed out after \(Int(age))s (likely terminal-answered) session=\(CNLog.sessionLabel(sid))")
                if let fd = pendingApprovals.removeValue(forKey: sid) {
                    close(fd)
                }
                pendingApprovalTimes.removeValue(forKey: sid)
                hadPendingApproval.remove(sid)
                staleApprovalCallback?(sid)
            }
        }
    }

    func stop() {
        fdCheckTimer?.invalidate()
        fdCheckTimer = nil
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

    /// Called when a PostToolUse event arrives — if the user approved from
    /// the terminal, the bridge is already gone. Close the stale fd so the
    /// permission card disappears from the UI.
    func clearPendingApproval(sessionId: String) {
        if let clientFd = pendingApprovals.removeValue(forKey: sessionId) {
            close(clientFd)
            CNLog.perm("cleared stale pending approval for \(CNLog.sessionLabel(sessionId))")
        }
    }

    /// Called from the UI when the user clicks Allow / Deny on a pending
    /// permission prompt. Writes the decision JSON back to the bridge
    /// process that's blocking on the socket, which in turn writes it to
    /// stdout for Claude Code to read.
    func resolvePermission(sessionId: String, decision: String) {
        guard let clientFd = pendingApprovals.removeValue(forKey: sessionId) else {
            CNLog.perm("no pending approval for \(CNLog.sessionLabel(sessionId))")
            return
        }
        resolvedViaUI.insert(sessionId)
        pendingApprovalTimes.removeValue(forKey: sessionId)
        CNLog.perm("resolving via UI: \(CNLog.sessionLabel(sessionId)) decision=\(decision)")

        // Claude Code PermissionRequest response format:
        //   "allow"  → hookSpecificOutput.decision.behavior = "allow"
        //   "deny"   → hookSpecificOutput.decision.behavior = "deny"
        //   "bypass" → top-level decision = "approve" (bypasses permission system)
        let response: [String: Any]
        if decision == "bypass" {
            response = ["decision": "approve"]
        } else {
            let decisionObj: [String: Any]
            switch decision {
            case "deny":
                decisionObj = ["behavior": "deny", "message": "Denied via ClaudeNotch"]
            case "always_allow":
                decisionObj = ["behavior": "allow", "remember": true]
            default: // "allow"
                decisionObj = ["behavior": "allow"]
            }
            response = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": decisionObj
                ] as [String: Any]
            ]
        }
        var sendOk = false
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                let n = send(clientFd, base, buf.count, 0)
                sendOk = n == buf.count
            }
        }
        close(clientFd)
        if sendOk {
            CNLog.perm("resolved via UI: \(CNLog.sessionLabel(sessionId)) → \(decision)")
        } else {
            CNLog.perm("SEND FAILED via UI: \(CNLog.sessionLabel(sessionId)) → \(decision) (bridge gone?)")
        }

        // Safety net: if PostToolUse doesn't arrive within 10s, the bridge
        // was already gone and the status is stuck. Clear it so the UI
        // doesn't show a stale permission card forever.
        // Capture the current generation so we don't kill a NEWER permission.
        let sid = sessionId
        let gen = permissionGeneration[sid, default: 0]
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            // Only clear if no new PermissionRequest arrived since we resolved.
            let currentGen = self.permissionGeneration[sid, default: 0]
            if currentGen == gen {
                self.clearStaleAwaitingApproval(sessionId: sid)
            }
        }
    }

    /// If a session is still awaitingApproval 10s after we resolved it,
    /// the bridge never relayed our answer. Force-clear the status.
    private func clearStaleAwaitingApproval(sessionId: String) {
        staleApprovalCallback?(sessionId)
    }

    /// Set by AppDelegate to clear stale awaitingApproval from the watcher.
    var staleApprovalCallback: ((String) -> Void)?

    /// Called from AppDelegate when PostToolUse arrives. If there's still
    /// a pending fd that wasn't resolved via UI, the user answered from
    /// the terminal. Log the source for diagnostics.
    func detectPermissionSource(sessionId: String) {
        if resolvedViaUI.remove(sessionId) != nil {
            // Already logged as "via UI" in resolvePermission.
            hadPendingApproval.remove(sessionId)
            return
        }
        // Only log "via Terminal" if this session actually had a pending
        // approval that's now gone (bridge exited because user answered).
        if hadPendingApproval.remove(sessionId) != nil && pendingApprovals[sessionId] == nil {
            CNLog.perm("resolved via Terminal: \(CNLog.sessionLabel(sessionId))")
        }
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

                // Register session name early so all log lines are readable.
                if let sid = event.sessionId, let cwd = event.cwd, !cwd.isEmpty {
                    CNLog.registerSession(id: sid, name: (cwd as NSString).lastPathComponent, fromHook: true)
                }

                // Store TTY from bridge (injected as _bridge_tty by the bridge process).
                if let sid = event.sessionId,
                   let tty = event.raw["_bridge_tty"] as? String, !tty.isEmpty {
                    if self.sessionTTY[sid] == nil {
                        self.sessionTTY[sid] = tty
                        CNLog.log("TTY from bridge: \(CNLog.sessionLabel(sid)) tty=\(tty)")
                    }
                }

                if isPermission, let sid = event.sessionId {
                    if let old = self.pendingApprovals[sid] {
                        CNLog.perm("replacing stale pending fd for \(CNLog.sessionLabel(sid))")
                        close(old)
                    }
                    var on: Int32 = 1
                    setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    self.pendingApprovals[sid] = clientFd
                    self.hadPendingApproval.insert(sid)
                    self.pendingApprovalTimes[sid] = Date()
                    self.permissionGeneration[sid, default: 0] += 1
                    CNLog.perm("stored pending fd=\(clientFd) for \(CNLog.sessionLabel(sid)) tool=\(event.toolName ?? "-")")
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
            permissionSuggestions: (obj["permission_suggestions"] as? [[String: Any]]) ?? [],
            raw: obj
        )
    }

    /// Find all TTYs for claude processes with the given CWD, then pick
    /// one that isn't already assigned to another session.
    private static func discoverTTYForSession(sessionId: String, cwd: String) -> String? {
        // Find ALL claude processes with matching CWD
        guard let psOutput = runSync("/bin/ps", ["-axo", "pid=,tty=,command="]) else { return nil }
        let normalizedCwd = (cwd as NSString).standardizingPath
        var candidateTTYs: [String] = []

        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 3 else { continue }
            let pid = Int(parts[0]) ?? 0
            let tty = parts[1]
            let command = parts[2]

            let isClaudeCLI = command.contains("/bin/claude") && !command.contains("browser-agent") && !command.contains("ClaudeNotch") && !command.contains("vibe-island")
            guard isClaudeCLI, tty != "?", tty != "??" else { continue }

            // Check CWD
            if let pidCwd = runSync("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) {
                for cwdLine in pidCwd.split(separator: "\n") {
                    if cwdLine.hasPrefix("n") {
                        let processCwd = (String(cwdLine.dropFirst()) as NSString).standardizingPath
                        if processCwd == normalizedCwd {
                            candidateTTYs.append(tty)
                        }
                    }
                }
            }
        }

        CNLog.log("TTY discovery for \(CNLog.sessionLabel(sessionId)): \(candidateTTYs.count) candidates: \(candidateTTYs)")

        // If only one candidate, use it
        if candidateTTYs.count == 1 { return candidateTTYs[0] }
        if candidateTTYs.isEmpty { return nil }

        // Multiple candidates — return the first that hasn't been claimed
        // by another session. This is a best-effort heuristic.
        // (Runs on background queue, reads sessionTTY on main would need sync.)
        return candidateTTYs.first
    }

    private nonisolated static func runSync(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.launchPath = path
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
