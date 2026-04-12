import AppKit
import Foundation
import UserNotifications

/// Execution status of a Claude Code session, derived from the jsonl tail
/// plus file activity signals. Tracked as a proper state machine so the UI
/// can distinguish "Claude is computing" from "Claude is stuck waiting for
/// the user to click Allow on a tool request" from "Claude is done".
enum SessionStatus: String, Hashable {
    case working           // streaming, running a tool, or user just spoke
    case compacting        // context compaction in progress
    case awaitingApproval  // tool_use pending with no recent file activity
    case interrupted       // session was terminated/cancelled mid-turn
    case idle              // last assistant message hit a terminal stop_reason

    var isBusy: Bool { self != .idle && self != .interrupted }
}

/// Token usage snapshot for a session. `contextTokens` mirrors what the
/// Claude Code statusline shows: the current context-window occupancy
/// drawn from the most recent assistant message.
struct UsageStats: Hashable {
    let contextTokens: Int    // last message: input + cache_read + cache_create
    let outputTokens: Int     // cumulative output across the whole session
}

/// Preview of code changes for Edit/Write permission requests.
/// Shown in the permission card so the user can review the actual
/// diff before approving.
struct DiffPreview: Hashable {
    let filePath: String       // full path to the file
    let oldString: String?     // Edit: text being replaced (max ~500 chars)
    let newString: String?     // Edit: replacement text (max ~500 chars)
    let content: String?       // Write: new file content preview (max ~1000 chars)
}

/// The tool Claude is currently running (or most recently ran) in a
/// session. Populated from `PreToolUse` hook events and cleared on
/// `PostToolUse`; gives the notch a human-readable "what's it doing
/// right now" badge.
struct CurrentTool: Hashable {
    let name: String          // e.g. "Bash", "Edit", "Read"
    let detail: String?       // a short summary of the tool input
    let description: String?  // human description from tool_input.description
    let diffPreview: DiffPreview?  // code changes for Edit/Write tools
    let hasAlwaysAllow: Bool  // true if permission_suggestions is non-empty
}

/// A subagent spawned by the Agent tool within a parent session.
struct Subagent: Identifiable, Hashable {
    let id: String            // unique subagent id from the hook payload
    let agentType: String     // e.g. "general-purpose", "Explore", "Plan"
    let description: String?  // task description
    let startedAt: Date
    var status: SubagentStatus
    var currentTool: CurrentTool?  // what the subagent is currently doing
    var duration: TimeInterval { Date().timeIntervalSince(startedAt) }
}

enum SubagentStatus: String, Hashable {
    case running = "Running"
    case done = "Done"
}

/// A task item from Claude's TodoWrite tool.
struct TodoItem: Hashable, Identifiable {
    let id: String              // content hash for identity
    let content: String         // task description
    let status: TodoStatus      // pending / in_progress / completed
}

enum TodoStatus: String, Hashable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
}

/// A single active Claude Code session discovered on disk.
struct ClaudeSession: Identifiable, Hashable {
    let id: URL          // path to the .jsonl file
    let projectName: String
    let lastModified: Date
    let lastSnippet: String?        // Last assistant text, ~120 chars
    let assistantFull: String?      // Last assistant text, ~500 chars (conversation card)
    let lastUserMessage: String?    // Last user message, ~200 chars
    let status: SessionStatus       // Working / awaiting approval / idle
    let cwd: String?                // Authoritative working dir from the jsonl entries
    let usage: UsageStats?          // Cumulative token usage + cost
    let gitBranch: String?          // Current git branch from the jsonl
    let currentTool: CurrentTool?   // Tool currently in flight (hook-driven)
    let subagents: [Subagent]       // Active/completed subagents (hook-driven)
    let todos: [TodoItem]           // Tasks from TodoWrite tool (hook-driven)

    /// Convenience for call sites that just want "is something happening".
    var isWorking: Bool { status == .working }

    /// True if the session was recently active (file modified < 20 min).
    /// Inactive sessions display as compact single-line rows.
    var isRecentlyActive: Bool {
        Date().timeIntervalSince(lastModified) < 20 * 60
    }

    /// Session UUID extracted from the jsonl filename, e.g.
    /// "2f627212-805d-4117-b41b-41dddd6f10a1" from "…/<uuid>.jsonl".
    /// Matches the `session_id` field in hook event payloads.
    var sessionID: String {
        id.deletingPathExtension().lastPathComponent
    }

