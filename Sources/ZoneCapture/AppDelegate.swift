import AppKit
import Carbon
import ServiceManagement
import ZoneCaptureCore

/// App delegate: sets up the menu-bar item, the global hotkeys, and owns the
/// single shared capture panel.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var pageCaptureMenuItem: NSMenuItem?
    /// One manager for every global hotkey; it dispatches Carbon events by
    /// hotkey ID so the two combos can never swallow each other.
    private let hotkeys = HotkeyManager()
    private let panel = CapturePanel()
    private var coordinator: CaptureCoordinator?
    private let captureLock = NSLock()
    private var isCapturingPage = false

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
        let pageItem = menu.addItem(withTitle: "Capture page content",
                                    action: #selector(capturePageContent),
                                    keyEquivalent: "l")
        pageItem.keyEquivalentModifierMask = [.command, .shift, .option]
        pageCaptureMenuItem = pageItem
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

        // Global hotkeys (work even when another app is frontmost).
        hotkeys.register(
            keyCode: Self.defaultsUInt32("hotkeyKeyCode", fallback: 37),
            modifiers: Self.defaultsUInt32("hotkeyModifiers", fallback: UInt32(cmdKey | shiftKey)),
            action: { [weak self] in self?.showPanel() },
            onFailure: { [weak self] status in
                // Never let the hotkey die silently: rename the first menu
                // entry so the missing shortcut is visible where the app lives.
                NSLog("[ZoneCapture] hotkey registration failed (status \(status))")
                self?.statusItem.menu?.item(at: 0)?.title =
                    "⚠︎ Hotkey not registered (⌘⇧L in use?)"
            })

        NSLog("[ZoneCapture] running. DB: \(Store.shared.databasePath)")

        Store.shared.onError = { error in
            NSLog("[ZoneCapture] database error: \(error)")
        }

        registerLoginItem()
        setupPageCaptureCoordinator()
        setupPageCaptureHotkey()
    }

    /// Locates `zone_extract.py`, preferring the bundled copy inside
    /// `Contents/Resources/tools`, falling back to a repo-relative path
    /// when running the raw SwiftPM binary during development.
    private func findZoneExtractScript() -> String {
        if let bundled = Bundle.main.path(
            forResource: "zone_extract",
            ofType: "py",
            inDirectory: "tools") {
            return bundled
        }
        // Development fallback: locate the script relative to this source
        // file so running the SwiftPM binary from any working directory works.
        // #filePath = <repo>/Sources/ZoneCapture/AppDelegate.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ZoneCapture/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // <repo>/
        let sourceRelative = repoRoot.appendingPathComponent("tools/zone_extract.py").path
        if FileManager.default.fileExists(atPath: sourceRelative) {
            return sourceRelative
        }
        return "./tools/zone_extract.py"
    }

    /// The installed .app bundles its own Python environment (see
    /// make-app.sh): a GUI app's `/usr/bin/env python3` resolves to the
    /// Command Line Tools interpreter, which has no readability/markdownify,
    /// so every capture would fail. Returns nil in development, where the
    /// runner falls back to the interactive shell's `python3`.
    private func findBundledPython() -> String? {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let candidate = (resources as NSString)
            .appendingPathComponent("tools/venv/bin/python3")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    private func setupPageCaptureCoordinator() {
        let scriptPath = findZoneExtractScript()
        let runner = PythonExtractionRunner(
            scriptPath: scriptPath,
            pythonPath: findBundledPython())
        let extractor = PageExtractor(runner: runner)
        coordinator = CaptureCoordinator(extractor: extractor, store: Store.shared)
        NSLog("[ZoneCapture] page extractor script: \(scriptPath)")
    }

    private func setupPageCaptureHotkey() {
        hotkeys.register(
            keyCode: Self.defaultsUInt32("pageHotkeyKeyCode", fallback: 37),
            modifiers: Self.defaultsUInt32(
                "pageHotkeyModifiers",
                fallback: UInt32(cmdKey | shiftKey | optionKey)),
            action: { [weak self] in self?.capturePageContent() },
            onFailure: { [weak self] status in
                NSLog("[ZoneCapture] page-capture hotkey registration failed (status \(status))")
                self?.pageCaptureMenuItem?.title =
                    "⚠︎ Hotkey not registered (⌘⇧⌥L in use?)"
                self?.panel.showBanner("⚠ ⌘⇧⌥L hotkey not registered", duration: 4.0)
            })
    }

    /// Reads an unsigned hotkey value from UserDefaults without trapping on
    /// out-of-range input (`defaults write … -int -5` must not crash launch).
    private static func defaultsUInt32(_ key: String, fallback: UInt32) -> UInt32 {
        guard let value = UserDefaults.standard.object(forKey: key) as? Int,
              let unsigned = UInt32(exactly: value) else {
            return fallback
        }
        return unsigned
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
        let alert = NSAlert()
        alert.messageText = "Recent captures"
        do {
            let rows = try Store.shared.readRecent(limit: 12)
            alert.informativeText = rows.isEmpty
                ? "Nothing captured yet. Press ⌘⇧L in a browser."
                : rows.enumerated().map { i, row in
                    let t = ISO8601DateFormatter().string(from: row.created)
                    let title = row.title.map { " (\($0))" } ?? ""
                    let c = row.comment.map { " — \($0)" } ?? ""
                    return "\(i + 1). \(row.url)\(title)\(c)\n   \(t)"
                }.joined(separator: "\n")
        } catch {
            alert.informativeText = "Database read failed: \(error)"
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func revealDB() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: Store.shared.databasePath)])
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Feature 2: page-content capture

    private func beginPageCapture() -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard !isCapturingPage else { return false }
        isCapturingPage = true
        return true
    }

    private func endPageCapture() {
        captureLock.lock()
        isCapturingPage = false
        captureLock.unlock()
    }

    @objc private func capturePageContent() {
        guard coordinator != nil else {
            panel.showBanner("✗ Page capture not configured")
            return
        }
        guard let front = URLFetcher.detectFrontmost() else {
            panel.showBanner("⚠ No frontmost app")
            return
        }
        guard beginPageCapture() else {
            panel.showBanner("⏳ Page capture already in progress", duration: 2.0)
            return
        }

        panel.showBanner("⏳ Capturing page…", duration: 25.0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer { self.endPageCapture() }

            let captured = URLFetcher.capture(app: front)

            if let message = captured.failureMessage {
                DispatchQueue.main.async {
                    self.panel.showBanner("⚠ " + message, duration: 4.5)
                }
                return
            }

            do {
                _ = try self.coordinator?.capturePage(
                    url: captured.url,
                    sourceApp: front.name,
                    comment: nil)
                DispatchQueue.main.async {
                    self.panel.showBanner("✓ Page captured")
                }
            } catch {
                // Surface the actual reason (extraction error, timeout,
                // database write failure) — a bare "failed" banner made these
                // undiagnosable without Console.app.
                let detail = String(describing: error)
                NSLog("[ZoneCapture] page capture failed: \(error)")
                DispatchQueue.main.async {
                    self.panel.showBanner("✗ " + String(detail.prefix(120)), duration: 4.5)
                }
            }
        }
    }
}
