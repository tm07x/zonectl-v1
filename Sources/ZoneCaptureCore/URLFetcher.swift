import AppKit

/// Reads the URL (and title) of the active tab in the frontmost browser via
/// AppleScript. Each supported browser needs its own script because they
/// expose different AppleScript dictionaries.
public enum URLFetcher {

    public struct Result {
        public let url: String
        public let title: String?
        public let appName: String

        public init(url: String, title: String?, appName: String) {
            self.url = url
            self.title = title
            self.appName = appName
        }
    }

    /// Inspect the frontmost app and, if it's a known browser, pull its tab URL.
    public static func captureFrontmost() -> Result? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = front.localizedName ?? "Unknown"
        let bundleId = front.bundleIdentifier ?? ""

        let script = scriptForApp(name: name, bundleId: bundleId)
        guard let script else {
            // Not a browser we know how to query. Return the app name only so
            // the panel can still record a manual note (feature 3 territory).
            return Result(url: "", title: nil, appName: name)
        }

        var errorInfo: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let output = appleScript.executeAndReturnError(&errorInfo)
            if let err = errorInfo {
                NSLog("[ZoneCapture] AppleScript error from \(name): \(err)")
                return Result(url: "", title: nil, appName: name)
            }
            let parsed = parse(output.stringValue ?? "")
            return Result(url: parsed.url, title: parsed.title, appName: name)
        }
        return Result(url: "", title: nil, appName: name)
    }

    // MARK: - Script selection

    /// Returns the AppleScript source for a known browser, or nil for
    /// unsupported apps (Firefox, unknown). Internal so tests can verify
    /// selection logic without running AppleScript against a real browser.
    static func scriptForApp(name: String, bundleId: String) -> String? {
        let n = name.lowercased()

        if n.contains("safari") {
            return """
            tell application "Safari"
                set theURL to URL of front document
                set theTitle to name of front document
                return theURL & linefeed & theTitle
            end tell
            """
        }
        if n.contains("chrome") || bundleId.contains("chrome") {
            return """
            tell application "Google Chrome"
                set theURL to URL of active tab of front window
                set theTitle to title of active tab of front window
                return theURL & linefeed & theTitle
            end tell
            """
        }
        if n.contains("edge") || bundleId.contains("edge") {
            return """
            tell application "Microsoft Edge"
                set theURL to URL of active tab of front window
                set theTitle to title of active tab of front window
                return theURL & linefeed & theTitle
            end tell
            """
        }
        if n.contains("brave") || bundleId.contains("brave") {
            return """
            tell application "Brave Browser"
                set theURL to URL of active tab of front window
                set theTitle to title of active tab of front window
                return theURL & linefeed & theTitle
            end tell
            """
        }
        if n.contains("arc") || bundleId.contains("arc") {
            // Arc exposes the active tab via its Chrome-compatible dictionary.
            return """
            tell application "Arc"
                set theURL to URL of active tab of front window
                set theTitle to title of active tab of front window
                return theURL & linefeed & theTitle
            end tell
            """
        }
        if n.contains("firefox") || bundleId.contains("firefox") {
            // Firefox ships no tab-URL AppleScript dictionary by default.
            // Fall through: user can paste the URL manually.
            return nil
        }
        return nil
    }

    /// Parses the raw AppleScript output (URL on line 1, optional title on
    /// line 2) into a (url, title) tuple. Internal so tests can verify the
    /// parsing edge cases without a live browser.
    static func parse(_ raw: String) -> (url: String, title: String?) {
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let url = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let title = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        return (url, title)
    }
}
