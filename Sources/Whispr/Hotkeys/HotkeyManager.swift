import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkeys:
/// - **Hold-to-talk**: hold Right ⌥ to record, release to finish.
/// - **Toggle**: ⌃⌥Space starts/stops a hands-free session.
///
/// The Carbon `RegisterEventHotKey` path needs no special permission and works
/// regardless of which app is focused. Right-⌥ hold is tracked via
/// `flagsChanged` monitors (global for when other apps are focused, local for
/// when ours is — the two never fire for the same event, so no dedup needed).
@MainActor
final class HotkeyManager {

    var onToggle: (() -> Void)?
    var onHoldDown: (() -> Void)?
    var onHoldUp: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    nonisolated private static let hotKeySignature = fourCharCode("WHSP")
    nonisolated private static let holdKeyCode: Int64 = Int64(kVK_RightOption)

    func start() {
        installCarbonHotKey()
        installFlagsMonitors()
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        hotKeyRef = nil
        eventHandlerRef = nil
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: - Toggle hotkey (Carbon)

    private func installCarbonHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                manager.onToggle?()
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

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.hotKeySignature, id: 1)
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

    /// `flagsChanged` fires for both presses and releases. For Right ⌥,
    /// `keyCode` tells us *which* modifier changed and the presence of
    /// `.option` in `modifierFlags` tells us the direction.
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
