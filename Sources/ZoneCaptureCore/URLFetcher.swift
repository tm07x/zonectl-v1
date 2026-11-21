import AppKit
import ApplicationServices

/// Reads the URL (and title) of the active tab in the frontmost browser.
///
/// Browser identification prefers EXACT bundle identifiers (locale-
/// independent, no false positives). Human-readable names are only a
/// fallback and must match canonical names exactly — the old substring
/// matching could route an unrelated app (anything containing "edge" or
/// "arc") to a browser's AppleScript, which can launch the wrong browser.
public enum URLFetcher {

    /// Failure causes the UI surfaces distinctly, so the user gets
    /// actionable feedback instead of a silently empty field.
    public enum FetchError {
        /// TCC denied the Apple Event (-1743). The user must grant
        /// ZoneCapture permission to control that browser under
        /// System Settings → Privacy & Security → Automation.
        case automationDenied
        /// Accessibility permission has not been granted, so Firefox's
        /// address bar cannot be read.
        case accessibilityDenied
        /// The script failed for any other reason: browser not running,
        /// no open window/tab, scripting error, etc.
        case browserNotRunningOrNoTabs
    }

    public struct Result {
        public let url: String
        public let title: String?
        public let appName: String
        public let error: FetchError?

        public init(url: String, title: String?, appName: String, error: FetchError? = nil) {
            self.url = url
            self.title = title
            self.appName = appName
            self.error = error
        }

        public var failureMessage: String? {
            switch error {
            case .automationDenied:
                return "Permission needed: allow ZoneCapture to control \(appName) " +
                    "under System Settings → Privacy & Security → Automation."
            case .accessibilityDenied:
                return "Permission needed: allow ZoneCapture under " +
                    "System Settings → Privacy & Security → Accessibility to read \(appName) tabs."
            case .browserNotRunningOrNoTabs:
                return "Couldn't read a tab from \(appName) — paste the URL."
            case nil:
                return url.isEmpty ? "No URL from \(appName) — paste one or type a note." : nil
            }
        }
    }

    /// Identity of the frontmost application, captured synchronously so the
    /// caller can fetch its tab URL *after* another window (the capture
    /// panel) has taken focus.
    public struct FrontApp {
        public let name: String
        public let bundleId: String
        public let pid: pid_t
    }

    /// Serializes `NSAppleScript` execution: Apple's OSA runtime is not
    /// thread-safe when invoked concurrently from global queues.
    private static let scriptQueue = DispatchQueue(label: "com.grokink.zonecapture.applescript")

    // MARK: - Frontmost detection (synchronous, cheap)

