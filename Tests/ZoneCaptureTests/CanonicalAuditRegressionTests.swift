import Foundation
import SQLite3
import XCTest
@testable import ZoneCaptureCore

final class CanonicalAuditRegressionTests: XCTestCase {
    func testBraveBetaTargetsDetectedVariant() throws {
        let script = try XCTUnwrap(URLFetcher.scriptForApp(
            name: "Brave Browser", bundleId: "com.brave.Browser.beta"))
        XCTAssertTrue(script.contains("tell application \"Brave Browser Beta\""))
    }

    func testBraveNightlyTargetsDetectedVariant() throws {
        let script = try XCTUnwrap(URLFetcher.scriptForApp(
            name: "Brave Browser", bundleId: "com.brave.Browser.nightly"))
        XCTAssertTrue(script.contains("tell application \"Brave Browser Nightly\""))
    }

    func testRecentReportsSQLiteStepFailure() throws {
        let store = try makeFailingReadStore()
        let reported = expectation(description: "current SQLite step error")
        store.onError = { error in
            guard case .queryFailed = error else { return }
            reported.fulfill()
        }
        XCTAssertTrue(store.recent().isEmpty)
        wait(for: [reported], timeout: 1)
    }

    func testRecentAllReportsSQLiteStepFailure() throws {
        let store = try makeFailingReadStore()
        let reported = expectation(description: "current SQLite step error")
        store.onError = { error in
            guard case .queryFailed = error else { return }
            reported.fulfill()
        }
        XCTAssertTrue(store.recentAll().isEmpty)
        wait(for: [reported], timeout: 1)
    }

    func testFailedInsertRemovesOnlyOwnedArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("zonecapture.db"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(rootDirectory: root.path)
        let sentinel = URL(fileURLWithPath: store.capturesDirectory).appendingPathComponent("keep.md")
        try "existing capture".write(to: sentinel, atomically: true, encoding: .utf8)
        let coordinator = CaptureCoordinator(
            extractor: PageExtractor(runner: WritingAuditRunner()), store: store)

        XCTAssertThrowsError(try coordinator.capturePage(
            url: "https://example.com", sourceApp: nil, comment: nil))

        XCTAssertEqual(try String(contentsOf: sentinel), "existing capture")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.capturesDirectory), ["keep.md"])
    }

    func testExtractionFailureRemovesPartialOwnedArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-partial-\(UUID().uuidString)")
        let store = Store(rootDirectory: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = CaptureCoordinator(
            extractor: PageExtractor(runner: WritingAuditRunner(fail: true)), store: store)

        XCTAssertThrowsError(try coordinator.capturePage(url: "https://example.com", sourceApp: nil, comment: nil))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.capturesDirectory), [])
        XCTAssertTrue(store.recentAll().isEmpty)
    }

    func testSuccessfulCaptureKeepsOwnedArtifactsAndIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-owned-success-\(UUID().uuidString)")
        let store = Store(rootDirectory: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = CaptureCoordinator(extractor: PageExtractor(runner: WritingAuditRunner()), store: store)

        let id = try coordinator.capturePage(url: "https://example.com", sourceApp: nil, comment: nil)

        let row = try XCTUnwrap(store.recentAll().first)
        XCTAssertEqual(row.id, id)
        let markdown = URL(fileURLWithPath: try XCTUnwrap(row.capturePath))
        XCTAssertNotEqual(markdown.deletingLastPathComponent().path, store.capturesDirectory)
        XCTAssertEqual(try String(contentsOf: markdown), "new capture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdown.deletingPathExtension().appendingPathExtension("json").path))
    }

    func testFailedInsertNeverDeletesRunnerReportedUnownedPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-unowned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("zonecapture.db"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(rootDirectory: root.path)
        let markdown = root.appendingPathComponent("existing.md")
        let json = root.appendingPathComponent("existing.json")
        try "keep markdown".write(to: markdown, atomically: true, encoding: .utf8)
        try "keep json".write(to: json, atomically: true, encoding: .utf8)
        let result = ExtractionResult(capturePath: markdown.path, jsonPath: json.path, title: "Existing", wordCount: 2)
        let coordinator = CaptureCoordinator(extractor: PageExtractor(runner: FakeExtractionRunner(stub: result)), store: store)

        XCTAssertThrowsError(try coordinator.capturePage(url: "https://example.com", sourceApp: nil, comment: nil))

        XCTAssertEqual(try String(contentsOf: markdown), "keep markdown")
        XCTAssertEqual(try String(contentsOf: json), "keep json")
    }

    private func makeFailingReadStore() throws -> Store {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-read-error-\(UUID().uuidString)")
        let store = Store(rootDirectory: root.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.databasePath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        DROP TABLE links;
        CREATE VIEW links AS SELECT 1 AS id, 'https://example.com' AS url,
            NULL AS title, NULL AS comment, NULL AS source_app,
            'url' AS kind, NULL AS capture_path, NULL AS topic,
            abs(-9223372036854775808) AS created_at;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return store
    }
}

private final class WritingAuditRunner: ExtractionRunner, @unchecked Sendable {
    private let fail: Bool

    init(fail: Bool = false) {
        self.fail = fail
    }

    func run(url: String, outDir: String, timeout: TimeInterval) throws -> ExtractionResult {
        let root = URL(fileURLWithPath: outDir)
        let markdown = root.appendingPathComponent("new.md")
        let json = root.appendingPathComponent("new.json")
        try "new capture".write(to: markdown, atomically: true, encoding: .utf8)
        try "{}".write(to: json, atomically: true, encoding: .utf8)
        if fail { throw ExtractionError.executionFailed("partial extraction") }
        return ExtractionResult(capturePath: markdown.path, jsonPath: json.path, title: "New", wordCount: 2)
    }
}
