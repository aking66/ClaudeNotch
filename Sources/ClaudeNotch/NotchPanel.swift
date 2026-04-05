import AppKit

/// Borderless floating NSPanel positioned directly under the MacBook notch.
/// Uses `.nonactivatingPanel` so it never steals focus from the active app.
final class NotchPanel: NSPanel {
    static let panelWidth: CGFloat = 440
    static let panelHeight: CGFloat = 150

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isMovableByWindowBackground = true
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.contentView = contentView

        positionNearNotch()
    }

    /// Center horizontally, tuck the panel just below the notch area.
    func positionNearNotch() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        // safeAreaInsets.top > 0 on notched Macs (macOS 12+)
        let notchHeight = screen.safeAreaInsets.top
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.maxY - max(notchHeight, 0) - Self.panelHeight - 6
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // Allow clicks without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
