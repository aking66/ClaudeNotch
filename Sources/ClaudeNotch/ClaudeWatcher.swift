import Foundation

/// A single active Claude Code session discovered on disk.
struct ClaudeSession: Identifiable, Hashable {
    let id: URL          // path to the .jsonl file
    let projectName: String
    let lastModified: Date
}

/// Polls ~/.claude/projects/ every few seconds and publishes active sessions.
/// Active = a .jsonl session file modified within the last 5 minutes.
@MainActor
final class ClaudeWatcher: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    private var timer: Timer?
    private let activeWindow: TimeInterval = 5 * 60  // 5 minutes

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
                found.append(ClaudeSession(
                    id: latest,
                    projectName: Self.decodeProjectName(dir.lastPathComponent),
                    lastModified: mod
                ))
            }
        }

        sessions = found.sorted { $0.lastModified > $1.lastModified }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
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
