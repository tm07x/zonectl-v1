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
}
