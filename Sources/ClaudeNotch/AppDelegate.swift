import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var watcher: ClaudeWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let watcher = ClaudeWatcher()
        self.watcher = watcher

        let rootView = NotchView(watcher: watcher)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(x: 0, y: 0, width: NotchPanel.panelWidth, height: NotchPanel.panelHeight)

        let panel = NotchPanel(contentView: hosting)
        panel.orderFrontRegardless()
        self.panel = panel

        watcher.start()
    }
}
