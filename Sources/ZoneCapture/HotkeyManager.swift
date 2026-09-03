import AppKit
import Carbon

/// Registers a single system-wide hotkey using the Carbon `RegisterEventHotKey`
/// API. This is still the most reliable way to get a global shortcut on macOS
/// without pulling in a third-party dependency.
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    var onTrigger: (() -> Void)?

    /// Called when the OS refuses the registration (typically because another
    /// app already owns the combo). The UI must surface this — a silently dead
    /// hotkey is the worst failure mode of this app.
    var onRegistrationFailed: ((OSStatus) -> Void)?

    /// Default binding: Cmd + Shift + L  (L for "link"). KeyCode 37 == 'L'.
    ///
    /// Configurable without code, e.g. to switch to ⌥⇧L (keyCode 37,
    /// modifiers cmdKey|optionKey… see Carbon masks below):
    ///
    ///     defaults write com.grokink.zonecapture hotkeyKeyCode -int 37
    ///     defaults write com.grokink.zonecapture hotkeyModifiers -int 2816
    ///
    /// Carbon modifier masks: cmdKey 256 · shiftKey 512 · optionKey 2048 ·
    /// controlKey 4096 (combine by adding). Restart the app to apply.
    func registerDefault() {
        let defaults = UserDefaults.standard
        let keyCode = UInt32(defaults.object(forKey: "hotkeyKeyCode") as? Int ?? 37)
        let modifiers = UInt32(
            defaults.object(forKey: "hotkeyModifiers") as? Int ?? (cmdKey | shiftKey))
        register(keyCode: keyCode, modifiers: modifiers)
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let handlerStatus = InstallEventHandler(
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
        if handlerStatus != noErr {
            NSLog("[ZoneCapture] InstallEventHandler failed: \(handlerStatus)")
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5A4F4E45), id: 1)  // 'ZONE'
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
        if status != noErr {
            NSLog("[ZoneCapture] RegisterEventHotKey failed (\(status)) — combo likely owned by another app")
            hotKeyRef = nil
            onRegistrationFailed?(status)
        }
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
