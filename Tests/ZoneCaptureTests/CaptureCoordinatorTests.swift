import XCTest
@testable import ZoneCaptureCore

final class CaptureCoordinatorTests: XCTestCase {

    private func makeTempStore() -> (Store, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-coordinator-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: tmpDir.path, withIntermediateDirectories: true)
        let store = Store(rootDirectory: tmpDir.path)
        return (store, tmpDir)
    }

    func testCapturePageInsertsCaptureRow() throws {
        let (store, _) = makeTempStore()
        let result = ExtractionResult(
            capturePath: store.pathForCapture(filename: "page.md"),
            jsonPath: store.pathForCapture(filename: "page.json"),
            title: "Extracted Page",
            wordCount: 123)
        let runner = FakeExtractionRunner(stub: result)
        let extractor = PageExtractor(runner: runner)
        let coordinator = CaptureCoordinator(extractor: extractor, store: store)

        let id = try coordinator.capturePage(
            url: "https://example.com/article",
            sourceApp: "Safari",
            comment: "read later")

        XCTAssertGreaterThan(id, 0)

        let rows = store.recentAll()
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.url, "https://example.com/article")
        XCTAssertEqual(row.title, "Extracted Page")
        XCTAssertEqual(row.comment, "read later")
        XCTAssertEqual(row.sourceApp, "Safari")
        XCTAssertEqual(row.kind, "capture")
        XCTAssertEqual(row.capturePath, result.capturePath)
    }

    func testCapturePageUsesEmptyCommentWhenNil() throws {
        let (store, _) = makeTempStore()
        let result = ExtractionResult(
            capturePath: store.pathForCapture(filename: "page.md"),
            jsonPath: store.pathForCapture(filename: "page.json"),
            title: "T",
            wordCount: 1)
        let runner = FakeExtractionRunner(stub: result)
        let coordinator = CaptureCoordinator(
            extractor: PageExtractor(runner: runner), store: store)

        _ = try coordinator.capturePage(
            url: "https://example.com", sourceApp: nil, comment: nil)

        let row = store.recentAll()[0]
        XCTAssertNil(row.comment)
        XCTAssertNil(row.sourceApp)
    }

    func testCapturePagePropagatesExtractionError() {
        let (store, _) = makeTempStore()
        let runner = FakeExtractionRunner(error: ExtractionError.executionFailed("network down"))
        let coordinator = CaptureCoordinator(
            extractor: PageExtractor(runner: runner), store: store)

        XCTAssertThrowsError(
            try coordinator.capturePage(
                url: "https://example.com", sourceApp: "Safari", comment: nil)
        ) { error in
            guard case ExtractionError.executionFailed(let msg) = error else {
                XCTFail("Expected executionFailed, got \(error)")
                return
            }
            XCTAssertEqual(msg, "network down")
        }
        XCTAssertEqual(store.recentAll().count, 0)
    }

    /// Regression: insertLink signals failure by returning -1 instead of
    /// throwing. The coordinator must turn that into an error, otherwise the
    /// caller shows "✓ Page captured" while the row was never written.
    func testCapturePageThrowsWhenStoreInsertFails() throws {
        // A directory where the database file should be makes sqlite3_open
        // fail, so every insert reports failure and returns -1.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-broken-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: tmpDir.appendingPathComponent("zonecapture.db").path,
            withIntermediateDirectories: true)
        let store = Store(rootDirectory: tmpDir.path)

        let result = ExtractionResult(
            capturePath: "/tmp/page.md",
            jsonPath: "/tmp/page.json",
            title: "T",
            wordCount: 1)
        let coordinator = CaptureCoordinator(
            extractor: PageExtractor(runner: FakeExtractionRunner(stub: result)),
            store: store)

        XCTAssertThrowsError(
            try coordinator.capturePage(
                url: "https://example.com", sourceApp: "Safari", comment: nil)
        ) { error in
            guard case CaptureError.storeInsertFailed = error else {
                XCTFail("Expected storeInsertFailed, got \(error)")
                return
            }
        }
    }
}
