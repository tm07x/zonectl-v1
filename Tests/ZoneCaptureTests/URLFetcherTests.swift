import XCTest
@testable import ZoneCaptureCore

/// Tests for URLFetcher — the AppleScript generation and output-parsing logic.
///
/// We test ONLY the pure logic:
///   - `parse()`: string splitting of AppleScript output into (url, title).
///   - `scriptForApp()`: which AppleScript source (if any) is selected for a
///     given browser name/bundle id.
///
/// We intentionally do NOT test `captureFrontmost()` against a real browser.
/// That method executes AppleScript via `NSAppleScript.executeAndReturnError`,
/// which requires a running browser, accessibility/automation permissions, and
/// human interaction to grant the TCC prompt. These are integration-test
/// concerns, not unit-test concerns.
final class URLFetcherTests: XCTestCase {

    // MARK: - parse

    func testParseUrlOnly() {
        // Single line: just a URL, no title.
        let result = URLFetcher.parse("https://example.com/page")
        XCTAssertEqual(result.url, "https://example.com/page")
        XCTAssertNil(result.title,
            "Single-line input should produce nil title")
    }

    func testParseUrlAndTitle() {
        // Two lines: URL then title separated by a newline.
        let result = URLFetcher.parse("https://example.com/page\nMy Page Title")
        XCTAssertEqual(result.url, "https://example.com/page")
        XCTAssertEqual(result.title, "My Page Title")
    }

    func testParseEmptyInput() {
        // Empty string: url should be empty, title nil.
        let result = URLFetcher.parse("")
        XCTAssertEqual(result.url, "")
        XCTAssertNil(result.title)
    }

    func testParseUrlWithWhitespaceTrimmed() {
        // Leading/trailing whitespace around URL and title should be trimmed.
        let result = URLFetcher.parse("  https://example.com  \n  Trimmed Title  ")
        XCTAssertEqual(result.url, "https://example.com")
        XCTAssertEqual(result.title, "Trimmed Title")
    }

    func testParseUrlWithNewlineOnly() {
        // Just a newline: url is empty (trimmed), title is empty string (trimmed
        // from empty). Actually split on "\n" with maxSplits 1 gives ["", ""].
        // The first part is "" -> trimmed "" -> url "". The second part is ""
        // -> trimmed "" -> title "" (not nil, because parts.count > 1).
        let result = URLFetcher.parse("\n")
        XCTAssertEqual(result.url, "")
        // title is "" (empty string, not nil) because there IS a second part
        XCTAssertEqual(result.title, "")
    }

    // MARK: - scriptForApp: supported browsers

    func testScriptForSafari() {
        let script = URLFetcher.scriptForApp(name: "Safari", bundleId: "com.apple.Safari")
        XCTAssertNotNil(script)
        if let script {
            XCTAssertTrue(script.contains("tell application \"Safari\""),
                "Safari script should target the Safari app")
            XCTAssertTrue(script.contains("URL of front document"),
                "Safari script should read URL of front document")
        }
    }

    func testScriptForChrome() {
        let script = URLFetcher.scriptForApp(
            name: "Google Chrome", bundleId: "com.google.Chrome")
        XCTAssertNotNil(script)
        if let script {
            XCTAssertTrue(script.contains("tell application \"Google Chrome\""))
            XCTAssertTrue(script.contains("active tab of front window"))
        }
    }

    func testScriptForEdge() {
        let script = URLFetcher.scriptForApp(
            name: "Microsoft Edge", bundleId: "com.microsoft.edgemac")
        XCTAssertNotNil(script)
        if let script {
            XCTAssertTrue(script.contains("tell application \"Microsoft Edge\""))
        }
    }

    func testScriptForBrave() {
        let script = URLFetcher.scriptForApp(
            name: "Brave Browser", bundleId: "com.brave.Browser")
        XCTAssertNotNil(script)
        if let script {
            XCTAssertTrue(script.contains("tell application \"Brave Browser\""))
        }
    }

    func testScriptForArc() {
        let script = URLFetcher.scriptForApp(
            name: "Arc", bundleId: "company.thebrowser.Browser")
        XCTAssertNotNil(script)
        if let script {
            XCTAssertTrue(script.contains("tell application \"Arc\""))
        }
    }

    // MARK: - scriptForApp: unsupported / unknown

    func testScriptForFirefoxReturnsNil() {
        let script = URLFetcher.scriptForApp(
            name: "Firefox", bundleId: "org.mozilla.firefox")
        XCTAssertNil(script,
            "Firefox has no tab-URL AppleScript dictionary; scriptForApp should return nil")
    }

    func testScriptForUnknownAppReturnsNil() {
        let script = URLFetcher.scriptForApp(
            name: "Xcode", bundleId: "com.apple.dt.Xcode")
        XCTAssertNil(script,
            "Unknown non-browser apps should return nil from scriptForApp")
    }

    func testScriptForUnknownAppWithGenericBundleIdReturnsNil() {
        let script = URLFetcher.scriptForApp(
            name: "Finder", bundleId: "com.apple.finder")
        XCTAssertNil(script)
    }

    // MARK: - scriptForApp: case insensitivity

    func testScriptForAppIsCaseInsensitive() {
        // The name is lowercased before matching, so "SAFARI" should still match.
        let script = URLFetcher.scriptForApp(
            name: "SAFARI", bundleId: "com.apple.Safari")
        XCTAssertNotNil(script)
        if let script {
            XCTAssertTrue(script.contains("Safari"))
        }
    }

    // MARK: - scriptForApp: bundleId fallback

    func testScriptForAppMatchesOnBundleId() {
        // Name doesn't contain "chrome" but bundleId does (case-sensitive:
        // the production code checks bundleId.contains("chrome") with a
        // lowercase literal, so the bundleId must contain lowercase "chrome").
        let script = URLFetcher.scriptForApp(
            name: "MyCustomBrowser", bundleId: "com.example.chrome.ext")
        XCTAssertNotNil(script,
            "scriptForApp should fall back to bundleId matching when name doesn't match")
        if let script {
            XCTAssertTrue(script.contains("Google Chrome"))
        }
    }

    // MARK: - script content sanity

    func testAllSupportedScriptsReturnUrlAndTitle() {
        // Every supported browser script should output both URL and title,
        // separated by a linefeed, so parse() can split them.
        let browsers: [(String, String)] = [
            ("Safari", "com.apple.Safari"),
            ("Google Chrome", "com.google.Chrome"),
            ("Microsoft Edge", "com.microsoft.edgemac"),
            ("Brave Browser", "com.brave.Browser"),
            ("Arc", "company.thebrowser.Browser"),
        ]
        for (name, bundleId) in browsers {
            guard let script = URLFetcher.scriptForApp(name: name, bundleId: bundleId) else {
                XCTFail("Expected non-nil script for \(name)")
                continue
            }
            XCTAssertTrue(script.contains("theURL"),
                "\(name) script should reference theURL variable")
            XCTAssertTrue(script.contains("theTitle"),
                "\(name) script should reference theTitle variable")
            XCTAssertTrue(script.contains("linefeed"),
                "\(name) script should join URL and title with linefeed")
        }
    }

    // MARK: - captureFrontmost is NOT tested here
    //
    // captureFrontmost() calls NSWorkspace.shared.frontmostApplication and
    // executes AppleScript against whatever browser happens to be frontmost.
    // This requires:
    //   1. A running browser with an open tab.
    //   2. Automation permission (TCC) granted to the test runner.
    //   3. A deterministic frontmost app — impossible in a headless test env.
    // These are integration-test concerns. The pure logic (script selection +
    // output parsing) is fully covered above.
}
