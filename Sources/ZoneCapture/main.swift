import AppKit

// Entry point. We bootstrap an LSUIElement app (no Dock icon, no main menu bar)
// and hand control to the AppDelegate, which installs the menu-bar item and the
// global hotkey.

// Single-instance guard: the login item can fire via SMAppService and via the
// launchd agent (~/Library/LaunchAgents/com.grokink.zonecapture.login.plist).
// If a second launch lands while one instance is already up, bow out quietly.
//
// IMPORTANT: runningApplications(withBundleIdentifier:) includes THIS process,
// so we must exclude our own PID — otherwise every launch sees "itself" and
// exits immediately, which is exactly the bug that made the app never appear.
let myPID = ProcessInfo.processInfo.processIdentifier
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != myPID }
    if !others.isEmpty {
        NSLog("[ZoneCapture] another instance is already running (pid \(others.first!.processIdentifier)) — exiting.")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Keep a strong reference: NSApplication.delegate is weak.
let delegate = AppDelegate()
app.delegate = delegate
app.run()
