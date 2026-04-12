import Foundation

/// Structured file logger for ClaudeNotch debugging.
/// Writes to /tmp/claudenotch.log with timestamps and categories.
///
/// Categories:
///   HOOK   — raw hook events arriving from the bridge
///   PERM   — permission requests, approvals, denials
///   STATE  — session status transitions (working → idle, etc.)
///   UI     — panel expand/collapse, hover, auto-expand
///   TOOL   — current tool tracking (PreToolUse / PostToolUse)
///   SUB    — subagent start/stop
///   TASK   — todo/task updates
///   FOCUS  — terminal focus detection, suppression decisions
///   TTY    — TTY discovery from bridge
///   USAGE  — usage fetcher updates
///   SOUND  — sound playback events
enum CNLog {
    private static let logFile = "/tmp/claudenotch.log"
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        write("INFO", message)
    }

    static func hook(_ message: String) {
        write("HOOK", message)
    }

    static func perm(_ message: String) {
        write("PERM", message)
    }

    static func state(_ message: String) {
        write("STATE", message)
    }

    static func ui(_ message: String) {
        write("UI", message)
    }

    static func tool(_ message: String) {
        write("TOOL", message)
    }

    static func sub(_ message: String) {
        write("SUB", message)
    }

    static func task(_ message: String) {
        write("TASK", message)
    }

    static func focus(_ message: String) {
        write("FOCUS", message)
    }

    static func usage(_ message: String) {
        write("USAGE", message)
    }

    static func sound(_ message: String) {
        write("SOUND", message)
    }

    private static func write(_ category: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logFile))
            }
        }
    }
}
