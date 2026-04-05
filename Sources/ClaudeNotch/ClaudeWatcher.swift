import Foundation
import UserNotifications

/// Execution status of a Claude Code session, derived from the jsonl tail
/// plus file activity signals. Tracked as a proper state machine so the UI
/// can distinguish "Claude is computing" from "Claude is stuck waiting for
/// the user to click Allow on a tool request" from "Claude is done".
enum SessionStatus: String, Hashable {
    case working           // streaming, running a tool, or user just spoke
    case awaitingApproval  // tool_use pending with no recent file activity
    case idle              // last assistant message hit a terminal stop_reason

    var isBusy: Bool { self != .idle }
}

/// Token usage snapshot for a session. `contextTokens` mirrors what the
/// Claude Code statusline shows: the current context-window occupancy
/// drawn from the most recent assistant message.
struct UsageStats: Hashable {
    let contextTokens: Int    // last message: input + cache_read + cache_create
    let outputTokens: Int     // cumulative output across the whole session
}

/// The tool Claude is currently running (or most recently ran) in a
/// session. Populated from `PreToolUse` hook events and cleared on
/// `PostToolUse`; gives the notch a human-readable "what's it doing
/// right now" badge.
struct CurrentTool: Hashable {
    let name: String          // e.g. "Bash", "Edit", "Read"
    let detail: String?       // a short summary of the tool input
}

/// A single active Claude Code session discovered on disk.
struct ClaudeSession: Identifiable, Hashable {
    let id: URL          // path to the .jsonl file
    let projectName: String
    let lastModified: Date
    let lastSnippet: String?    // Last assistant text, cleaned + truncated
    let status: SessionStatus   // Working / awaiting approval / idle
    let cwd: String?            // Authoritative working dir from the jsonl entries
    let usage: UsageStats?      // Cumulative token usage + cost
    let gitBranch: String?      // Current git branch from the jsonl
    let currentTool: CurrentTool?  // Tool currently in flight (hook-driven)

    /// Convenience for call sites that just want "is something happening".
    var isWorking: Bool { status == .working }

    /// Session UUID extracted from the jsonl filename, e.g.
    /// "2f627212-805d-4117-b41b-41dddd6f10a1" from "…/<uuid>.jsonl".
    /// Matches the `session_id` field in hook event payloads.
    var sessionID: String {
        id.deletingPathExtension().lastPathComponent
    }

    /// Return a copy with a different status. Used when a hook event
    /// arrives and overrides the jsonl-derived value.
    func with(status newStatus: SessionStatus) -> ClaudeSession {
        ClaudeSession(
            id: id,
            projectName: projectName,
            lastModified: lastModified,
            lastSnippet: lastSnippet,
            status: newStatus,
            cwd: cwd,
            usage: usage,
            gitBranch: gitBranch,
            currentTool: currentTool
        )
    }

    /// Return a copy with a different currentTool.
    func with(currentTool newTool: CurrentTool?) -> ClaudeSession {
        ClaudeSession(
            id: id,
            projectName: projectName,
            lastModified: lastModified,
            lastSnippet: lastSnippet,
            status: status,
            cwd: cwd,
            usage: usage,
            gitBranch: gitBranch,
            currentTool: newTool
        )
    }
}

