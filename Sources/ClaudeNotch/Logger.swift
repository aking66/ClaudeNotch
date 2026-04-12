import Foundation

/// Structured file logger for ClaudeNotch debugging.
/// Writes to /tmp/claudenotch.log with timestamps and categories.
///
/// Categories:
///   HOOK    — raw hook events arriving from the bridge
///   PERM    — permission requests, approvals, denials
///   STATE   — session status transitions (working → idle, etc.)
///   UI      — panel expand/collapse, hover, auto-expand
///   TOOL    — current tool tracking (PreToolUse / PostToolUse)
///   SUB     — subagent start/stop
///   TASK    — todo/task updates
///   FOCUS   — terminal focus detection, app switches
///   SESSION — session lifecycle (discovered, alive, removed)
///   USAGE   — usage fetcher updates
///   SOUND   — sound playback events
///   SIM     — diagnostic simulation scenarios
enum CNLog {
    private static let logFile = "/tmp/claudenotch.log"
    private static let maxFileSize = 1_000_000    // 1 MB
    private static let truncateTarget = 500_000   // keep last 500 KB

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Session name registry

    /// Maps session UUIDs to readable project names for log output.
    /// e.g. "ceb6a1c3-4fe2-..." → "youtube-ai-scout"
    private static var sessionNames: [String: String] = [:]

    /// Register a session's project name so logs show readable labels.
    /// Names from hooks (real folder names) take priority over polling
    /// (decoded path names that mangle hyphens into slashes).
    static func registerSession(id: String, name: String, fromHook: Bool = false) {
        if fromHook || sessionNames[id] == nil {
            sessionNames[id] = name
        }
    }

    /// Returns a short readable label: "project(abcd)" or "abcd" if unknown.
    static func sessionLabel(_ id: String) -> String {
        let short = String(id.prefix(4))
        if let name = sessionNames[id] {
            return "\(name)(\(short))"
        }
        return short
    }

    // MARK: - Category methods

    static func log(_ message: String)     { write("INFO", message) }
    static func hook(_ message: String)    { write("HOOK", message) }
    static func perm(_ message: String)    { write("PERM", message) }
    static func state(_ message: String)   { write("STATE", message) }
    static func ui(_ message: String)      { write("UI", message) }
    static func tool(_ message: String)    { write("TOOL", message) }
    static func sub(_ message: String)     { write("SUB", message) }
    static func task(_ message: String)    { write("TASK", message) }
    static func focus(_ message: String)   { write("FOCUS", message) }
    static func session(_ message: String) { write("SESSION", message) }
    static func usage(_ message: String)   { write("USAGE", message) }
    static func sound(_ message: String)   { write("SOUND", message) }
    static func sim(_ message: String)     { write("SIM", message) }

    // MARK: - Writer with rotation

    private static func write(_ category: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: logFile) {
            // Rotate if file exceeds max size.
            if let attrs = try? fm.attributesOfItem(atPath: logFile),
               let size = attrs[.size] as? Int, size > maxFileSize {
                rotateLog()
            }
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: logFile))
        }
    }

    /// Truncate the log file to the last `truncateTarget` bytes.
    private static func rotateLog() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logFile)),
              data.count > truncateTarget else { return }
        let tail = data.suffix(truncateTarget)
        // Find first newline in the tail to avoid partial lines.
        if let newlineIdx = tail.firstIndex(of: 0x0A) {
            let clean = tail.suffix(from: tail.index(after: newlineIdx))
            let header = "[LOG ROTATED — kept last \(clean.count / 1024) KB]\n".data(using: .utf8) ?? Data()
            try? (header + clean).write(to: URL(fileURLWithPath: logFile))
        }
    }
}
