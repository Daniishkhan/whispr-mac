import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Inserts text into the focused app by swapping the clipboard and simulating
/// ⌘V, then restoring the previous clipboard contents.
///
/// Requires Accessibility permission for the synthetic keystroke; without it
/// we fall back to leaving the text on the clipboard and telling the user.
enum TextInserter {

    enum InsertResult {
        case pasted
        case copiedOnly
    }

    @MainActor
    static func insert(text: String) -> InsertResult {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            return .copiedOnly
        }

        postCommandV()

        // Give the target app a beat to consume the paste before restoring.
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            snapshot.restore(to: pasteboard)
        }
        return .pasted
    }

    static func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}

/// Saves every pasteboard item (all types) so the user's clipboard can be
/// restored after a paste-based insertion.
struct PasteboardSnapshot {
    private let items: [[String: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var snapshot: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            if !entry.isEmpty {
                snapshot.append(entry)
            }
        }
        return PasteboardSnapshot(items: snapshot)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for entry in items {
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            pasteboard.writeObjects([item])
        }
    }
}