    public static func detectFrontmost() -> FrontApp? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontApp(
            name: front.localizedName ?? "Unknown",
            bundleId: front.bundleIdentifier ?? "",
            pid: front.processIdentifier)
    }

    /// Returns true if the given app is a browser ZoneCapture knows how to
    /// read a URL from (via AppleScript or Firefox Accessibility).
    public static func isSupportedBrowser(name: String, bundleId: String) -> Bool {
        browser(name: name, bundleId: bundleId) != nil || isFirefox(name: name, bundleId: bundleId)
    }

    // MARK: - Fetching (may block ~100–300 ms; safe off the main thread)

    /// Fetches the active tab from an already-detected frontmost app.
    public static func capture(app: FrontApp) -> Result {
        if let script = scriptForApp(name: app.name, bundleId: app.bundleId) {
            return runScript(script, appName: app.name)
        }
        if isFirefox(name: app.name, bundleId: app.bundleId) {
            // Firefox has no tab-URL AppleScript dictionary. Best effort via
            // the Accessibility API (address bar of the focused window);
            // surface a clear permission hint when Accessibility isn't granted.
            guard AXIsProcessTrusted() else {
                return Result(url: "", title: nil, appName: app.name, error: .accessibilityDenied)
            }
            if let fx = firefoxTabInfo(pid: app.pid) {
                return Result(url: fx.url, title: fx.title, appName: app.name)
            }
            return Result(url: "", title: nil, appName: app.name, error: .browserNotRunningOrNoTabs)
        }
        // Not a browser we can read; the panel can still record a note.
        return Result(url: "", title: nil, appName: app.name)
    }

    /// Convenience wrapper: detect + fetch in one blocking call.
    public static func captureFrontmost() -> Result? {
        guard let front = detectFrontmost() else { return nil }
        return capture(app: front)
    }

    // MARK: - Browser table

    private struct Browser {
        let bundleIds: [String]   // exact, compared case-insensitively
        let names: [String]       // exact canonical names, lowercased
        let target: String        // AppleScript application target
    }

    private static let browsers: [Browser] = [
        Browser(bundleIds: ["com.apple.safari"],
                names: ["safari"],
                target: "Safari"),
        Browser(bundleIds: ["com.google.chrome"],
                names: ["google chrome", "chrome"],
                target: "Google Chrome"),
        Browser(bundleIds: ["com.microsoft.edgemac"],
                names: ["microsoft edge"],
                target: "Microsoft Edge"),
        Browser(bundleIds: ["com.brave.browser"],
                names: ["brave browser", "brave"],
                target: "Brave Browser"),
        Browser(bundleIds: ["com.brave.browser.beta"],
                names: ["brave browser beta"],
                target: "Brave Browser Beta"),
        Browser(bundleIds: ["com.brave.browser.nightly"],
                names: ["brave browser nightly"],
                target: "Brave Browser Nightly"),
        Browser(bundleIds: ["company.thebrowser.browser"],
                names: ["arc"],
                target: "Arc"),
    ]

    private static let firefoxBundles = [
        "org.mozilla.firefox", "org.mozilla.firefoxbeta", "org.mozilla.nightly",
        "org.mozilla.firefoxdeveloperedition",
    ]
    private static let firefoxNames = ["firefox", "firefox developer edition", "firefox nightly"]

    // MARK: - Script selection

    /// Returns the AppleScript source for a known browser, or nil for
    /// unsupported apps. Firefox returns nil here (handled via the
    /// Accessibility API in `capture(app:)`). Internal so tests can verify
    /// selection logic without running AppleScript against a real browser.
    static func scriptForApp(name: String, bundleId: String) -> String? {
        guard let browser = browser(name: name, bundleId: bundleId) else { return nil }
        return script(for: browser.target)
    }

    private static func browser(name: String, bundleId: String) -> Browser? {
        let bid = bundleId.lowercased()
        let n = name.lowercased()
        if !bid.isEmpty {
            return browsers.first { $0.bundleIds.contains(bid) }
        }
        return browsers.first { $0.names.contains(n) }
    }

    static func isFirefox(name: String, bundleId: String) -> Bool {
        bundleId.isEmpty
            ? firefoxNames.contains(name.lowercased())
            : firefoxBundles.contains(bundleId.lowercased())
    }

    private static func script(for target: String) -> String {
        if target == "Safari" {
            return """
            tell application "Safari"
                set theURL to URL of front document
                set theTitle to name of front document
                return theURL & linefeed & theTitle
            end tell
            """
        }
        return """
        tell application "\(target)"
            set theURL to URL of active tab of front window
            set theTitle to title of active tab of front window
            return theURL & linefeed & theTitle
        end tell
        """
    }

    // MARK: - Script execution + error mapping

    private static func runScript(_ source: String, appName: String) -> Result {
        scriptQueue.sync {
            guard let appleScript = NSAppleScript(source: source) else {
                return Result(url: "", title: nil, appName: appName,
                              error: .browserNotRunningOrNoTabs)
            }
            var errorInfo: NSDictionary?
            let output = appleScript.executeAndReturnError(&errorInfo)
            if let err = errorInfo {
                let number = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                NSLog("[ZoneCapture] AppleScript error from \(appName) (\(number)): \(err)")
                // -1743 == errAEEventNotPermitted: Automation permission denied.
                let kind: FetchError = (number == -1743)
                    ? .automationDenied
                    : .browserNotRunningOrNoTabs
                return Result(url: "", title: nil, appName: appName, error: kind)
            }
            let parsed = parse(output.stringValue ?? "")
            return Result(url: parsed.url, title: parsed.title, appName: appName)
        }
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

    // MARK: - Firefox via Accessibility (best effort)

    /// Normalizes a value read from Firefox's address bar into an HTTP(S) URL.
    /// Modern Firefox strips `https://` from the displayed field and may show
    /// bare hosts (`example.com/path`) or `localhost:3000`. Non-URL values
    /// (search queries with spaces, `about:` pages, etc.) return nil.
    static func normalizeFirefoxURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let comps = URLComponents(string: trimmed),
                  let host = comps.host, !host.isEmpty else {
                return nil
            }
            return trimmed
        }
        let slash = trimmed.firstIndex(of: "/") ?? trimmed.endIndex
        if let colon = trimmed.firstIndex(of: ":"), colon < slash {
            let beforeColon = trimmed[..<colon]
            let afterColon = trimmed[trimmed.index(after: colon)..<slash]
            let isPort = !afterColon.isEmpty && afterColon.allSatisfy(\.isNumber)
            if !isPort && !beforeColon.contains(".") {
                return nil
            }
        }
        if lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("localhost/") {
            return "http://" + trimmed
        }
        guard trimmed.contains(".") else { return nil }
        let candidate = "https://" + trimmed
        guard let comps = URLComponents(string: candidate),
              let host = comps.host, !host.isEmpty else {
            return nil
        }
        return candidate
    }

    /// Reads the address bar (AXIdentifier "urlbar-input" or "urlbar") and
    /// window title from Firefox's accessibility tree. Returns nil whenever
    /// the structure is not found — the panel then falls back to manual paste.
    static func firefoxTabInfo(pid: pid_t) -> (url: String, title: String?)? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windowRef = axAttribute(appElement, kAXFocusedWindowAttribute),
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(windowRef, to: AXUIElement.self)
        let title = axAttribute(window, kAXTitleAttribute) as? String

        var found: String?
        walk(window, depth: 0) { elem in
            guard found == nil else { return false }
            let role = axAttribute(elem, kAXRoleAttribute) as? String
            if role == kAXTextFieldRole || role == "AXComboBox" {
                let identifier = axAttribute(elem, "AXIdentifier") as? String
                if (identifier == "urlbar-input" || identifier == "urlbar"),
                   let value = axAttribute(elem, kAXValueAttribute) as? String,
                   let normalized = normalizeFirefoxURL(value) {
                    found = normalized
                    return false
                }
            }
            return true
        }
        guard let url = found else { return nil }
        return (url, title)
    }

    private static func walk(_ elem: AXUIElement, depth: Int, visit: (AXUIElement) -> Bool) {
        guard depth < 20 else { return }
        guard visit(elem) else { return }
        guard let childrenRef = axAttribute(elem, kAXChildrenAttribute),
              CFGetTypeID(childrenRef) == CFArrayGetTypeID() else { return }
        let children = unsafeDowncast(childrenRef, to: CFArray.self)
        for i in 0..<CFArrayGetCount(children) {
            guard let raw = CFArrayGetValueAtIndex(children, i) else { continue }
            let child = unsafeBitCast(raw, to: AXUIElement.self)
            walk(child, depth: depth + 1, visit: visit)
        }
    }

    private static func axAttribute(_ elem: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
