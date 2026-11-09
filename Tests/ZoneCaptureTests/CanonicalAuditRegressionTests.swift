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
    func run(url: String, outDir: String, timeout: TimeInterval) throws -> ExtractionResult {
        let root = URL(fileURLWithPath: outDir)
        let markdown = root.appendingPathComponent("new.md")
        let json = root.appendingPathComponent("new.json")
        try "new capture".write(to: markdown, atomically: true, encoding: .utf8)
        try "{}".write(to: json, atomically: true, encoding: .utf8)
        return ExtractionResult(capturePath: markdown.path, jsonPath: json.path, title: "New", wordCount: 2)
    }
}
