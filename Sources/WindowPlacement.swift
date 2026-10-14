import AppKit

enum WindowPlacement {
    /// Screen under the mouse pointer, so the window appears where the user is working.
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Exact center of the visible screen area (NSWindow.center() sits above center).
    static func frame(size: NSSize, on screen: NSScreen?) -> NSRect {
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    static func center(_ window: NSWindow) {
        window.setFrame(frame(size: window.frame.size, on: activeScreen()), display: false)
    }

    /// Largest height that still fits the screen with some air.
    static func maxContentHeight() -> CGFloat {
        (activeScreen()?.visibleFrame.height ?? 800) * 0.85 - 28
    }
}
