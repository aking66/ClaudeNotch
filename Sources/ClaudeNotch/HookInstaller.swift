import Foundation

/// Installs and uninstalls ClaudeNotch's Claude Code hooks in
/// `~/.claude/settings.json`. Every mutation makes a timestamped backup
/// and preserves every non-ClaudeNotch entry in the file (Vibe Island,
/// osascript notifications, etc. keep working in parallel).
enum HookInstaller {

    /// Events we want to subscribe to. Tuple: (event name, use matcher, timeout).
    /// The matcher "*" is required for tool-related events; other events
    /// don't use matchers at all. PermissionRequest gets a 24h timeout so
    /// the bridge can block until the user clicks Allow/Deny in the notch.
    private static let events: [(name: String, useMatcher: Bool, timeout: Int?)] = [
        ("UserPromptSubmit", false, nil),
        ("PreToolUse",       true,  nil),
        ("PostToolUse",      true,  nil),
        ("PermissionRequest", true, 86400),   // 24h — bridge blocks for decision
        ("Notification",     true,  nil),
        ("Stop",             false, nil),
        ("SessionStart",     false, nil),
        ("SessionEnd",       false, nil),
        ("SubagentStart",    false, nil),
        ("SubagentStop",     false, nil),
        ("PreCompact",       false, nil),
    ]

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Absolute path to the bridge helper inside the running app bundle.
    /// Falls back to the built .app path in the repo during local dev.
    static var bridgePath: String {
        if let bundle = Bundle.main.executablePath {
            // bundle: .../ClaudeNotch.app/Contents/MacOS/ClaudeNotch
            let helpers = URL(fileURLWithPath: bundle)
                .deletingLastPathComponent()     // MacOS/
                .deletingLastPathComponent()     // Contents/
                .appendingPathComponent("Helpers/claudenotch-bridge")
            if FileManager.default.isExecutableFile(atPath: helpers.path) {
                return helpers.path
            }
        }
        // Dev fallback — the checked-in build output.
        return "/Users/ahmed/ClaudeNotch/ClaudeNotch.app/Contents/Helpers/claudenotch-bridge"
    }

    /// Path where the StatusLine script dumps rate_limits JSON.
    static let rateLimitsFile = "/tmp/claudenotch-rl.json"

    // MARK: - StatusLine

    /// Inject our rate_limits extraction into the existing statusLine command.
    /// Appends a one-liner that saves `.rate_limits` to a temp file on every
    /// assistant message — zero API calls, free data.
    static func installStatusLine() throws {
        var settings = readSettings() ?? [:]
        var sl = (settings["statusLine"] as? [String: Any]) ?? [:]
        let existingCmd = (sl["command"] as? String) ?? ""

        let marker = "# ClaudeNotch: rate_limits bridge"
        if existingCmd.contains(marker) { return } // already installed

        // Append our extraction after the existing command
        let rlSnippet = "; \(marker)\n_rl=$(echo \"$input\" | jq -c '.rate_limits // empty' 2>/dev/null); [ -n \"$_rl\" ] && echo \"$_rl\" > \(rateLimitsFile)"

        let newCmd: String
        if existingCmd.isEmpty {
            newCmd = "input=$(cat)\(rlSnippet)"
        } else {
            // The existing command likely starts with input=$(cat).
            // Append our snippet at the end.
            newCmd = existingCmd + rlSnippet
        }

        sl["command"] = newCmd
        sl["type"] = "command"
        settings["statusLine"] = sl

        let _ = try backupCurrent()
        try writeSettings(settings)
        NSLog("ClaudeNotch: installed StatusLine rate_limits bridge")
    }

    // MARK: - Public

    /// True if every event we want already has a claudenotch-bridge entry.
    static func isInstalled() -> Bool {
        guard let settings = readSettings(),
              let hooks = settings["hooks"] as? [String: Any]
        else { return false }

        for (event, _, _) in events {
            if !hookArrayContainsBridge(hooks[event]) { return false }
        }
        return true
    }

