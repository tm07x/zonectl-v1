import AppKit
import ServiceManagement
import ZoneCaptureCore

/// App delegate: sets up the menu-bar item, the global hotkey, and owns the
/// single shared capture panel.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyManager()
    private let panel = CapturePanel()
    private var lastReadError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar item — a small bookmark glyph.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "bookmark.fill",
                accessibilityDescription: "ZoneCapture")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Capture frontmost URL",
                     action: #selector(showPanel),
                     keyEquivalent: "l")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Recent captures…",
                     action: #selector(showRecent),
                     keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal database in Finder",
                     action: #selector(revealDB),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit",
                     action: #selector(quit),
                     keyEquivalent: "q")
        statusItem.menu = menu

        // Global hotkey (works even when another app is frontmost).
        hotkey.onTrigger = { [weak self] in self?.showPanel() }
        hotkey.onRegistrationFailed = { [weak self] status in
            // Never let the hotkey die silently: rename the first menu entry
            // so the missing shortcut is visible where the app lives.
            NSLog("[ZoneCapture] hotkey registration failed (status \(status))")
            self?.statusItem.menu?.item(at: 0)?.title =
                "⚠︎ Hotkey not registered (⌘⇧L in use?)"
        }
        hotkey.registerDefault()

        NSLog("[ZoneCapture] running. DB: \(Store.shared.databasePath)")

        // Surface database errors instead of failing silently. Write failures
        // are also caught at the call site (the panel shows a retryable
        // error); this hook logs everything and remembers read errors so
        // "Recent captures…" can report them.
        Store.shared.onError = { [weak self] error in
            NSLog("[ZoneCapture] database error: \(error)")
            if case .queryFailed = error {
                self?.lastReadError = String(describing: error)
            }
        }

        registerLoginItem()
    }

    /// Relaunch ZoneCapture at login so the ⌘⇧L hotkey survives reboots.
    ///
    /// The login item always points at the currently running bundle, so
    /// reinstalling to /Applications (make-app.sh) moves the entry over
    /// automatically; a stale entry (e.g. a deleted debug build) shows up as
    /// `.notFound` and is replaced here.
    private func registerLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .notRegistered, .requiresApproval, .notFound:
                try service.register()
                NSLog("[ZoneCapture] login item registered, status: \(statusName(service.status))")
            case .enabled:
                NSLog("[ZoneCapture] login item already enabled")
            @unknown default:
                NSLog("[ZoneCapture] login item: unrecognized status")
            }
        } catch {
            NSLog("[ZoneCapture] login item registration failed: \(error.localizedDescription)")
        }
    }

    private func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    @objc func showPanel() {
        panel.show()
    }

    @objc func showRecent() {
        let rows = Store.shared.recent(limit: 12)
        let alert = NSAlert()
        alert.messageText = "Recent captures"
        alert.informativeText = rows.isEmpty
            ? (lastReadError.map { "Database read failed: \($0)" }
                ?? "Nothing captured yet. Press ⌘⇧L in a browser.")
            : rows.enumerated().map { i, row in
                let t = ISO8601DateFormatter().string(from: row.created)
                let title = row.title.map { " (\($0))" } ?? ""
                let c = row.comment.map { " — \($0)" } ?? ""
                return "\(i + 1). \(row.url)\(title)\(c)\n   \(t)"
            }.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func revealDB() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: Store.shared.databasePath)])
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
