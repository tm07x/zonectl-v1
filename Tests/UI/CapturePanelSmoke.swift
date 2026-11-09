import AppKit
import ZoneCaptureCore

guard let root = ProcessInfo.processInfo.environment["ZONE_CAPTURE_ROOT"], !root.isEmpty,
      let screenshot = ProcessInfo.processInfo.environment["ZONE_CAPTURE_SCREENSHOT"] else {
    fatalError("The UI smoke check requires disposable storage and a screenshot destination")
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
let capture = CapturePanel()

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    capture.show(front: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        do {
            guard let window = app.windows.first(where: { $0.title == "ZoneCapture" }),
                  let content = window.contentView,
                  let grid = content.subviews.compactMap({ $0 as? NSGridView }).first,
                  let url = grid.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSTextField,
                  let note = grid.cell(atColumnIndex: 1, rowIndex: 1).contentView as? NSTextField else {
                fatalError("Capture panel did not render its editable fields")
            }
            url.stringValue = "https://example.com/research"
            note.stringValue = "Disposable CI capture"
            window.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                fatalError("Could not render the capture panel")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Could not encode the rendered panel")
            }
            try png.write(to: URL(fileURLWithPath: screenshot))
            precondition(app.sendAction(NSSelectorFromString("save:"), to: capture, from: nil))
            let rows = try Store.shared.readRecent()
            precondition(rows.count == 1 && rows[0].url == url.stringValue)
            precondition(rows[0].title == nil && rows[0].comment == note.stringValue)
            precondition(!window.isVisible)
            capture.show(front: nil)
            precondition(url.stringValue.isEmpty && note.stringValue.isEmpty)
            precondition(app.sendAction(NSSelectorFromString("cancel"), to: capture, from: nil))
            precondition(!window.isVisible)
            print("Capture panel rendered, saved to disposable storage, reopened, and cancelled")
            exit(0)
        } catch {
            fatalError("Capture panel smoke check failed: \(error)")
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    fatalError("Capture panel smoke check timed out")
}
app.run()
