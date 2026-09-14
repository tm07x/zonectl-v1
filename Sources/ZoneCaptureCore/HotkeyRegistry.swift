import Foundation

/// Pure dispatch table for global hotkeys.
///
/// Carbon delivers every `kEventHotKeyPressed` event to the application event
/// target, and a handler that returns `noErr` consumes the event. The old
/// design installed one handler per hotkey and ignored the event's
/// `EventHotKeyID`, so whichever handler ran first consumed *every* hotkey
/// press — the second registration hijacked the first.
///
/// The fix lives in two parts: this registry gives each hotkey a unique ID
/// and routes an incoming ID to the action that was registered for it, and
/// `HotkeyManager` (in the app target) installs a single Carbon handler that
/// reads the `EventHotKeyID` and dispatches through here.
public final class HotkeyRegistry {
    public typealias Action = () -> Void

    private var actions: [UInt32: Action] = [:]
    private var nextID: UInt32 = 1

    public init() {}

    /// Registers an action and returns its unique hotkey ID. IDs are never
    /// reused, so a stale Carbon event can never fire a newer action.
    @discardableResult
    public func register(_ action: @escaping Action) -> UInt32 {
        let id = nextID
        nextID += 1
        actions[id] = action
        return id
    }

    public func unregister(id: UInt32) {
        actions.removeValue(forKey: id)
    }

    /// Runs the action registered for `id`. Returns false when no action is
    /// registered, so the caller can refuse to consume the event.
    @discardableResult
    public func dispatch(id: UInt32) -> Bool {
        guard let action = actions[id] else { return false }
        action()
        return true
    }
}
