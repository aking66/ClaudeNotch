import AppKit
import Foundation

/// Resolves a ClaudeSession to a running Terminal.app tab and brings it to front.
/// Falls back to opening a fresh Terminal window at the project's cwd if no live
/// claude process can be matched to the session.
@MainActor
enum SessionLauncher {

    static func open(_ session: ClaudeSession) {
        let targetCwd = resolveCwd(for: session)
        let sid = session.sessionID

        CNLog.log("JUMP: session=\(sid) cwd=\(targetCwd)")

        // Try 1: use the known TTY from hook events (most precise).
        if let server = (NSApp.delegate as? AppDelegate)?.hookServer {
            let allTTYs = server.sessionTTY
            CNLog.log("JUMP: sessionTTY map has \(allTTYs.count) entries: \(allTTYs)")
            if let tty = allTTYs[sid] {
                CNLog.log("JUMP: found hook TTY=\(tty) for session \(sid)")
                if focusTerminalTab(tty: tty) {
                    CNLog.log("JUMP: SUCCESS via hook TTY")
                    return
                }
                CNLog.log("JUMP: hook TTY failed to focus")
            } else {
                CNLog.log("JUMP: no hook TTY for session \(sid)")
            }
        }

        // Try 2: find by TTY of a claude process with matching CWD.
        CNLog.log("JUMP: trying findTTY for cwd=\(targetCwd)")
        if let tty = findTTY(forCwd: targetCwd) {
            CNLog.log("JUMP: found process TTY=\(tty)")
            if focusTerminalTab(tty: tty) {
                CNLog.log("JUMP: SUCCESS via process TTY")
                return
            }
            CNLog.log("JUMP: process TTY failed to focus")
        } else {
            CNLog.log("JUMP: no process TTY found")
        }

        // Fallback: open a fresh Terminal window at the project directory.
        CNLog.log("JUMP: FALLBACK opening new terminal at \(targetCwd)")
        openNewTerminal(at: targetCwd)
    }

    // MARK: - CWD resolution

    /// Prefer the cwd from the jsonl; fall back to expanding the decoded project name.
    private static func resolveCwd(for session: ClaudeSession) -> String {
        if let cwd = session.cwd, !cwd.isEmpty {
            return cwd
        }
        // projectName looks like "~/ClaudeNotch". Expand to an absolute path.
        let expanded = (session.projectName as NSString).expandingTildeInPath
        return expanded
    }

    // MARK: - Process matching

    /// Walk live `claude` CLI processes, return the TTY of the one whose cwd matches.
    /// Returns a TTY short name like "ttys016" (no "/dev/" prefix).
    private static func findTTY(forCwd targetCwd: String) -> String? {
        // ps emits columns: pid, tty, command (full args).
        guard let psOutput = run("/bin/ps", ["-axo", "pid=,tty=,command="]) else {
            return nil
        }

        let normalizedTarget = (targetCwd as NSString).standardizingPath

        for rawLine in psOutput.split(separator: "\n") {
            guard let (pid, tty, command) = parsePsLine(String(rawLine)) else { continue }

            // Match the interactive `claude` CLI. In practice it appears as
            // `node /path/to/.npm-global/bin/claude` so we check if the
            // command contains "/bin/claude" but NOT "browser-agent" or
            // "ClaudeNotch" or "vibe-island".
            let isClaudeCLI = (command == "claude" || command.hasPrefix("claude "))
                || (command.contains("/bin/claude") && !command.contains("browser-agent")
                    && !command.contains("ClaudeNotch") && !command.contains("vibe-island"))
            guard isClaudeCLI else { continue }
            guard tty != "?" && tty != "??" else { continue }

            if let pidCwd = cwdOfProcess(pid: pid) {
                let normalizedPidCwd = (pidCwd as NSString).standardizingPath
                if normalizedPidCwd == normalizedTarget {
                    return tty
                }
            }
        }

        return nil
    }

    /// Parse a single `ps -o pid=,tty=,command=` line into (pid, tty, command).
    /// Handles arbitrary whitespace between columns.
    private static func parsePsLine(_ line: String) -> (pid: Int, tty: String, command: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Column 1: pid
        guard let pidEnd = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let pidStr = String(trimmed[..<pidEnd])
        guard let pid = Int(pidStr) else { return nil }

        // Skip whitespace
        var cursor = trimmed.index(after: pidEnd)
        while cursor < trimmed.endIndex && trimmed[cursor].isWhitespace {
            cursor = trimmed.index(after: cursor)
        }
        guard cursor < trimmed.endIndex else { return nil }

        // Column 2: tty
        guard let ttyEnd = trimmed[cursor...].firstIndex(where: { $0.isWhitespace }) else { return nil }
        let tty = String(trimmed[cursor..<ttyEnd])

        // Skip whitespace
        var cmdStart = trimmed.index(after: ttyEnd)
        while cmdStart < trimmed.endIndex && trimmed[cmdStart].isWhitespace {
            cmdStart = trimmed.index(after: cmdStart)
        }
        guard cmdStart < trimmed.endIndex else { return nil }

        // Column 3: full command (rest of line, trailing whitespace trimmed)
        let command = String(trimmed[cmdStart...]).trimmingCharacters(in: .whitespaces)

        return (pid, tty, command)
    }

    /// Run `lsof -a -p PID -d cwd -Fn` and parse the single `n<path>` line.
    private static func cwdOfProcess(pid: Int) -> String? {
        guard let output = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else {
            return nil
        }
        for line in output.split(separator: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    // MARK: - Session terminal detection

    /// Check if a session's terminal tab is currently the active/selected tab.
    /// Uses the Terminal window title which contains the project directory name.
    static func isSessionTerminalActive(cwd: String) -> Bool {
        let projectName = (cwd as NSString).lastPathComponent
        guard !projectName.isEmpty else { return false }
        // Check if Terminal's front window title contains this project name.
        let escaped = projectName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            if not frontmost then return "no"
            try
                set t to name of front window
                if t contains "\(escaped)" then return "yes"
            end try
            return "no"
        end tell
        """
        var errorInfo: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return false }
        let result = apple.executeAndReturnError(&errorInfo)
        return result.stringValue == "yes"
    }

    // MARK: - AppleScript focus

    /// Find and focus a Terminal tab whose name contains the given string.
    /// More reliable than TTY matching when multiple sessions share a CWD.
    private static func focusTerminalTabByTitle(containing text: String) -> Bool {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if name of t contains "\(escaped)" then
                        set frontmost of w to true
                        set selected of t to true
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        var errorInfo: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return false }
        let result = apple.executeAndReturnError(&errorInfo)
        return result.stringValue == "ok"
    }

    /// Drive Terminal.app to select the tab whose tty matches "/dev/<tty>".
    /// Returns true iff a matching tab was found and focused.
    private static func focusTerminalTab(tty: String) -> Bool {
        let devPath = "/dev/\(tty)"
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(devPath)" then
                        set frontmost of w to true
                        set selected of t to true
                        return "ok"
                    end if
                end repeat
            end repeat
            return "notfound"
        end tell
        """

        var errorInfo: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return false }
        let result = apple.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return false }
        return result.stringValue == "ok"
    }

    // MARK: - Fallback

    private static func openNewTerminal(at path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Terminal", path]
        try? task.run()
    }

    // MARK: - Process helper

    /// Synchronously run a command and return its stdout as a String, or nil on failure.
    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.launchPath = launchPath
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
