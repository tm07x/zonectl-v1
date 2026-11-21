import AppKit
import ZoneCaptureCore

/// The small floating launcher panel shown when the global hotkey fires.
///
/// Layout:
///   ┌───────────────────────────────────────────┐
///   │ URL:    [ the captured url, editable ]      │
///   │ Note:   [ your comment                ]      │
///   │            [ Cancel ]      [ Save (↵) ]      │
///   └───────────────────────────────────────────┘
///
/// The panel appears IMMEDIATELY; the browser URL is fetched in the
/// background (AppleScript can take 100–300 ms) and filled in when it
/// arrives. Pressing Enter saves and dismisses; Escape cancels.
///
/// Error feedback: fetch problems (Automation permission denied, browser
/// unreadable) show an actionable status line. A failed database write
/// shows an error banner and KEEPS THE PANEL OPEN so nothing typed is lost.
final class CapturePanel {

    private var panel: NSPanel!
    private var urlField: NSTextField!
    private var commentField: NSTextField!
    private var statusLabel: NSTextField!
    private var session = CaptureSession()
    /// App that was frontmost before the panel activated, so dismissing the
    /// panel returns keyboard focus cleanly without a mouse click.
    private var previousApp: NSRunningApplication?

    // One reusable confirmation/error banner (previously a new NSWindow was
    // allocated on every save).
    private var bannerWindow: NSWindow?
    private var bannerLabel: NSTextField?
    /// Pending auto-hide for the banner; cancelled when a newer banner
    /// arrives so an old timer can't dismiss the new message early.
    private var bannerHideWork: DispatchWorkItem?

    init() {
        buildUI()
    }

    // MARK: - Public

    func show(front: URLFetcher.FrontApp? = URLFetcher.detectFrontmost()) {
        // Identify the frontmost app synchronously, *before* this panel
        // steals focus. The URL fetch itself runs in the background.
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let front, front.pid != myPID {
            previousApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == front.pid }
        } else {
            previousApp = nil
        }

        let request = session.begin(sourceApp: front?.name ?? "")
        let isBrowser = front.map {
            URLFetcher.isSupportedBrowser(name: $0.name, bundleId: $0.bundleId)
        } ?? false

        urlField.stringValue = ""
        commentField.stringValue = ""
        statusLabel.stringValue = front.map {
            isBrowser ? "From \($0.name) — fetching URL…" : "From \($0.name) — paste a URL or type a note…"
        } ?? "Type a URL or note…"

        positionNearMouseOrCenter()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // When a supported browser is frontmost, focus the note field right
        // away so typing immediately doesn't clobber the URL field while the
        // browser fetch is in flight.
        panel.makeFirstResponder(isBrowser ? commentField : urlField)

