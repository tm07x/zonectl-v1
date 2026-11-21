import XCTest
@testable import ZoneCaptureCore

final class BrowserFeedbackTests: XCTestCase {
    func testAutomationDenialProvidesSettingsPathForUnattendedCapture() throws {
        let result = URLFetcher.Result(url: "", title: nil, appName: "Brave Browser Beta", error: .automationDenied)
        let message = try XCTUnwrap(result.failureMessage)
        XCTAssertTrue(message.contains("Brave Browser Beta"))
        XCTAssertTrue(message.contains("System Settings → Privacy & Security → Automation"))
    }

    func testOtherFetchFailuresStayDistinctFromNoURL() throws {
        let failed = URLFetcher.Result(url: "", title: nil, appName: "Safari", error: .browserNotRunningOrNoTabs)
        let empty = URLFetcher.Result(url: "", title: nil, appName: "Xcode")
        XCTAssertTrue(try XCTUnwrap(failed.failureMessage).contains("Couldn't read a tab"))
        XCTAssertTrue(try XCTUnwrap(empty.failureMessage).contains("No URL from Xcode"))
        XCTAssertNotEqual(failed.failureMessage, empty.failureMessage)
        XCTAssertNil(URLFetcher.Result(url: "https://example.com", title: nil, appName: "Safari").failureMessage)
    }

    func testBundleIDTakesPrecedenceOverConflictingName() throws {
        let script = try XCTUnwrap(URLFetcher.scriptForApp(name: "Safari", bundleId: "com.brave.Browser.beta"))
        XCTAssertTrue(script.contains("Brave Browser Beta"))
        XCTAssertFalse(script.contains("tell application \"Safari\""))
    }

    func testUnknownNonemptyBundleIDCannotImpersonateBrowserByName() {
        XCTAssertNil(URLFetcher.scriptForApp(name: "Safari", bundleId: "example.not-safari"))
        XCTAssertFalse(URLFetcher.isFirefox(name: "Firefox", bundleId: "example.not-firefox"))
        XCTAssertNotNil(URLFetcher.scriptForApp(name: "Safari", bundleId: ""))
        XCTAssertTrue(URLFetcher.isFirefox(name: "Firefox", bundleId: ""))
    }

    func testFirefoxDeveloperEditionUsesItsExactBundleID() {
        XCTAssertTrue(URLFetcher.isFirefox(
            name: "Firefox Developer Edition", bundleId: "org.mozilla.firefoxdeveloperedition"))
        XCTAssertTrue(URLFetcher.isFirefox(
            name: "Localized browser name", bundleId: "ORG.MOZILLA.FIREFOXDEVELOPEREDITION"))
        XCTAssertFalse(URLFetcher.isFirefox(
            name: "Firefox Developer Edition", bundleId: "example.not-firefox"))
        XCTAssertNil(URLFetcher.scriptForApp(
            name: "Firefox Developer Edition", bundleId: "org.mozilla.firefoxdeveloperedition"))
    }

    func testAccessibilityDenialProvidesSettingsPathForFirefox() throws {
        let result = URLFetcher.Result(url: "", title: nil, appName: "Firefox", error: .accessibilityDenied)
        let message = try XCTUnwrap(result.failureMessage)
        XCTAssertTrue(message.contains("Firefox"))
        XCTAssertTrue(message.contains("System Settings → Privacy & Security → Accessibility"))
    }

    func testIsSupportedBrowserMatchesScriptedAndFirefoxBrowsersOnly() {
        XCTAssertTrue(URLFetcher.isSupportedBrowser(name: "Safari", bundleId: "com.apple.Safari"))
        XCTAssertTrue(URLFetcher.isSupportedBrowser(name: "Brave Browser", bundleId: "com.brave.Browser.beta"))
        XCTAssertTrue(URLFetcher.isSupportedBrowser(name: "Firefox", bundleId: "org.mozilla.firefox"))
        XCTAssertTrue(URLFetcher.isSupportedBrowser(
            name: "Firefox Developer Edition", bundleId: "org.mozilla.firefoxdeveloperedition"))
        XCTAssertFalse(URLFetcher.isSupportedBrowser(name: "Xcode", bundleId: "com.apple.dt.Xcode"))
        XCTAssertFalse(URLFetcher.isSupportedBrowser(name: "Safari", bundleId: "example.not-safari"))
    }

    func testNormalizeFirefoxURLHandlesBareHostsLocalhostAndRejectsNonURLs() {
        XCTAssertEqual(URLFetcher.normalizeFirefoxURL("https://example.com/path"), "https://example.com/path")
        XCTAssertEqual(URLFetcher.normalizeFirefoxURL("http://localhost:3000/app"), "http://localhost:3000/app")
        XCTAssertEqual(URLFetcher.normalizeFirefoxURL("localhost:8080/docs"), "http://localhost:8080/docs")
        XCTAssertEqual(URLFetcher.normalizeFirefoxURL("example.com/docs/a:b"), "https://example.com/docs/a:b")
        XCTAssertEqual(URLFetcher.normalizeFirefoxURL("example.com:8443/x"), "https://example.com:8443/x")
        XCTAssertNil(URLFetcher.normalizeFirefoxURL(""))
        XCTAssertNil(URLFetcher.normalizeFirefoxURL("about:blank"))
        XCTAssertNil(URLFetcher.normalizeFirefoxURL("javascript:alert(1)"))
        XCTAssertNil(URLFetcher.normalizeFirefoxURL("ftp://example.com/file"))
        XCTAssertNil(URLFetcher.normalizeFirefoxURL("how to install linux"))
        XCTAssertNil(URLFetcher.normalizeFirefoxURL("justaword"))
    }
}
