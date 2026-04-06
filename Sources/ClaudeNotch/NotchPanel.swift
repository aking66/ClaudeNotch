import AppKit

/// Borderless floating NSPanel that visually extends from the MacBook notch.
/// Its top edge aligns flush with the screen top so the portion behind the
/// physical notch cutout is hidden, while the sides and bottom droop down
/// like a widget growing out of the notch itself. Uses `.nonactivatingPanel`
/// so it never steals focus from the active app.
final class NotchPanel: NSPanel {
    /// Max window width. Must be >= the widest state that NotchView can
    /// render (currently the expanded dashboard at 560pt); otherwise the
    /// SwiftUI content gets clipped by the NSPanel frame.
    static let panelWidth: CGFloat = 600

    /// Visible content height below the notch region. The full panel frame
    /// includes an extra `notchHeight` at the top that is physically hidden
    /// behind the display cutout.
    static let visibleContentHeight: CGFloat = 380

    /// Notch height of the active main screen at launch (cached for layout).
    static var currentNotchHeight: CGFloat {
        NSScreen.main?.safeAreaInsets.top ?? 0
    }

    init(contentView: NSView) {
        let fullHeight = Self.visibleContentHeight + Self.currentNotchHeight
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: fullHeight),
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

    /// Center horizontally, glue the top edge of the panel to the screen top so
    /// the notch cutout physically occludes the upper center of our frame.
    func positionNearNotch() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let panelHeight = Self.visibleContentHeight + screen.safeAreaInsets.top
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.maxY - panelHeight
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // Allow clicks without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
