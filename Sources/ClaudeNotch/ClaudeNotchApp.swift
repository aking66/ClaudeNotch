import AppKit

@main
enum ClaudeNotchApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory = no Dock icon, no menu bar app — pure floating panel
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