    func with(status newStatus: SessionStatus) -> ClaudeSession {
        ClaudeSession(id: id, projectName: projectName, lastModified: lastModified,
                      lastSnippet: lastSnippet, assistantFull: assistantFull,
                      lastUserMessage: lastUserMessage, status: newStatus,
                      cwd: cwd, usage: usage, gitBranch: gitBranch,
                      currentTool: currentTool, subagents: subagents, todos: todos)
    }

    func with(currentTool newTool: CurrentTool?) -> ClaudeSession {
        ClaudeSession(id: id, projectName: projectName, lastModified: lastModified,
                      lastSnippet: lastSnippet, assistantFull: assistantFull,
                      lastUserMessage: lastUserMessage, status: status,
                      cwd: cwd, usage: usage, gitBranch: gitBranch,
                      currentTool: newTool, subagents: subagents, todos: todos)
    }

    func with(subagents newSubagents: [Subagent]) -> ClaudeSession {
        ClaudeSession(id: id, projectName: projectName, lastModified: lastModified,
                      lastSnippet: lastSnippet, assistantFull: assistantFull,
                      lastUserMessage: lastUserMessage, status: status,
                      cwd: cwd, usage: usage, gitBranch: gitBranch,
                      currentTool: currentTool, subagents: newSubagents, todos: todos)
    }

    func with(todos newTodos: [TodoItem]) -> ClaudeSession {
        ClaudeSession(id: id, projectName: projectName, lastModified: lastModified,
                      lastSnippet: lastSnippet, assistantFull: assistantFull,
                      lastUserMessage: lastUserMessage, status: status,
                      cwd: cwd, usage: usage, gitBranch: gitBranch,
                      currentTool: currentTool, subagents: subagents, todos: newTodos)
    }
}

