import Foundation

/// Token usage snapshot for a session. `contextTokens` mirrors what the
/// Claude Code statusline shows: the current context-window occupancy
/// drawn from the most recent assistant message.
struct UsageStats: Hashable {
    let contextTokens: Int    // last message: input + cache_read + cache_create
    let outputTokens: Int     // cumulative output across the whole session
}

/// A single active Claude Code session discovered on disk.
struct ClaudeSession: Identifiable, Hashable {
    let id: URL          // path to the .jsonl file
    let projectName: String
    let lastModified: Date
    let lastSnippet: String?   // Last assistant text, cleaned + truncated
    let isWorking: Bool        // True if Claude is currently processing
    let cwd: String?           // Authoritative working dir from the jsonl entries
    let usage: UsageStats?     // Cumulative token usage + cost
}

/// Polls ~/.claude/projects/ every few seconds and publishes active sessions.
/// Active = a .jsonl session file modified within the last 5 minutes.
@MainActor
final class ClaudeWatcher: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    private var timer: Timer?
    private let activeWindow: TimeInterval = 5 * 60  // 5 minutes

    /// Cache parsed usage per session file. Keyed by URL, value includes the
    /// file mtime at parse time so we can invalidate cheaply.
    private var usageCache: [URL: (mtime: Date, stats: UsageStats)] = [:]

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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
                let (snippet, working, cwd) = Self.parseTail(latest)

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
                    lastSnippet: snippet,
                    isWorking: working,
                    cwd: cwd,
                    usage: usage
                ))
            }
        }

        sessions = found.sorted { $0.lastModified > $1.lastModified }

        // Prune cache entries for sessions that are no longer active.
        let activeIDs = Set(found.map { $0.id })
        usageCache = usageCache.filter { activeIDs.contains($0.key) }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Read the tail of a .jsonl session file and derive:
    ///   - lastSnippet: the most recent assistant text content (cleaned, truncated)
    ///   - isWorking: whether Claude is mid-turn (last entry is user, or assistant's
    ///     last content item is a tool_use awaiting a tool_result)
    ///   - cwd: the working directory recorded in the most recent entry (authoritative)
    /// Reads only the final ~16KB to stay cheap on large sessions.
    private static func parseTail(_ url: URL) -> (snippet: String?, isWorking: Bool, cwd: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (nil, false, nil)
        }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 16_384
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let start = fileSize > chunkSize ? fileSize - chunkSize : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()

        guard let text = String(data: data, encoding: .utf8) else {
            return (nil, false, nil)
        }

        // Parse lines in reverse. The very first (last) line may be a partial write
        // from Claude Code currently flushing, so tolerate parse failures.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        var lastParsed: [String: Any]? = nil
        var snippet: String? = nil
        var cwd: String? = nil

        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if lastParsed == nil {
                lastParsed = obj
            }

            // The cwd field is on every entry; grab it from the first successfully
            // parsed (most recent) line.
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
                cwd = c
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

            if lastParsed != nil && snippet != nil && cwd != nil { break }
        }

        // Working = last speaker is user (Claude hasn't replied yet),
        // or assistant's final content item is a tool_use (tool still running).
        var isWorking = false
        if let entry = lastParsed, let type = entry["type"] as? String {
            if type == "user" {
                isWorking = true
            } else if type == "assistant",
                      let msg = entry["message"] as? [String: Any],
                      let contents = msg["content"] as? [[String: Any]],
                      let last = contents.last,
                      (last["type"] as? String) == "tool_use" {
                isWorking = true
            }
        }

        return (snippet, isWorking, cwd)
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
