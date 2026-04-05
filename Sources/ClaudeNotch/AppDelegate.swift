import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var watcher: ClaudeWatcher?
    private var hookServer: HookServer?
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let watcher = ClaudeWatcher()
        self.watcher = watcher

        let rootView = NotchView(watcher: watcher)
        let hosting = NSHostingView(rootView: rootView)
        let fullHeight = NotchPanel.visibleContentHeight + NotchPanel.currentNotchHeight
        hosting.frame = NSRect(x: 0, y: 0, width: NotchPanel.panelWidth, height: fullHeight)

        let panel = NotchPanel(contentView: hosting)
        panel.orderFrontRegardless()
        self.panel = panel

        watcher.start()

        // Bring up the hook server BEFORE we start touching settings.json,
        // so the socket is ready whenever Claude Code first fires a hook.
        let server = HookServer { event in
            NSLog("ClaudeNotch hook: \(event.hookEventName) session=\(event.sessionId ?? "?") tool=\(event.toolName ?? "-")")
        }
        server.start()
        self.hookServer = server

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
