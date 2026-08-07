import AppKit
import ApplicationServices
import Foundation

enum Permissions {

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt once (if never granted). Returns current state.
    @discardableResult
    static func requestAccessibilityPrompt() -> Bool {
        // Same value as kAXTrustedCheckOptionPrompt, inlined to avoid the
        // concurrency-unsafe global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
