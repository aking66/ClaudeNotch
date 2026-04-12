import AppKit
import Combine

/// Monitors which app is frontmost to enable smart auto-expand behavior:
/// - Suppress auto-expand when Terminal is focused (user is already looking at Claude)
/// - Collapse the panel when the user switches away to another app
@MainActor
final class FocusMonitor: ObservableObject {
    /// True when a terminal app (Terminal.app, iTerm2, etc.) is frontmost.
    @Published private(set) var isTerminalFocused = false

    /// Fires when user switches FROM our notch area to another app.
    /// NotchView observes this to auto-collapse.
    @Published var appSwitchCounter = 0

    /// Bundle IDs of terminal apps where the user can see Claude Code output.
    /// When these are focused, auto-expand is suppressed.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "org.alacritty",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
    ]

    private var observation: Any?

    /// The currently focused app name, for logging.
    private(set) var currentAppName: String = ""

    func start() {
        // Check initial state
        updateFocusState()

        // Watch for app activation changes
        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                let previousTerminal = self.isTerminalFocused
                let previousApp = self.currentAppName
                self.updateFocusState()

                if previousApp != self.currentAppName {
                    CNLog.focus("\(previousApp) → \(self.currentAppName)")
                }

                // If user switched away from a terminal to something else,
                // signal collapse (they're no longer looking at Claude output).
                if previousTerminal && !self.isTerminalFocused {
                    self.appSwitchCounter += 1
                }
            }
        }
    }

    func stop() {
        if let obs = observation {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            observation = nil
        }
    }

    private func updateFocusState() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            isTerminalFocused = false
            return
        }
        let bundleID = app.bundleIdentifier ?? ""
        isTerminalFocused = Self.terminalBundleIDs.contains(bundleID)
        currentAppName = app.localizedName ?? bundleID
    }
}
