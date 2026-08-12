import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkeys:
/// - **Hold-to-talk**: hold Right ⌥ to record, release to finish.
/// - **Toggle**: ⌃⌥Space starts/stops a hands-free session.
/// - **Temporary Escape**: cancels an initial polish request without requiring
///   Accessibility permission.
@MainActor
final class HotkeyManager {

    var onToggle: (() -> Void)?
    var onHoldDown: (() -> Void)?
    var onHoldUp: (() -> Void)?
    var onTemporaryEscape: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var escapeHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    nonisolated private static let hotKeySignature = fourCharCode("WHSP")
    nonisolated private static let toggleHotKeyID: UInt32 = 1
    nonisolated private static let escapeHotKeyID: UInt32 = 2
    nonisolated private static let holdKeyCode: Int64 = Int64(kVK_RightOption)

    func start() {
        installCarbonHotKey()
        installFlagsMonitors()
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        unregisterTemporaryEscape()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        hotKeyRef = nil
        eventHandlerRef = nil
        globalMonitor = nil
        localMonitor = nil
    }

    /// Registers only while the initial nonactivating polish panel is shown.
    /// Carbon consumes the event before it reaches the target application.
    func registerTemporaryEscape() {
        guard escapeHotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: HotkeyManager.hotKeySignature, id: HotkeyManager.escapeHotKeyID)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            id,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr else {
            dbg("hotkey: RegisterEventHotKey failed for Escape (\(status))")
            return
        }
        escapeHotKeyRef = reference
    }

    func unregisterTemporaryEscape() {
        if let escapeHotKeyRef { UnregisterEventHotKey(escapeHotKeyRef) }
        escapeHotKeyRef = nil
    }

    // MARK: - Carbon hotkeys

    private func installCarbonHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                switch hotKeyID.id {
                case HotkeyManager.toggleHotKeyID:
                    manager.onToggle?()
                case HotkeyManager.escapeHotKeyID:
                    manager.onTemporaryEscape?()
                default:
                    break
                }
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard status == noErr else {
            dbg("hotkey: InstallEventHandler failed (\(status))")
            return
        }

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.hotKeySignature, id: HotkeyManager.toggleHotKeyID)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        dbg(registerStatus == noErr
            ? "hotkey: ⌃⌥Space registered"
            : "hotkey: RegisterEventHotKey failed (\(registerStatus)) — another app may own ⌃⌥Space")
    }

    // MARK: - Hold hotkey (modifier flags)

    private func installFlagsMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private nonisolated func handleFlagsChanged(_ event: NSEvent) {
        guard Int64(event.keyCode) == HotkeyManager.holdKeyCode else { return }
        let pressed = event.modifierFlags.contains(.option)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if pressed {
                self.onHoldDown?()
            } else {
                self.onHoldUp?()
            }
        }
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}
