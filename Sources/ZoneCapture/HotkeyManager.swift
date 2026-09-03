import AppKit
import Carbon

/// Registers a single system-wide hotkey using the Carbon `RegisterEventHotKey`
/// API. This is still the most reliable way to get a global shortcut on macOS
/// without pulling in a third-party dependency.
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    var onTrigger: (() -> Void)?

    /// Default binding: Cmd + Shift + L  (L for "link").
    /// KeyCode 37 == 'L'. Override freely later.
    func registerDefault() {
        register(keyCode: 37, modifiers: UInt32(cmdKey) | UInt32(shiftKey))
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onTrigger?() }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5A4F4E45), id: 1)  // 'ZONE'
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit { unregister() }
}