/// Polls ~/.claude/projects/ every few seconds and publishes active sessions.
/// Active = a .jsonl session file modified within the last 5 minutes.
@MainActor
final class ClaudeWatcher: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Injected by AppDelegate so auto-expand can be suppressed when terminal is focused.
    weak var focusMonitor: FocusMonitor?

    /// Incremented on every event that should auto-expand. Using a
    /// counter instead of a session-id string guarantees SwiftUI's
    /// onChange fires even when the same session triggers twice.
    @Published var autoExpandCounter: Int = 0
    /// Which session to focus on when auto-expanding.
    var autoExpandFocusedSession: String?

    private var timer: Timer?
    private let activeWindow: TimeInterval = 48 * 60 * 60  // 48 hours — show all recent, UI handles compact display

    /// Cache parsed usage per session file. Keyed by URL, value includes the
    /// file mtime at parse time so we can invalidate cheaply.
    private var usageCache: [URL: (mtime: Date, stats: UsageStats)] = [:]

    /// Cache parsed tasks per session file (full-file scan, like usage).
    private var taskCache: [URL: (mtime: Date, tasks: [TodoItem])] = [:]

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

    /// Sessions known to be alive via SessionStart hook (not yet SessionEnd).
    /// Keyed by session UUID → jsonl path from the hook payload.
    private var hookAliveSessions: [String: String] = [:]

    /// Active subagents per parent session UUID.
    private var sessionSubagents: [String: [Subagent]] = [:]

    /// Tasks per session UUID, populated from TodoWrite/TaskCreate/TaskUpdate events.
    private var sessionTodos: [String: [TodoItem]] = [:]

    /// Counter for TaskCreate per session, so we can assign numeric IDs
    /// that match what TaskUpdate references.
    private var taskCounter: [String: Int] = [:]

    /// Pending subagent type/description from Agent PreToolUse, used when
    /// SubagentStart doesn't carry these fields directly.
    private var pendingAgentType: [String: String] = [:]
    private var pendingAgentDesc: [String: String] = [:]

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

    /// Check if a session is known alive via hook events.
    func isSessionHookAlive(_ sessionID: String) -> Bool {
        hookAliveSessions[sessionID] != nil
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

            // Filter: only UUID-named .jsonl (skip agent-*.jsonl subagent files)
            let jsonls = files.filter {
                $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("agent-")
            }

            let projectName = Self.decodeProjectName(dir.lastPathComponent)
            for jsonl in jsonls {
                let mod = Self.modDate(jsonl)
                let sessionID = jsonl.deletingPathExtension().lastPathComponent
                // Show if recently modified OR known alive via hooks.
                let isHookAlive = hookAliveSessions[sessionID] != nil
                guard mod > cutoff || isHookAlive else { continue }

                let tail = Self.parseTail(jsonl)

                // Classify status from the parsed tail. Fall back to the
                // previously known status on parse failures so we don't
                // flicker to idle when a giant entry overflows the buffer.
                let parseFailed = (tail.cwd == nil && tail.snippet == nil && tail.lastEntryKind == .unknown)
                let now = Date()
                var status: SessionStatus
                if parseFailed {
                    status = lastStatus[jsonl] ?? .idle
                } else {
                    status = Self.classifyStatus(tail: tail, fileModifiedAt: mod, now: now,
                                                 approvalIdleThreshold: approvalIdleThreshold)
                }
                // Detect interrupted sessions: snippet contains "[Request interrupted"
                if status == .idle,
                   let snippet = tail.snippet,
                   snippet.contains("[Request interrupted") || snippet.contains("Interrupted") {
                    status = .interrupted
                }

                // Detect transitions and notify the user when a session
                // finishes (busy → idle) or needs their attention.
                let previous = lastStatus[jsonl]
                if let previous, previous != status {
                    handleTransition(
                        from: previous, to: status,
                        projectName: projectName
                    )
                }
                lastStatus[jsonl] = status

                // Use cached values for expensive full-file scans.
                // When cache is stale, serve stale data and refresh async.
                let usage: UsageStats? = usageCache[jsonl]?.stats
                let fileTasks: [TodoItem] = taskCache[jsonl]?.tasks ?? []

                // Schedule background refresh for stale caches.
                let needsUsageRefresh = usageCache[jsonl]?.mtime != mod
                let needsTaskRefresh = taskCache[jsonl]?.mtime != mod
                if needsUsageRefresh || needsTaskRefresh {
                    let url = jsonl
                    let mtime = mod
                    DispatchQueue.global(qos: .utility).async {
                        let newUsage = needsUsageRefresh ? Self.parseUsage(url) : nil
                        let newTasks = needsTaskRefresh ? Self.parseTasks(url) : nil
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if needsUsageRefresh, let u = newUsage {
                                self.usageCache[url] = (mtime, u)
                            }
                            if needsTaskRefresh {
                                self.taskCache[url] = (mtime, newTasks ?? [])
                            }
                            self.rebuildPublishedSessions()
                        }
                    }
                }

                let todos = tail.todos.isEmpty ? fileTasks : tail.todos

                found.append(ClaudeSession(
                    id: jsonl,
                    projectName: projectName,
                    lastModified: mod,
                    lastSnippet: tail.snippet,
                    assistantFull: tail.assistantFull,
                    lastUserMessage: tail.lastUserMessage,
                    status: status,
                    cwd: tail.cwd,
                    usage: usage,
                    gitBranch: tail.branch,
                    currentTool: nil,
                    subagents: [],
                    todos: todos
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
        taskCache = taskCache.filter { activeIDs.contains($0.key) }
        lastStatus = lastStatus.filter { activeIDs.contains($0.key) }
        hookStatus = hookStatus.filter { activeSessionIDs.contains($0.key) }
        currentTools = currentTools.filter { activeSessionIDs.contains($0.key) }
        sessionSubagents = sessionSubagents.filter { activeSessionIDs.contains($0.key) }
        sessionTodos = sessionTodos.filter { activeSessionIDs.contains($0.key) }
        taskCounter = taskCounter.filter { activeSessionIDs.contains($0.key) }
    }

    // MARK: - Hook-driven updates

    /// Called by the HookServer whenever Claude Code fires an event.
    /// Updates the status of the matching session immediately (no disk
    /// scan) and republishes so the UI reflects the change with
    /// sub-100ms latency.
    func applyHookEvent(_ event: HookServer.Event) {
        guard let sid = event.sessionId, !sid.isEmpty else { return }

        // Track alive sessions via SessionStart/SessionEnd hooks.
        // This keeps sessions visible even when their jsonl file hasn't
        // been modified recently (idle sessions waiting for user input).
        if event.hookEventName == "SessionStart" {
            if let path = event.transcriptPath {
                hookAliveSessions[sid] = path
            }
        } else if event.hookEventName == "SessionEnd" {
            hookAliveSessions.removeValue(forKey: sid)
        }
        // Any hook event from a session means it's alive.
        if hookAliveSessions[sid] == nil, let path = event.transcriptPath {
            hookAliveSessions[sid] = path
        }

        // Track the in-flight tool per session so the UI can show a
        // "Bash: git show …" badge while it's running.
        switch event.hookEventName {
        case "PreToolUse":
            if let name = event.toolName {
                let desc = event.toolInput?["description"] as? String
                let detail = Self.describeToolInput(toolName: name, input: event.toolInput)
                CNLog.tool("PreToolUse: \(name) \(detail ?? "") session=\(sid)")
                currentTools[sid] = CurrentTool(
                    name: name,
                    detail: detail,
                    description: desc,
                    diffPreview: Self.extractDiffPreview(toolName: name, input: event.toolInput),
                    hasAlwaysAllow: false
                )
            }
        case "PostToolUse":
            CNLog.tool("PostToolUse: \(event.toolName ?? "-") session=\(sid)")
            break  // Keep showing last tool
        case "Stop", "SessionEnd":
            break  // Keep showing last tool even when idle
        default:
            break
        }

        // Track subagents spawned within each session.
        switch event.hookEventName {
        case "SubagentStart":
            let subId = event.raw["subagent_id"] as? String ?? UUID().uuidString
            let agentType = event.raw["subagent_type"] as? String
                ?? event.raw["agent_type"] as? String
                ?? event.toolInput?["subagent_type"] as? String
                ?? pendingAgentType[sid]
                ?? "agent"
            let desc = event.raw["description"] as? String
                ?? event.toolInput?["description"] as? String
                ?? pendingAgentDesc[sid]
            CNLog.sub("START: id=\(subId) type=\(agentType) desc=\(desc ?? "-") session=\(sid)")
            pendingAgentType.removeValue(forKey: sid)
            pendingAgentDesc.removeValue(forKey: sid)
            let sub = Subagent(
                id: subId,
                agentType: agentType,
                description: desc,
                startedAt: Date(),
                status: .running,
                currentTool: nil
            )
            var subs = sessionSubagents[sid] ?? []
            subs.append(sub)
            sessionSubagents[sid] = subs

        case "SubagentStop":
            let subId = event.raw["subagent_id"] as? String ?? ""
            CNLog.sub("STOP: id=\(subId) session=\(sid)")
            if var subs = sessionSubagents[sid] {
                if let idx = subs.firstIndex(where: { $0.id == subId }) {
                    subs[idx].status = .done
                    subs[idx].currentTool = nil
                    sessionSubagents[sid] = subs
                }
            }

        case "SessionEnd":
            sessionSubagents[sid] = nil

        default:
            break
        }

        // When Agent tool fires PreToolUse, capture type/description for
        // the upcoming SubagentStart (which may lack these fields).
        if event.hookEventName == "PreToolUse",
           let name = event.toolName, (name == "Agent" || name == "Task") {
            if let t = event.toolInput?["subagent_type"] as? String { pendingAgentType[sid] = t }
            if let d = event.toolInput?["description"] as? String { pendingAgentDesc[sid] = d }
        }

        // Attribute tool events to the active running subagent so the UI
        // shows what each subagent is doing (e.g. "└ $ grep ...").
        if event.hookEventName == "PreToolUse",
           let name = event.toolName, name != "Agent" && name != "Task",
           var subs = sessionSubagents[sid],
           let idx = subs.lastIndex(where: { $0.status == .running }) {
            let desc = event.toolInput?["description"] as? String
            subs[idx].currentTool = CurrentTool(
                name: name,
                detail: Self.describeToolInput(toolName: name, input: event.toolInput),
                description: desc,
                diffPreview: nil,
                hasAlwaysAllow: false
            )
            sessionSubagents[sid] = subs
        }
        if event.hookEventName == "PostToolUse",
           var subs = sessionSubagents[sid],
           let idx = subs.lastIndex(where: { $0.status == .running }) {
            subs[idx].currentTool = nil
            sessionSubagents[sid] = subs
        }

        // Track task tools to populate the tasks section.
        // Supports both TodoWrite (full list) and TaskCreate/TaskUpdate (incremental).
        if event.hookEventName == "PostToolUse" || event.hookEventName == "PreToolUse" {
            let name = event.toolName ?? ""
            let input = event.toolInput ?? [:]

            if name == "TodoWrite" || name == "TodoWriteTool",
               let todosRaw = input["todos"] as? [[String: Any]] {
                let todos = todosRaw.compactMap { obj -> TodoItem? in
                    guard let content = obj["content"] as? String,
                          let statusStr = obj["status"] as? String else { return nil }
                    let status: TodoStatus
                    switch statusStr {
                    case "completed": status = .completed
                    case "in_progress": status = .inProgress
                    default: status = .pending
                    }
                    return TodoItem(id: content, content: content, status: status)
                }
                if !todos.isEmpty {
                    CNLog.task("TodoWrite: \(todos.count) items session=\(sid)")
                    sessionTodos[sid] = todos
                }
            }

            if name == "TaskCreate" || name == "TaskUpdate" {
                CNLog.task("\(name) session=\(sid)")
                // Find the session URL to invalidate its task cache.
                if let url = baseSessions.values.first(where: { $0.sessionID == sid })?.id {
                    taskCache.removeValue(forKey: url)
                }
            }
        }

        // Clear todos on session end.
        if event.hookEventName == "SessionEnd" {
            sessionTodos[sid] = nil
            taskCounter[sid] = nil
        }

        // PermissionRequest also carries tool_input — update currentTools
        // so the diff preview is available even if PreToolUse was missed.
        if event.hookEventName == "PermissionRequest", let name = event.toolName {
            let desc = event.toolInput?["description"] as? String
            let hasAlways = !event.permissionSuggestions.isEmpty
            CNLog.perm("PermissionRequest: tool=\(name) hasAlwaysAllow=\(hasAlways) session=\(sid)")
            currentTools[sid] = CurrentTool(
                name: name,
                detail: Self.describeToolInput(toolName: name, input: event.toolInput),
                description: desc,
                diffPreview: Self.extractDiffPreview(toolName: name, input: event.toolInput),
                hasAlwaysAllow: hasAlways
            )
        }

        // Auto-expand the notch panel focused on THIS session.
        // PermissionRequest: ALWAYS expand (user must respond).
        // Stop (completion): suppress only when THIS session's terminal
        // tab is active (user already sees the output).
        if event.hookEventName == "PermissionRequest" {
            CNLog.ui("auto-expand: PermissionRequest session=\(sid)")
            autoExpandFocusedSession = sid
            autoExpandCounter += 1
        } else if event.hookEventName == "Stop" {
            let sessionCwd = baseSessions.values.first(where: { $0.sessionID == sid })?.cwd
            let isThisSessionFocused = focusMonitor?.isTerminalFocused == true
                && sessionCwd != nil
                && SessionLauncher.isSessionTerminalActive(cwd: sessionCwd!)
            if !isThisSessionFocused {
                CNLog.ui("auto-expand: Stop session=\(sid) (terminal not focused)")
                autoExpandFocusedSession = sid
                autoExpandCounter += 1
            } else {
                CNLog.ui("suppressed: Stop session=\(sid) (terminal focused)")
            }
        }

        guard let newStatus = Self.statusFromHookEvent(event.hookEventName) else {
            rebuildPublishedSessions()
            return
        }

        let previousStatus = hookStatus[sid]?.status

        // Don't let Notification/SubagentStart/SubagentStop override
        // awaitingApproval — a pending permission prompt is still open.
        if previousStatus == .awaitingApproval && newStatus == .working {
            let isRealWork = ["UserPromptSubmit", "PreToolUse", "PostToolUse"].contains(event.hookEventName)
            if !isRealWork {
                CNLog.state("blocked \(event.hookEventName) from overriding awaitingApproval session=\(sid)")
                rebuildPublishedSessions()
                return
            }
        }

        hookStatus[sid] = (newStatus, Date())

        if previousStatus != newStatus {
            CNLog.state("\(previousStatus?.rawValue ?? "nil") → \(newStatus.rawValue) session=\(sid)")
        }

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
    static func describeToolInput(toolName: String, input: [String: Any]?) -> String? {
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

    /// Extract a diff preview from tool_input for Edit/Write tools.
    /// Returns nil for tools that don't produce code changes.
    private static func extractDiffPreview(toolName: String, input: [String: Any]?) -> DiffPreview? {
        guard let input else { return nil }
        switch toolName {
        case "Edit", "MultiEdit":
            guard let filePath = input["file_path"] as? String else { return nil }
            let old = (input["old_string"] as? String).map { String($0.prefix(500)) }
            let new = (input["new_string"] as? String).map { String($0.prefix(500)) }
            guard old != nil || new != nil else { return nil }
            return DiffPreview(filePath: filePath, oldString: old, newString: new, content: nil)
        case "Write", "NotebookEdit":
            guard let filePath = input["file_path"] as? String else { return nil }
            let content = (input["content"] as? String).map { String($0.prefix(1000)) }
            return DiffPreview(filePath: filePath, oldString: nil, newString: nil, content: content)
        default:
            return nil
        }
    }

    /// Map a hook event name to the session status it implies.
    /// Events we don't care about return nil (no update).
    private static func statusFromHookEvent(_ name: String) -> SessionStatus? {
        switch name {
        case "UserPromptSubmit", "PreToolUse":
            return .working
        case "PostToolUse":
            return .working
        case "PermissionRequest":
            return .awaitingApproval
        case "PreCompact":
            return .compacting
        case "Stop", "SessionEnd":
            return .idle
        // Any other event clears stuck compacting/approval states.
        case "Notification", "SubagentStart", "SubagentStop":
            return .working
        default:
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
            if let hook = hookStatus[session.sessionID] {
                let age = now.timeIntervalSince(hook.at)
                // idle/interrupted from Stop/SessionEnd is a final verdict —
                // never expire it so the polling fallback can't flip it back
                // to working based on a stale tool_use in the JSONL tail.
                let isFinal = hook.status == .idle || hook.status == .interrupted
                let ttl = isFinal ? Double.infinity : (hook.status == .compacting ? 300.0 : hookStatusTTL)
                if age < ttl {
                    result = result.with(status: hook.status)
                } else {
                    CNLog.state("hookStatus expired: \(hook.status.rawValue) age=\(Int(age))s session=\(session.sessionID)")
                }
            }
            if let tool = currentTools[session.sessionID] {
                result = result.with(currentTool: tool)
            }
            if let subs = sessionSubagents[session.sessionID], !subs.isEmpty {
                result = result.with(subagents: subs)
            }
            if let todos = sessionTodos[session.sessionID], !todos.isEmpty {
                result = result.with(todos: todos)
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
            return .working

        case .assistantToolUse:
            let idleFor = now.timeIntervalSince(fileModifiedAt)
            return idleFor > approvalIdleThreshold ? .awaitingApproval : .working

        case .assistantEndTurn:
            return .idle

        case .userMessage:
            return .working

        case .compactBoundary:
            // Compact boundary means context was compacted. If the file is
            // still being written to (entries arriving after the boundary),
            // Claude is actively compacting. Use a generous window since
            // compaction can take several minutes on large contexts.
            let idleFor = now.timeIntervalSince(fileModifiedAt)
            return idleFor < 300 ? .compacting : .idle

        case .unknown:
            return .idle
        }
    }

    // MARK: - Notifications

    /// React to a session status change. Fires a user notification and
    /// plays a sound from the Clean Chimes pack.
    private func handleTransition(
        from previous: SessionStatus,
        to current: SessionStatus,
        projectName: String
    ) {
        // Completion: something was happening, now idle.
        if previous.isBusy && current == .idle {
            postNotification(title: "Claude finished", body: projectName, sound: false)
            return
        }

        // New approval request (either fresh start or transition from working).
        if current == .awaitingApproval && previous != .awaitingApproval {
            postNotification(title: "Claude needs approval", body: projectName, sound: false)
        }
    }

    private func postNotification(title: String, body: String, sound: Bool) {
        // UNUserNotificationCenter can silently fail for LSUIElement apps
        // that haven't been granted permission. Fall back to osascript
        // which is proven to work on this system.
        let soundClause = sound ? " sound name \"Hero\"" : ""
        let escaped = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped)\" with title \"\(title)\"\(soundClause)"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
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
        case compactBoundary     // system compact_boundary entry
        case unknown             // parse failed or nothing matched
    }

    /// Everything parseTail extracts from the session file tail.
    struct TailParseResult {
        let snippet: String?               // assistant text, ~120 chars
        let assistantFull: String?          // assistant text, ~500 chars (for conversation card)
        let lastUserMessage: String?        // user's last message, ~200 chars
        let cwd: String?
        let branch: String?
        let lastEntryKind: LastEntryKind
        let todos: [TodoItem]              // tasks from most recent TodoWrite
    }

    /// Read the tail of a .jsonl session file and derive a `TailParseResult`.
    /// Reads up to 512 KB to comfortably contain large tool results; entries
    /// bigger than that are handled upstream by keeping the previous status
    /// on parse failure.
    private static func parseTail(_ url: URL) -> TailParseResult {
        let empty = TailParseResult(snippet: nil, assistantFull: nil, lastUserMessage: nil, cwd: nil, branch: nil, lastEntryKind: .unknown, todos: [])

        guard let handle = try? FileHandle(forReadingFrom: url) else { return empty }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 2_097_152  // 2 MB — large enough to find TaskCreate entries
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let start = fileSize > chunkSize ? fileSize - chunkSize : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()

        guard let text = String(data: data, encoding: .utf8) else { return empty }

        // Parse lines in reverse. The very first (last) line may be a partial
        // write from Claude Code currently flushing, so tolerate parse failures.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        var snippet: String? = nil
        var assistantFull: String? = nil
        var lastUserMessage: String? = nil
        var cwd: String? = nil
        var branch: String? = nil
        var lastEntryKind: LastEntryKind = .unknown
        var lastEntryResolved = false
        var todos: [TodoItem] = []
        var todosFound = false

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

            let entryType = obj["type"] as? String

            // Capture the most recent assistant text content for snippets.
            if snippet == nil, entryType == "assistant",
               let msg = obj["message"] as? [String: Any],
               let contents = msg["content"] as? [[String: Any]] {
                for c in contents {
                    if (c["type"] as? String) == "text",
                       let txt = c["text"] as? String {
                        let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            // Snippet: single line for row display
                            snippet = String(trimmed.replacingOccurrences(of: "\n", with: " ").prefix(120))
                            // Full: preserve newlines for markdown rendering in card
                            assistantFull = String(trimmed.prefix(800))
                        }
                        break
                    }
                }
            }

            // Capture the most recent user message text.
            if lastUserMessage == nil, entryType == "user",
               let msg = obj["message"] as? [String: Any],
               let content = msg["content"] {
                // User messages can be a string or an array of content blocks.
                let text: String?
                if let str = content as? String {
                    text = str
                } else if let blocks = content as? [[String: Any]] {
                    text = blocks.compactMap { b -> String? in
                        guard (b["type"] as? String) == "text" else { return nil }
                        return b["text"] as? String
                    }.first
                } else {
                    text = nil
                }
                if let t = text {
                    var cleaned = t.replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.count > 200 { cleaned = String(cleaned.prefix(200)) }
                    if !cleaned.isEmpty { lastUserMessage = cleaned }
                }
            }

            // Find most recent TodoWrite (full list replacement).
            if !todosFound, entryType == "assistant",
               let msg = obj["message"] as? [String: Any],
               let contents = msg["content"] as? [[String: Any]] {
                for c in contents {
                    if (c["type"] as? String) == "tool_use",
                       let name = c["name"] as? String,
                       (name == "TodoWrite" || name == "TodoWriteTool"),
                       let input = c["input"] as? [String: Any],
                       let rawTodos = input["todos"] as? [[String: Any]] {
                        todos = rawTodos.compactMap { t -> TodoItem? in
                            guard let content = t["content"] as? String,
                                  let st = t["status"] as? String else { return nil }
                            let status: TodoStatus
                            switch st {
                            case "completed": status = .completed
                            case "in_progress": status = .inProgress
                            default: status = .pending
                            }
                            return TodoItem(id: content, content: content, status: status)
                        }
                        todosFound = true
                        break
                    }
                }
            }

            let allFound = lastEntryResolved && snippet != nil && cwd != nil
                && branch != nil && lastUserMessage != nil && todosFound
            if allFound { break }
        }

        // If no TodoWrite found, try forward scan for TaskCreate/TaskUpdate (incremental).
        if !todosFound {
            var taskMap: [String: (content: String, status: TodoStatus)] = [:]
            var nextId = 1
            for line in lines {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let contents = msg["content"] as? [[String: Any]]
                else { continue }
                for c in contents {
                    guard (c["type"] as? String) == "tool_use",
                          let name = c["name"] as? String,
                          let input = c["input"] as? [String: Any] else { continue }
                    if name == "TaskCreate", let subject = input["subject"] as? String {
                        let id = "\(nextId)"
                        taskMap[id] = (subject, .pending)
                        nextId += 1
                    }
                    if name == "TaskUpdate",
                       let taskId = input["taskId"] as? String,
                       let statusStr = input["status"] as? String {
                        if var existing = taskMap[taskId] {
                            switch statusStr {
                            case "completed": existing.status = .completed
                            case "in_progress": existing.status = .inProgress
                            case "deleted": taskMap.removeValue(forKey: taskId); continue
                            default: existing.status = .pending
                            }
                            taskMap[taskId] = existing
                        }
                    }
                }
            }
            if !taskMap.isEmpty {
                todos = taskMap.sorted(by: { Int($0.key) ?? 0 < Int($1.key) ?? 0 })
                    .map { TodoItem(id: $0.key, content: $0.value.content, status: $0.value.status) }
            }
        }

        return TailParseResult(
            snippet: snippet,
            assistantFull: assistantFull,
            lastUserMessage: lastUserMessage,
            cwd: cwd,
            branch: branch,
            lastEntryKind: lastEntryKind,
            todos: todos
        )
    }

    /// Map a single parsed jsonl entry to a LastEntryKind. Prefers the
    /// explicit `stop_reason` field over content-type heuristics.
    private static func classifyEntry(_ obj: [String: Any]) -> LastEntryKind {
        guard let type = obj["type"] as? String else { return .unknown }

        if type == "system", (obj["subtype"] as? String) == "compact_boundary" {
            return .compactBoundary
        }

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

    /// Scan the full .jsonl for TaskCreate/TaskUpdate/TodoWrite to build
    /// the current task list. Reads the entire file but only parses lines
    /// containing task tool names (fast string filter before JSON parse).
    private static func parseTasks(_ url: URL) -> [TodoItem] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var taskMap: [String: (content: String, status: TodoStatus)] = [:]
        var latestTodoWrite: [TodoItem]? = nil
        // Map tool_use_id → subject for correlating TaskCreate with its tool_result.
        var pendingCreates: [String: String] = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Fast pre-filter: skip lines that can't contain task tools.
            let hasTask = line.contains("TaskCreate") || line.contains("TaskUpdate")
                || line.contains("TodoWrite") || line.contains("Task #")
            guard hasTask else { continue }

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let entryType = obj["type"] as? String
            let msg = obj["message"] as? [String: Any]
            let contents: [[String: Any]]?
            if let c = msg?["content"] as? [[String: Any]] {
                contents = c
            } else {
                contents = nil
            }

            // Assistant entries: tool_use calls for TaskCreate/TaskUpdate/TodoWrite
            if entryType == "assistant", let contents {
                for c in contents {
                    guard (c["type"] as? String) == "tool_use",
                          let name = c["name"] as? String,
                          let input = c["input"] as? [String: Any] else { continue }

                    if (name == "TodoWrite" || name == "TodoWriteTool"),
                       let rawTodos = input["todos"] as? [[String: Any]] {
                        latestTodoWrite = rawTodos.compactMap { t -> TodoItem? in
                            guard let content = t["content"] as? String,
                                  let st = t["status"] as? String else { return nil }
                            let status: TodoStatus
                            switch st {
                            case "completed": status = .completed
                            case "in_progress": status = .inProgress
                            default: status = .pending
                            }
                            return TodoItem(id: content, content: content, status: status)
                        }
                    }

                    if name == "TaskCreate", let subject = input["subject"] as? String,
                       let toolUseId = c["id"] as? String {
                        pendingCreates[toolUseId] = subject
                    }

                    if name == "TaskUpdate",
                       let taskId = input["taskId"] as? String,
                       let statusStr = input["status"] as? String {
                        if var existing = taskMap[taskId] {
                            switch statusStr {
                            case "completed": existing.status = .completed
                            case "in_progress": existing.status = .inProgress
                            case "deleted": taskMap.removeValue(forKey: taskId); continue
                            default: existing.status = .pending
                            }
                            taskMap[taskId] = existing
                        }
                    }
                }
            }

            // User entries: tool_result containing "Task #N created successfully"
            // to get the real numeric ID assigned by Claude Code.
            if entryType == "user", let contents {
                for c in contents {
                    guard (c["type"] as? String) == "tool_result",
                          let toolUseId = c["tool_use_id"] as? String,
                          let subject = pendingCreates.removeValue(forKey: toolUseId)
                    else { continue }
                    // Content can be a string or array of text blocks.
                    let resultText: String?
                    if let s = c["content"] as? String {
                        resultText = s
                    } else if let blocks = c["content"] as? [[String: Any]] {
                        resultText = blocks.compactMap { $0["text"] as? String }.first
                    } else {
                        resultText = nil
                    }
                    // Parse "Task #N created successfully" to extract N.
                    if let text = resultText,
                       let range = text.range(of: #"Task #(\d+)"#, options: .regularExpression) {
                        let match = text[range]
                        let numStr = match.drop(while: { !$0.isNumber })
                        let taskId = String(numStr)
                        taskMap[taskId] = (subject, .pending)
                    }
                }
            }
        }

        // Prefer TodoWrite (full snapshot) over incremental TaskCreate/TaskUpdate.
        if let todos = latestTodoWrite, !todos.isEmpty {
            return todos
        }

        guard !taskMap.isEmpty else { return [] }
        return taskMap.sorted(by: { Int($0.key) ?? 0 < Int($1.key) ?? 0 })
            .map { TodoItem(id: $0.key, content: $0.value.content, status: $0.value.status) }
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
