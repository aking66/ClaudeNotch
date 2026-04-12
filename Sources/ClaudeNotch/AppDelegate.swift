import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var watcher: ClaudeWatcher?
    private var usageFetcher: UsageFetcher?
    var hookServer: HookServer?
    private var focusMonitor: FocusMonitor?
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE so writing to a closed bridge socket doesn't
        // crash the app. Common for daemon/background apps using sockets.
        signal(SIGPIPE, SIG_IGN)

        let watcher = ClaudeWatcher()
        self.watcher = watcher

        let focus = FocusMonitor()
        self.focusMonitor = focus
        focus.start()
        watcher.focusMonitor = focus

        let usage = UsageFetcher()
        self.usageFetcher = usage
        usage.start()

        let rootView = NotchView(watcher: watcher, usage: usage, focusMonitor: focus)
        let hosting = NSHostingView(rootView: rootView)
        let fullHeight = NotchPanel.visibleContentHeight + NotchPanel.currentNotchHeight
        hosting.frame = NSRect(x: 0, y: 0, width: NotchPanel.panelWidth, height: fullHeight)

        let panel = NotchPanel(contentView: hosting)
        panel.orderFrontRegardless()
        self.panel = panel

        watcher.start()

        // Bring up the hook server BEFORE we start touching settings.json,
        // so the socket is ready whenever Claude Code first fires a hook.
        // Events are routed straight into the watcher so the UI reflects
        // state changes with sub-100ms latency — no polling wait.
        // PostToolUse / Stop also poke the usage fetcher because every
        // finished turn nudges the 5h / 7d counters on Anthropic's side.
        let server = HookServer { [weak watcher, weak usage] event in
            let sid = event.sessionId ?? "?"
            let tool = event.toolName ?? "-"
            // Register name from cwd BEFORE logging so the first line is readable.
            if let cwd = event.cwd, !cwd.isEmpty, sid != "?" {
                CNLog.registerSession(id: sid, name: (cwd as NSString).lastPathComponent, fromHook: true)
            }
            CNLog.hook("\(event.hookEventName) session=\(CNLog.sessionLabel(sid)) tool=\(tool)")
            if let input = event.toolInput, !input.isEmpty {
                let detail = ClaudeWatcher.describeToolInput(toolName: tool, input: event.toolInput) ?? ""
                if !detail.isEmpty { CNLog.tool("\(tool): \(detail)") }
            }
            watcher?.applyHookEvent(event)
            SoundManager.shared.playForEvent(event.hookEventName, toolName: event.toolName)

            if event.hookEventName == "PostToolUse" || event.hookEventName == "Stop" {
                usage?.refreshIfStale(maxAge: 30)
            }
            // Detect if permission was answered from terminal vs UI.
            if event.hookEventName == "PostToolUse", let sid2 = event.sessionId {
                (NSApp.delegate as? AppDelegate)?.hookServer?.detectPermissionSource(sessionId: sid2)
            }
            if event.hookEventName == "Stop", let sid2 = event.sessionId {
                (NSApp.delegate as? AppDelegate)?.hookServer?.clearPendingApproval(sessionId: sid2)
            }
        }
        server.start()
        self.hookServer = server

        // Safety net: if permission resolve fails (bridge gone), clear
        // the stale awaitingApproval status after 10s timeout.
        server.staleApprovalCallback = { [weak watcher] sessionId in
            watcher?.clearStalePermission(sessionId: sessionId)
        }

        // Idempotently install the hooks into ~/.claude/settings.json. Makes
        // a timestamped backup whenever it actually has to mutate the file.
        do {
            let result = try HookInstaller.install()
            if result.added > 0 {
                NSLog("ClaudeNotch: installed \(result.added) new hook(s)")
            }
            try HookInstaller.installStatusLine()
        } catch {
            NSLog("ClaudeNotch: hook install failed: \(error)")
        }

        setupStatusItem()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Diamond glyph matches the "◆ CLAUDE NOTCH" header in the panel.
            button.title = "◆"
            button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            button.toolTip = "ClaudeNotch"
        }

        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: "Hide Notch",
            action: #selector(toggleNotch),
            keyEquivalent: "h"
        )
        toggle.target = self
        menu.addItem(toggle)
        self.toggleMenuItem = toggle

        menu.addItem(.separator())

        let uninstallHooks = NSMenuItem(
            title: "Uninstall Claude Code Hooks",
            action: #selector(uninstallHooksAction),
            keyEquivalent: ""
        )
        uninstallHooks.target = self
        menu.addItem(uninstallHooks)

        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        self.launchAtLoginMenuItem = launchAtLogin
        refreshLaunchAtLoginState()

        menu.addItem(.separator())

        let diag = NSMenuItem(
            title: "Run Diagnostics",
            action: #selector(runDiagnostics),
            keyEquivalent: "d"
        )
        diag.target = self
        menu.addItem(diag)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit ClaudeNotch",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func toggleNotch() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            toggleMenuItem?.title = "Show Notch"
        } else {
            panel.orderFrontRegardless()
            toggleMenuItem?.title = "Hide Notch"
        }
    }

    @objc private func runDiagnostics() {
        watcher?.simulateBugScenarios()
        // Open the log file so user can see results immediately.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/claudenotch.log"))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// Called by the NotchView's permission buttons to send a decision
    /// back to the Claude Code CLI through the bridge socket.
    func resolvePermission(sessionId: String, decision: String) {
        hookServer?.resolvePermission(sessionId: sessionId, decision: decision)
        // Immediately switch status to working so the UI stops showing
        // the permission card and hasPermission becomes false (allowing
        // the panel to collapse). Don't wait for PostToolUse.
        watcher?.permissionResolved(sessionId: sessionId)
    }

    @objc private func uninstallHooksAction() {
        do {
            let result = try HookInstaller.uninstall()
            let alert = NSAlert()
            alert.messageText = "ClaudeNotch hooks removed"
            alert.informativeText = result.removed > 0
                ? "Removed \(result.removed) entries from ~/.claude/settings.json. Backup: \(result.backup ?? "—")"
                : "No ClaudeNotch hooks were installed."
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Uninstall failed"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - Launch at login

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("ClaudeNotch: failed to toggle launch-at-login: \(error)")
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
