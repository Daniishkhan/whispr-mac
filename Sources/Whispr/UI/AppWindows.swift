import AppKit
import SwiftUI

/// Owns the Settings and History windows.
///
/// We manage these with plain AppKit instead of SwiftUI's `Settings`/`Window`
/// scenes: with a MenuBarExtra + LSUIElement app, the scene actions
/// (`showSettingsWindow:`) report success but never actually order in a
/// window. Direct NSWindow control is deterministic.
@MainActor
final class AppWindows {

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func showSettings(state: AppState) {
        present(
            window: &settingsWindow,
            makeContent: { SettingsView(state: state) },
            title: "Whispr Settings",
            size: NSSize(width: 540, height: 780)
        )
    }

    func showHistory(state: AppState) {
        present(
            window: &historyWindow,
            makeContent: { HistoryView(state: state) },
            title: "Transcript History",
            size: NSSize(width: 560, height: 420)
        )
    }

    private func present<Content: View>(
        window storage: inout NSWindow?,
        makeContent: () -> Content,
        title: String,
        size: NSSize
    ) {
        if let existing = storage {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: makeContent())
        let screen = ScreenUtil.current().visibleFrame
        window.setFrameOrigin(NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        ))
        window.isReleasedWhenClosed = false
        storage = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] note in
            // The observer is bound to the main queue, so this always runs on
            // the main thread; the annotation just satisfies the compiler.
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let self, let closing = note.object as? NSWindow else { return }
                if closing === self.settingsWindow { self.settingsWindow = nil }
                if closing === self.historyWindow { self.historyWindow = nil }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
