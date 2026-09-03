import AppKit

// Entry point. We bootstrap an LSUIElement app (no Dock icon, no main menu bar)
// and hand control to the AppDelegate, which installs the menu-bar item and the
// global hotkey.

// Single-instance guard: the login item can fire via SMAppService and via the
// launchd agent (~/Library/LaunchAgents/com.grokink.zonecapture.login.plist).
// If a second launch lands while one instance is already up, bow out quietly.
if let bundleID = Bundle.main.bundleIdentifier,
   !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
    NSLog("[ZoneCapture] another instance is already running — exiting.")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Keep a strong reference: NSApplication.delegate is weak.
let delegate = AppDelegate()
app.delegate = delegate
app.run()
