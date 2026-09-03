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
/// The URL field is pre-filled from the frontmost browser and left editable so
/// you can fix it if the AppleScript grab missed. Pressing Enter saves and
/// dismisses; Escape cancels.
final class CapturePanel {

    private var panel: NSPanel!
    private var urlField: NSTextField!
    private var commentField: NSTextField!
    private var statusLabel: NSTextField!
    private var sourceApp: String = ""
    private var sourceTitle: String?

    init() {
        buildUI()
    }

    // MARK: - Public

    func show() {
        // Grab the URL *before* our panel steals focus, while the browser is
        // still the frontmost app.
        let captured = URLFetcher.captureFrontmost()
        sourceApp = captured?.appName ?? ""
        // Remember the tab title so Save can persist it alongside the URL.
        sourceTitle = (captured?.title?.isEmpty == false) ? captured?.title : nil

        urlField.stringValue = captured?.url ?? ""
        commentField.stringValue = ""

        if let captured, captured.url.isEmpty {
            statusLabel.stringValue = "No URL from \(sourceApp) — paste one or type a note."
        } else {
            statusLabel.stringValue = "From \(sourceApp) · press ↵ to save"
        }

        positionNearMouseOrCenter()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Focus the comment field if we already have a URL, else the URL field.
        if (captured?.url.isEmpty ?? true) {
            panel.makeFirstResponder(urlField)
        } else {
            panel.makeFirstResponder(commentField)
        }
    }

    // MARK: - UI construction

    private func buildUI() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 168),
            styleMask: [.titled, .titled, .closable, .fullSizeContentView],
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
        commentField.action = #selector(save(_:))

        let statusLabel = makeLabel("")
        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        self.statusLabel = statusLabel

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1B}"  // Escape
        cancelButton.isBordered = true
        cancelButton.bezelStyle = .roundRect

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
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
        grid.addRow(with: [statusLabel, makeSpacer()])

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
        field.action = #selector(save)
        return field
    }

    private func makeSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    // MARK: - Positioning

    private func positionNearMouseOrCenter() {
        if let screen = NSScreen.main {
            let mouse = NSEvent.mouseLocation
            let screenFrame = screen.visibleFrame
            var frame = panel.frame
            // Center horizontally on the screen that has the mouse, just below
            // the top so it appears where the eye already is.
            let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? screen
            let visible = targetScreen.visibleFrame
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.maxY - frame.height - 80
            panel.setFrame(frame, display: true)
            _ = screenFrame
        }
    }

    // MARK: - Actions

    @objc private func cancel() {
        panel.orderOut(nil)
    }

    @objc private func save(_ sender: Any?) {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = commentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing to record: an empty URL plus an empty note would only add a
        // junk row (e.g. accidental hotkey + Return). Dismiss silently.
        guard !url.isEmpty || !comment.isEmpty else {
            panel.orderOut(nil)
            return
        }

        // Allow a note-only capture when no browser URL was grabbed (feature 3
        // groundwork): record the frontmost app name so the row is still useful.
        let kind = url.isEmpty ? "note" : "url"
        let recordedURL = url.isEmpty ? "(no url — note from \(sourceApp))" : url

        Store.shared.insertLink(
            url: recordedURL,
            title: url.isEmpty ? nil : sourceTitle,
            comment: comment.isEmpty ? nil : comment,
            sourceApp: sourceApp,
            kind: kind)

        flashSuccess()
        panel.orderOut(nil)
    }

    private func flashSuccess() {
        // Brief visual confirmation that the capture landed.
        let banner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        banner.isOpaque = false
        banner.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        banner.level = .floating
        banner.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "✓ Captured")
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        banner.contentView?.addSubview(label)
        if let cv = banner.contentView {
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
            ])
        }
        if let screen = NSScreen.main {
            var f = banner.frame
            f.origin.x = screen.visibleFrame.midX - f.width / 2
            f.origin.y = screen.visibleFrame.maxY - 120
            banner.setFrame(f, display: true)
        }
        banner.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            banner.orderOut(nil)
        }
    }
}