        guard let front else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let captured = URLFetcher.capture(app: front)
            DispatchQueue.main.async { self.apply(captured, request: request) }
        }
    }

    private func apply(_ captured: URLFetcher.Result, request: UUID) {
        guard session.apply(captured, request: request) else { return }
        // Don't clobber text the user has already typed while the browser
        // script was still in flight.
        if urlField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            urlField.stringValue = captured.url
        }
        statusLabel.stringValue = captured.failureMessage
            ?? "From \(captured.appName) · press ↵ to save"

        let editingURL = urlField.currentEditor().map { panel.firstResponder === $0 } ?? false
        if captured.url.isEmpty {
            if urlField.stringValue.isEmpty && commentField.stringValue.isEmpty {
                panel.makeFirstResponder(urlField)
            }
        } else if commentField.stringValue.isEmpty && !editingURL {
            panel.makeFirstResponder(commentField)
        }
    }

    // MARK: - UI construction

    private func buildUI() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 168),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.title = "ZoneCapture"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        self.panel = panel

        let content = panel.contentView!
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true

        let urlLabel = makeLabel("URL")
        urlField = makeTextField(placeholder: "https://…")

        let commentLabel = makeLabel("Note")
        commentField = makeTextField(placeholder: "What's worth remembering here?")

        let statusLabel = makeLabel("")
        statusLabel.alignment = .left
        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.statusLabel = statusLabel

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1B}"  // Escape
        cancelButton.isBordered = true
        cancelButton.bezelStyle = .roundRect

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"  // Return
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .regular

        let grid = NSGridView(frame: content.bounds)
        grid.autoresizingMask = [.width, .height]
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setContentHuggingPriority(.defaultLow, for: .horizontal)

        grid.addRow(with: [urlLabel, urlField])
        grid.addRow(with: [commentLabel, commentField])
        grid.addRow(with: [makeSpacer(), statusLabel])

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        let buttonContainer = NSView()
        buttonContainer.addSubview(buttonRow)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonRow.trailingAnchor.constraint(equalTo: buttonContainer.trailingAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: buttonContainer.topAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: buttonContainer.bottomAnchor),
            buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: buttonContainer.leadingAnchor),
        ])
        grid.addRow(with: [makeSpacer(), buttonContainer])

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }

    private func makeTextField(placeholder: String) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(save(_:))
        return field
    }

    private func makeSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    // MARK: - Positioning

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
    }

    private func positionNearMouseOrCenter() {
        guard let visible = screenUnderMouse()?.visibleFrame else { return }
        // Center horizontally on the screen with the mouse, near the top so
        // it appears where the eye already is.
        var frame = panel.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.maxY - frame.height - 80
        panel.setFrame(frame, display: true)
    }

    // MARK: - Actions

    private func dismiss() {
        session.end()
        panel.orderOut(nil)
        if let prev = previousApp,
           prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate(options: [])
        }
        previousApp = nil
    }

    @objc private func cancel() {
        dismiss()
    }

    @objc private func save(_ sender: Any?) {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = commentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing to record: an empty URL plus an empty note would only add a
        // junk row (e.g. accidental hotkey + Return). Dismiss silently.
        guard !url.isEmpty || !comment.isEmpty else {
            dismiss()
            return
        }

        // Allow a note-only capture when no browser URL was grabbed (feature 3
        // groundwork): record the frontmost app name so the row is still useful.
        let kind = url.isEmpty ? "note" : "url"
        let recordedURL = url.isEmpty ? "(no url — note from \(session.sourceApp))" : url

        let id = Store.shared.insertLink(
            url: recordedURL,
            title: session.title(for: url),
            comment: comment.isEmpty ? nil : comment,
            sourceApp: session.sourceApp,
            kind: kind)

        if id < 0 {
            // Database write failed. Keep the panel open so nothing typed is
            // lost, and tell the user clearly how to retry.
            statusLabel.stringValue =
                "✗ Save failed (database error) — press ↵ to retry. Details in Console."
            flashBanner("✗ Save failed")
            return
        }

        flashBanner("✓ Captured")
        dismiss()
    }

    func showBanner(_ text: String, duration: TimeInterval? = nil) {
        flashBanner(text, duration: duration)
    }

    private func flashBanner(_ text: String, duration: TimeInterval? = nil) {
        // Brief visual confirmation (or error notice). Reuses one window.
        if bannerWindow == nil {
            let banner = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            banner.isOpaque = false
            banner.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
            banner.level = .floating
            banner.isReleasedWhenClosed = false
            banner.contentView?.wantsLayer = true
            banner.contentView?.layer?.cornerRadius = 10
            banner.contentView?.layer?.masksToBounds = true

            let label = NSTextField(wrappingLabelWithString: text)
            label.alignment = .center
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byWordWrapping
            label.preferredMaxLayoutWidth = 480
            label.translatesAutoresizingMaskIntoConstraints = false
            banner.contentView?.addSubview(label)
            if let cv = banner.contentView {
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
                    label.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
                    label.topAnchor.constraint(equalTo: cv.topAnchor, constant: 10),
                    label.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -10),
                ])
            }
            bannerWindow = banner
            bannerLabel = label
        }
        guard let banner = bannerWindow, let label = bannerLabel else { return }
        label.stringValue = text
        let maxTextWidth: CGFloat = 480
        let fitted = label.sizeThatFits(NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude))
        let width = min(max(ceil(fitted.width) + 32, 220), 520)
        let height = max(ceil(fitted.height) + 20, 44)
        if let screen = screenUnderMouse() {
            let visible = screen.visibleFrame
            let frame = NSRect(
                x: visible.midX - width / 2,
                y: visible.maxY - height - 80,
                width: width,
                height: height)
            banner.setFrame(frame, display: true)
        }
        banner.orderFront(nil)
        bannerHideWork?.cancel()
        let isNotice = text.hasPrefix("✗") || text.hasPrefix("⚠")
        let effectiveDuration = duration ?? (isNotice ? 3.5 : 1.4)
        let work = DispatchWorkItem { [weak banner] in
            banner?.orderOut(nil)
        }
        bannerHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration, execute: work)
    }
}
