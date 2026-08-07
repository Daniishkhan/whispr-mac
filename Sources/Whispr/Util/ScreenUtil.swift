import AppKit

enum ScreenUtil {

    /// The screen most relevant to the user right now: the one containing the
    /// mouse cursor, falling back to the key window's screen, then the main
    /// screen. Multi-display setups put new windows on surprising screens
    /// otherwise.
    static func current() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}