    /// Idempotent install. Returns (added count, backup path on first change).
    @discardableResult
    static func install() throws -> (added: Int, backup: String?) {
        var settings = readSettings() ?? [:]
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        var added = 0
        for (event, useMatcher, timeout) in events {
            var eventEntries = (hooks[event] as? [[String: Any]]) ?? []
            let existingIdx = eventEntries.firstIndex(where: entryIsOurBridge)

            if let idx = existingIdx {
                // Already present — but upgrade it if the timeout changed
                // (e.g. PermissionRequest gained timeout: 86400 after the
                // initial install that didn't have it).
                let needsUpgrade: Bool = {
                    guard let hookArr = eventEntries[idx]["hooks"] as? [[String: Any]],
                          let hook = hookArr.first else { return true }
                    let currentTimeout = hook["timeout"] as? Int
                    return currentTimeout != timeout
                }()
                if needsUpgrade {
                    eventEntries[idx] = makeEntry(useMatcher: useMatcher, timeout: timeout)
                    hooks[event] = eventEntries
                    added += 1
                }
                continue
            }

            eventEntries.append(makeEntry(useMatcher: useMatcher, timeout: timeout))
            hooks[event] = eventEntries
            added += 1
        }

        guard added > 0 else { return (0, nil) }

        settings["hooks"] = hooks
        let backup = try backupCurrent()
        try writeSettings(settings)
        NSLog("ClaudeNotch: installed \(added) hook(s), backup=\(backup)")
        return (added, backup)
    }

    /// Remove only our entries, leaving every other hook untouched.
    @discardableResult
    static func uninstall() throws -> (removed: Int, backup: String?) {
        guard var settings = readSettings(),
              var hooks = settings["hooks"] as? [String: Any]
        else { return (0, nil) }

        var removed = 0
        for (event, _, _) in events {
            guard var eventEntries = hooks[event] as? [[String: Any]] else { continue }
            let before = eventEntries.count
            eventEntries.removeAll(where: entryIsOurBridge)
            if eventEntries.count < before {
                removed += (before - eventEntries.count)
                if eventEntries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = eventEntries
                }
            }
        }

        guard removed > 0 else { return (0, nil) }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        let backup = try backupCurrent()
        try writeSettings(settings)
        NSLog("ClaudeNotch: removed \(removed) hook(s), backup=\(backup)")
        return (removed, backup)
    }

    // MARK: - Matching

    /// True if the given value — expected to be `[[String: Any]]` — contains
    /// at least one entry whose hooks array references our bridge.
    private static func hookArrayContainsBridge(_ raw: Any?) -> Bool {
        guard let arr = raw as? [[String: Any]] else { return false }
        return arr.contains(where: entryIsOurBridge)
    }

    private static func entryIsOurBridge(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            (hook["command"] as? String)?.contains("claudenotch-bridge") == true
        }
    }

    private static func makeEntry(useMatcher: Bool, timeout: Int? = nil) -> [String: Any] {
        var hook: [String: Any] = [
            "command": bridgePath,
            "type": "command"
        ]
        if let timeout {
            hook["timeout"] = timeout
        }
        var entry: [String: Any] = ["hooks": [hook]]
        if useMatcher {
            entry["matcher"] = "*"
        }
        return entry
    }

    // MARK: - File I/O

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        // Pretty print with sorted keys to keep the file diff-friendly.
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )

        // Atomic write: temp file + rename to avoid half-written settings
        // if the process dies mid-write.
        let tmpURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent(".settings.claudenotch-tmp.json")
        try data.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: tmpURL)
    }

    /// Copy the current settings.json to a timestamped backup, returning
    /// the absolute path written. Safe to call even when the file is
    /// missing — in that case no backup is produced and we return "".
    private static func backupCurrent() throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return "" }

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.claudenotch-backup-\(ts)")

        // Copy (not move) so the active file remains intact.
        try? fm.removeItem(at: backupURL)  // unlikely collision, just in case
        try fm.copyItem(at: settingsURL, to: backupURL)
        return backupURL.path
    }
}
