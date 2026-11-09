import AppKit
import Carbon
import ZoneCaptureCore

/// Registers system-wide hotkeys using the Carbon `RegisterEventHotKey` API.
///
/// One instance manages any number of hotkeys. A single Carbon event handler
/// is installed lazily on first registration; every hotkey gets a unique
/// `EventHotKeyID.id` from the shared `HotkeyRegistry`, and the handler reads
/// the ID out of the delivered event to find the matching action.
///
/// This matters because Carbon dispatches `kEventHotKeyPressed` to every
/// handler on the application target and the first one returning `noErr`
/// consumes the event. The previous one-handler-per-hotkey design let the
/// most recently installed handler swallow every combo, so ⌘⇧L triggered the
/// page-capture action instead of opening the panel.
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private let registry = HotkeyRegistry()

    /// 'ZONE' — identifies our hotkeys to Carbon.
    private let signature = OSType(0x5A4F4E45)

    /// Registers a global hotkey. `onFailure` is called when the OS refuses
    /// the registration (typically because another app owns the combo) — the
    /// UI must surface this; a silently dead hotkey is the worst failure mode.
    ///
    /// Carbon modifier masks: cmdKey 256 · shiftKey 512 · optionKey 2048 ·
    /// controlKey 4096 (combine by adding). Restart the app to apply changes.
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void,
        onFailure: ((OSStatus) -> Void)? = nil
    ) {
        registry.register(action, installHandler: installHandlerIfNeeded, reserve: { id in
            let hotKeyID = EventHotKeyID(signature: signature, id: id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                NSLog("[ZoneCapture] RegisterEventHotKey failed (\(status)) — combo likely owned by another app")
                return status == noErr ? OSStatus(paramErr) : status
            }
            hotKeyRefs[id] = ref
            return noErr
        }, onFailure: onFailure)
    }

    func unregisterAll() {
        for (id, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
            registry.unregister(id: id)
        }
        hotKeyRefs.removeAll()
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()

                // Identify WHICH hotkey fired. Without this, the handler can
                // only guess — and guessing wrong hijacks the other hotkey.
                var hotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID)
                guard paramStatus == noErr, hotKeyID.signature == manager.signature else {
                    // Not one of ours: refuse to consume it.
                    return OSStatus(eventNotHandledErr)
                }

                DispatchQueue.main.async {
                    manager.registry.dispatch(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler)
        if status != noErr {
            NSLog("[ZoneCapture] InstallEventHandler failed: \(status)")
            return status
        }
        return eventHandler == nil ? OSStatus(eventNotHandledErr) : noErr
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
