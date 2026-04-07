import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var watcher: ClaudeWatcher?
    private var usageFetcher: UsageFetcher?
    private var hookServer: HookServer?
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
            NSLog("ClaudeNotch hook: \(event.hookEventName) session=\(event.sessionId ?? "?") tool=\(event.toolName ?? "-")")
            watcher?.applyHookEvent(event)

            if event.hookEventName == "PostToolUse" || event.hookEventName == "Stop" {
                usage?.refreshIfStale(maxAge: 30)
            }
            // Only clear pending approval on Stop (session ended) — NOT on
            // every PostToolUse, as that would clear the pending fd for a
            // PermissionRequest that's still waiting while other tools run.
            if event.hookEventName == "Stop", let sid = event.sessionId {
                (NSApp.delegate as? AppDelegate)?.hookServer?.clearPendingApproval(sessionId: sid)
            }
        }
        server.start()
        self.hookServer = server

        // Idempotently install the hooks into ~/.claude/settings.json. Makes
        // a timestamped backup whenever it actually has to mutate the file.
        do {
            let result = try HookInstaller.install()
            if result.added > 0 {
                NSLog("ClaudeNotch: installed \(result.added) new hook(s)")
            }
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

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// Called by the NotchView's permission buttons to send a decision
    /// back to the Claude Code CLI through the bridge socket.
    func resolvePermission(sessionId: String, decision: String) {
        hookServer?.resolvePermission(sessionId: sessionId, decision: decision)
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