/// Polls ~/.claude/projects/ every few seconds and publishes active sessions.
/// Active = a .jsonl session file modified within the last 5 minutes.
@MainActor
final class ClaudeWatcher: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    private var timer: Timer?
    private let activeWindow: TimeInterval = 20 * 60  // 20 minutes

    /// Cache parsed usage per session file. Keyed by URL, value includes the
    /// file mtime at parse time so we can invalidate cheaply.
    private var usageCache: [URL: (mtime: Date, stats: UsageStats)] = [:]

    /// Previous status per session, used to detect transitions and fire
    /// notifications / avoid flicker from transient parse failures.
    private var lastStatus: [URL: SessionStatus] = [:]

    /// Sessions built from disk on the last refresh, keyed by URL. The
    /// published `sessions` array is produced by merging this with hook
    /// overrides so UI updates can arrive without re-scanning disk.
    private var baseSessions: [URL: ClaudeSession] = [:]

    /// Current in-flight tool per session UUID, populated from
    /// `PreToolUse` hook events and cleared on `PostToolUse`.
    private var currentTools: [String: CurrentTool] = [:]

    /// Session-status overrides driven by Claude Code hook events.
    /// Keyed by session UUID (matches ClaudeSession.sessionID). Each
    /// override carries the timestamp it was written so it can expire.
    ///
    /// Why the expiry matters: if a session fired `PermissionRequest`
    /// (setting status → awaitingApproval) and then the user approved
    /// in a terminal window where our hooks aren't installed (e.g. a
    /// session that started before HookInstaller ran), no clearing
    /// event ever arrives and the UI gets stuck. With expiry, we fall
    /// back to the parseTail-derived status after the timeout.
    private var hookStatus: [String: (status: SessionStatus, at: Date)] = [:]

    /// How long a hook-driven status remains authoritative. Long enough
    /// to cover the typical gap between a PermissionRequest and the
    /// matching PostToolUse, short enough to recover from lost events.
    private let hookStatusTTL: TimeInterval = 90

    /// If a tool_use is the last assistant entry AND the file has been idle
    /// for longer than this, the session is considered to be waiting for the
    /// user to approve the tool call rather than actively running it.
    private let approvalIdleThreshold: TimeInterval = 2.5

    func start() {
        requestNotificationPermission()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let fm = FileManager.default
        let projectsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            sessions = []
            return
        }

        let cutoff = Date().addingTimeInterval(-activeWindow)
        var found: [ClaudeSession] = []

        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            let jsonls = files.filter { $0.pathExtension == "jsonl" }
            guard let latest = jsonls.max(by: { a, b in
                Self.modDate(a) < Self.modDate(b)
            }) else { continue }

            let mod = Self.modDate(latest)
            if mod > cutoff {
                let tail = Self.parseTail(latest)

                // Classify status from the parsed tail. Fall back to the
                // previously known status on parse failures so we don't
                // flicker to idle when a giant entry overflows the buffer.
                let parseFailed = (tail.cwd == nil && tail.snippet == nil && tail.lastEntryKind == .unknown)
                let now = Date()
                let status: SessionStatus
                if parseFailed {
                    status = lastStatus[latest] ?? .idle
                } else {
                    status = Self.classifyStatus(tail: tail, fileModifiedAt: mod, now: now,
                                                 approvalIdleThreshold: approvalIdleThreshold)
                }

                // Detect transitions and notify the user when a session
                // finishes (busy → idle) or needs their attention.
                let previous = lastStatus[latest]
                if let previous, previous != status {
                    handleTransition(
                        from: previous, to: status,
                        projectName: Self.decodeProjectName(dir.lastPathComponent)
                    )
                }
                lastStatus[latest] = status

                // Expensive full-file scan for usage — cache by mtime so we
                // only re-parse when the file actually changed.
                let usage: UsageStats?
                if let cached = usageCache[latest], cached.mtime == mod {
                    usage = cached.stats
                } else {
                    usage = Self.parseUsage(latest)
                    if let u = usage {
                        usageCache[latest] = (mod, u)
                    }
                }

                found.append(ClaudeSession(
                    id: latest,
                    projectName: Self.decodeProjectName(dir.lastPathComponent),
                    lastModified: mod,
                    lastSnippet: tail.snippet,
                    status: status,
                    cwd: tail.cwd,
                    usage: usage,
                    gitBranch: tail.branch,
                    currentTool: nil
                ))
            }
        }

        // Rebuild the base session map, then merge hook overrides and
        // publish.
        baseSessions = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        rebuildPublishedSessions()

        // Prune caches for sessions that are no longer active.
        let activeIDs = Set(found.map { $0.id })
        let activeSessionIDs = Set(found.map { $0.sessionID })
        usageCache = usageCache.filter { activeIDs.contains($0.key) }
        lastStatus = lastStatus.filter { activeIDs.contains($0.key) }
        hookStatus = hookStatus.filter { activeSessionIDs.contains($0.key) }
        currentTools = currentTools.filter { activeSessionIDs.contains($0.key) }
    }

    // MARK: - Hook-driven updates

    /// Called by the HookServer whenever Claude Code fires an event.
    /// Updates the status of the matching session immediately (no disk
    /// scan) and republishes so the UI reflects the change with
    /// sub-100ms latency.
    func applyHookEvent(_ event: HookServer.Event) {
        guard let sid = event.sessionId, !sid.isEmpty else { return }

        // Track the in-flight tool per session so the UI can show a
        // "Bash: git show …" badge while it's running.
        switch event.hookEventName {
        case "PreToolUse":
            if let name = event.toolName {
                currentTools[sid] = CurrentTool(
                    name: name,
                    detail: Self.describeToolInput(
                        toolName: name,
                        input: event.toolInput
                    )
                )
            }
        case "PostToolUse", "Stop", "SessionEnd":
            currentTools[sid] = nil
        default:
            break
        }

        guard let newStatus = Self.statusFromHookEvent(event.hookEventName) else {
            rebuildPublishedSessions()
            return
        }

        let previousStatus = hookStatus[sid]?.status
        hookStatus[sid] = (newStatus, Date())

        // Fire user notifications on the meaningful transitions.
        if previousStatus != newStatus {
            let projectName = baseSessions.values
                .first(where: { $0.sessionID == sid })?.projectName
                ?? sid
            handleTransition(
                from: previousStatus ?? .idle,
                to: newStatus,
                projectName: projectName
            )
        }

        rebuildPublishedSessions()
    }

    /// Turn a tool_input payload into a short human string. Falls back
    /// to nil for tools we don't specifically recognise — the UI will
    /// just show the bare tool name in that case.
    private static func describeToolInput(toolName: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let raw: String?
        switch toolName {
        case "Bash":
            raw = input["command"] as? String
        case "Read", "Edit", "Write", "NotebookEdit":
            if let path = input["file_path"] as? String {
                raw = (path as NSString).lastPathComponent
            } else {
                raw = nil
            }
        case "Glob":
            raw = input["pattern"] as? String
        case "Grep":
            raw = input["pattern"] as? String
        case "Task", "Agent":
            let type = input["subagent_type"] as? String ?? ""
            let desc = input["description"] as? String ?? ""
            raw = type.isEmpty ? desc : "\(type): \(desc)"
        case "WebFetch":
            raw = input["url"] as? String
        case "WebSearch":
            raw = input["query"] as? String
        default:
            raw = nil
        }
        guard var s = raw else { return nil }
        s = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if s.count > 80 { s = String(s.prefix(80)) + "…" }
        return s.isEmpty ? nil : s
    }

    /// Map a hook event name to the session status it implies.
    /// Events we don't care about return nil (no update).
    private static func statusFromHookEvent(_ name: String) -> SessionStatus? {
        switch name {
        case "UserPromptSubmit", "PreToolUse":
            return .working
        case "PostToolUse":
            // Tool finished (whether auto-approved or user-approved) — the
            // session is no longer blocked on a permission prompt. Claude
            // is still mid-turn; a Stop will arrive when it truly finishes.
            return .working
        case "PermissionRequest":
            // The authoritative signal for "stuck waiting on the user".
            return .awaitingApproval
        case "Stop", "SessionEnd":
            return .idle
        default:
            // Notification and other events are deliberately ignored: they
            // can fire for idle timeouts, session ends, generic attention
            // requests, etc. and would cause false "awaiting approval"
            // states. PermissionRequest is the only reliable approval
            // signal; we rely on it alone.
            return nil
        }
    }

    /// Merge `baseSessions` with `hookStatus` + `currentTools` overrides
    /// and publish. Hook status overrides older than `hookStatusTTL` are
    /// ignored so a stuck awaitingApproval (e.g. from a session that
    /// predated the hook installer) recovers on its own.
    private func rebuildPublishedSessions() {
        let now = Date()
        let merged = baseSessions.values.map { session -> ClaudeSession in
            var result = session
            if let hook = hookStatus[session.sessionID],
               now.timeIntervalSince(hook.at) < hookStatusTTL {
                result = result.with(status: hook.status)
            }
            if let tool = currentTools[session.sessionID] {
                result = result.with(currentTool: tool)
            }
            return result
        }
        sessions = merged.sorted { $0.lastModified > $1.lastModified }
    }

    // MARK: - Status classification

    /// Turn the raw tail parse into a SessionStatus. The logic hinges on
    /// the last entry kind and (for tool_use) file activity freshness.
    private static func classifyStatus(
        tail: TailParseResult,
        fileModifiedAt: Date,
        now: Date,
        approvalIdleThreshold: TimeInterval
    ) -> SessionStatus {
        switch tail.lastEntryKind {
        case .assistantStreaming:
            // Assistant entry exists but stop_reason is still null → mid-stream.
            return .working

        case .assistantToolUse:
            // Claude requested a tool. If the file has been quiet for more
            // than a couple seconds, the harness is stuck on a permission
            // prompt waiting for the user. Otherwise the tool is running.
            let idleFor = now.timeIntervalSince(fileModifiedAt)
            return idleFor > approvalIdleThreshold ? .awaitingApproval : .working

        case .assistantEndTurn:
            return .idle

        case .userMessage:
            // User just spoke (input or tool_result). Claude will respond.
            return .working

        case .unknown:
            return .idle
        }
    }

    // MARK: - Notifications

    /// React to a session status change. Fires a user notification on the
    /// two transitions that matter most: completion and approval-wait.
    private func handleTransition(
        from previous: SessionStatus,
        to current: SessionStatus,
        projectName: String
    ) {
        // Completion: something was happening, now idle.
        if previous.isBusy && current == .idle {
            postNotification(
                title: "Claude finished",
                body: projectName,
                sound: true
            )
            return
        }

        // New approval request (either fresh start or transition from working).
        if current == .awaitingApproval && previous != .awaitingApproval {
            postNotification(
                title: "Claude needs approval",
                body: projectName,
                sound: true
            )
        }
    }

    private func postNotification(title: String, body: String, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Classification of the most recent jsonl entry for a session.
    enum LastEntryKind {
        case assistantStreaming  // assistant message with stop_reason == null
        case assistantToolUse    // assistant message with stop_reason == "tool_use"
        case assistantEndTurn    // assistant message with a terminal stop_reason
        case userMessage         // user prompt or tool_result
        case unknown             // parse failed or nothing matched
    }

    /// Everything parseTail extracts from the session file tail.
    struct TailParseResult {
        let snippet: String?
        let cwd: String?
        let branch: String?
        let lastEntryKind: LastEntryKind
    }

    /// Read the tail of a .jsonl session file and derive a `TailParseResult`.
    /// Reads up to 512 KB to comfortably contain large tool results; entries
    /// bigger than that are handled upstream by keeping the previous status
    /// on parse failure.
    private static func parseTail(_ url: URL) -> TailParseResult {
        let empty = TailParseResult(snippet: nil, cwd: nil, branch: nil, lastEntryKind: .unknown)

        guard let handle = try? FileHandle(forReadingFrom: url) else { return empty }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 524_288  // 512 KB
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let start = fileSize > chunkSize ? fileSize - chunkSize : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()

        guard let text = String(data: data, encoding: .utf8) else { return empty }

        // Parse lines in reverse. The very first (last) line may be a partial
        // write from Claude Code currently flushing, so tolerate parse failures.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        var snippet: String? = nil
        var cwd: String? = nil
        var branch: String? = nil
        var lastEntryKind: LastEntryKind = .unknown
        var lastEntryResolved = false

        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // First successfully parsed line (most recent) classifies the
            // last-entry kind for the whole session.
            if !lastEntryResolved {
                lastEntryKind = classifyEntry(obj)
                lastEntryResolved = true
            }

            // cwd and gitBranch appear on every entry; snapshot them from the
            // most recent successfully parsed line.
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
                cwd = c
            }
            if branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty {
                branch = b
            }

            // Capture the most recent assistant text content for the snippet.
            if snippet == nil,
               (obj["type"] as? String) == "assistant",
               let msg = obj["message"] as? [String: Any],
               let contents = msg["content"] as? [[String: Any]] {
                for c in contents {
                    if (c["type"] as? String) == "text",
                       let txt = c["text"] as? String {
                        var cleaned = txt
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleaned.count > 120 {
                            cleaned = String(cleaned.prefix(120))
                        }
                        if !cleaned.isEmpty { snippet = cleaned }
                        break
                    }
                }
            }

            if lastEntryResolved && snippet != nil && cwd != nil && branch != nil { break }
        }

        return TailParseResult(
            snippet: snippet,
            cwd: cwd,
            branch: branch,
            lastEntryKind: lastEntryKind
        )
    }

    /// Map a single parsed jsonl entry to a LastEntryKind. Prefers the
    /// explicit `stop_reason` field over content-type heuristics.
    private static func classifyEntry(_ obj: [String: Any]) -> LastEntryKind {
        guard let type = obj["type"] as? String else { return .unknown }

        if type == "user" {
            return .userMessage
        }

        guard type == "assistant",
              let msg = obj["message"] as? [String: Any]
        else { return .unknown }

        // stop_reason is the authoritative indicator of turn state.
        //   null (missing)   → still streaming
        //   "tool_use"       → tool call pending
        //   "end_turn" / etc → terminal, ready for next user input
        if let stopReason = msg["stop_reason"] as? String {
            if stopReason == "tool_use" {
                return .assistantToolUse
            }
            return .assistantEndTurn
        }

        // stop_reason explicitly null or missing → still being written.
        return .assistantStreaming
    }

    /// Stream the entire .jsonl file and derive usage stats. `contextTokens`
    /// comes from the most recent assistant `usage` block (summing input,
    /// cache_read, and cache_creation — i.e., the full context window at that
    /// turn). `outputTokens` is a cumulative sum across every assistant entry.
    /// Returns nil for empty or unparseable files.
    private static func parseUsage(_ url: URL) -> UsageStats? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var cumulativeOutput = 0
        var latestContextTokens = 0
        var sawAny = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any]
            else { continue }

            sawAny = true
            cumulativeOutput += (usage["output_tokens"] as? Int) ?? 0

            // Snapshot the latest assistant turn's context-window footprint.
            let input = (usage["input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0

            var cacheCreate = 0
            if let cc = usage["cache_creation"] as? [String: Any] {
                cacheCreate += (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
                cacheCreate += (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
            } else {
                cacheCreate += (usage["cache_creation_input_tokens"] as? Int) ?? 0
            }

            latestContextTokens = input + cacheRead + cacheCreate
        }

        guard sawAny else { return nil }

        return UsageStats(
            contextTokens: latestContextTokens,
            outputTokens: cumulativeOutput
        )
    }

    /// Claude Code encodes project paths by replacing "/" with "-".
    /// e.g. "-Users-ahmed-ClaudeNotch" -> "~/ClaudeNotch"
    private static func decodeProjectName(_ encoded: String) -> String {
        var s = encoded
        if s.hasPrefix("-Users-") {
            s = String(s.dropFirst("-Users-".count))
            // Drop the username segment (first "-" separated component)
            if let firstDash = s.firstIndex(of: "-") {
                s = String(s[s.index(after: firstDash)...])
            } else {
                return "~"
            }
        }
        return "~/" + s.replacingOccurrences(of: "-", with: "/")
    }
}
