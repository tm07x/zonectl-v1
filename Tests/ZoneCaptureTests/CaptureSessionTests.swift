import XCTest
@testable import ZoneCaptureCore

final class CaptureSessionTests: XCTestCase {
    func testEarlierCompletionCannotPopulateReopenedSession() {
        var session = CaptureSession()
        let first = session.begin(sourceApp: "Safari")
        session.end()
        let second = session.begin(sourceApp: "Brave Browser Beta")

        XCTAssertFalse(session.apply(result("first"), request: first))
        XCTAssertNil(session.title(for: "https://example.com/first"))
        XCTAssertEqual(session.sourceApp, "Brave Browser Beta")
        XCTAssertTrue(session.apply(result("second"), request: second))
        XCTAssertFalse(session.apply(result("first"), request: first))
        XCTAssertEqual(session.title(for: "https://example.com/second"), "second")
    }

    func testDismissalInvalidatesPendingFetch() {
        var session = CaptureSession()
        let request = session.begin(sourceApp: "Safari")
        session.end()
        XCTAssertFalse(session.apply(result("first"), request: request))
        XCTAssertNil(session.title(for: "https://example.com/first"))
    }

    func testTitleIsBoundToFetchedURLBeforeAndAfterEdits() {
        var session = CaptureSession()
        let request = session.begin(sourceApp: "Safari")
        XCTAssertTrue(session.apply(result("first"), request: request))
        XCTAssertNil(session.title(for: "https://example.com/typed-before-fetch"))
        XCTAssertEqual(session.title(for: "https://example.com/first"), "first")
        XCTAssertNil(session.title(for: "https://example.com/edited-after-fetch"))
        XCTAssertNil(session.title(for: ""))
        XCTAssertEqual(session.title(for: " \nhttps://example.com/first\n"), "first")
    }

    func testNewPresentationClearsPreviousMetadata() {
        var session = CaptureSession()
        let request = session.begin(sourceApp: "Safari")
        session.apply(result("first"), request: request)
        session.begin(sourceApp: "Arc")
        XCTAssertNil(session.title(for: "https://example.com/first"))
        XCTAssertEqual(session.sourceApp, "Arc")
    }

    func testFailedFetchCannotSupplyTitle() {
        var session = CaptureSession()
        let request = session.begin(sourceApp: "Safari")
        session.apply(URLFetcher.Result(
            url: "https://example.com/first", title: "Wrong", appName: "Safari",
            error: .automationDenied), request: request)
        XCTAssertNil(session.title(for: "https://example.com/first"))
    }

    private func result(_ name: String) -> URLFetcher.Result {
        URLFetcher.Result(url: "https://example.com/\(name)", title: name, appName: "Safari")
    }
}
