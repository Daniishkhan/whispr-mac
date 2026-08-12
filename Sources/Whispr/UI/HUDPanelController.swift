import AppKit
import SwiftUI

/// Owns the single floating panel used for the recording HUD, the editable
/// preview, and transient notices.
///
/// The panel is `.nonactivatingPanel` so it can float over the app you're
/// dictating into *without stealing its focus* while recording. For the
/// preview we explicitly activate our own app first, which lets the panel
/// become key and receive keyboard input.
@MainActor
final class HUDPanelController: @unchecked Sendable {

    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?
    private var noticeTimer: Task<Void, Never>?

    func showRecording(state: AppState) {
        noticeTimer?.cancel()
        let panel = ensurePanel()
        setContent(HUDView(state: state), size: NSSize(width: 580, height: 180))
        positionBottomCenter(panel)
        panel.orderFrontRegardless()
    }

    func showPolishing(state: AppState) {
        noticeTimer?.cancel()
        let panel = ensurePanel()
        setContent(PolishingView(state: state), size: NSSize(width: 500, height: 112))
        positionBottomCenter(panel)
        panel.orderFrontRegardless()
    }

    func showPreview(state: AppState) {
        noticeTimer?.cancel()
        let panel = ensurePanel()
        setContent(PreviewView(state: state), size: NSSize(width: 660, height: 560))
        centerOnScreen(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func showNotice(title: String, message: String) {
        let panel = ensurePanel()
        setContent(NoticeView(title: title, message: message), size: NSSize(width: 440, height: 120))
        positionBottomCenter(panel)
        panel.orderFrontRegardless()
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        noticeTimer?.cancel()
        panel?.orderOut(nil)
    }

    // MARK: - Panel plumbing

    private func setContent<Content: View>(_ view: Content, size: NSSize) {
        guard let hosting, let panel else { return }
        hosting.rootView = AnyView(view)
        panel.setContentSize(size)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 180),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        panel.contentViewController = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func positionBottomCenter(_ panel: NSPanel) {
        let visible = ScreenUtil.current().visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 100
        )
        panel.setFrameOrigin(origin)
    }

    private func centerOnScreen(_ panel: NSPanel) {
        let visible = ScreenUtil.current().visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.midY - panel.frame.height / 2 + 60
        )
        panel.setFrameOrigin(origin)
    }
}
