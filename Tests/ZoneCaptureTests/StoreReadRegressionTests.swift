import Foundation
import SQLite3
import XCTest
@testable import ZoneCaptureCore

final class StoreReadRegressionTests: XCTestCase {
    func testCurrentReadThrowsStepErrorAndRecoversWithoutStaleError() throws {
        let root = temporaryRoot()
        let store = Store(rootDirectory: root.path)
        let id = store.insertLink(url: "https://example.com", title: nil, comment: nil, sourceApp: nil)
        try execute(store.databasePath, """
            ALTER TABLE links RENAME TO saved_links;
            CREATE VIEW links AS SELECT 1 AS id, 'https://example.com' AS url,
                NULL AS title, NULL AS comment, NULL AS source_app,
                'url' AS kind, NULL AS capture_path, NULL AS topic,
                abs(-9223372036854775808) AS created_at;
            """)

        XCTAssertThrowsError(try store.readRecent()) { error in
            guard case StoreError.queryFailed(let message) = error else {
                return XCTFail("Expected queryFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("integer overflow"))
        }

        try execute(store.databasePath, "DROP VIEW links; ALTER TABLE saved_links RENAME TO links;")
        XCTAssertEqual(try store.readRecent().map(\.id), [id])
    }

    func testCurrentReadThrowsPrepareErrorImmediately() throws {
        let store = Store(rootDirectory: temporaryRoot().path)
        try execute(store.databasePath, "DROP TABLE links;")
        XCTAssertThrowsError(try store.readRecent()) { error in
            guard case StoreError.queryFailed(let message) = error else {
                return XCTFail("Expected queryFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("no such table"))
        }
    }

    func testLegacySchemaGainsCapturePathWithoutLosingRows() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("zonecapture.db").path
        try execute(database, """
            CREATE TABLE links (
                id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL,
                title TEXT, comment TEXT, source_app TEXT,
                kind TEXT NOT NULL DEFAULT 'url', created_at REAL NOT NULL);
            INSERT INTO links(url, created_at) VALUES ('https://legacy.example', 1);
            """)

        for _ in 0..<2 {
            let store = Store(rootDirectory: root.path)
            XCTAssertEqual(try store.readRecent().last?.url, "https://legacy.example")
            let id = store.insertLink(
                url: "https://new.example", title: nil, comment: nil, sourceApp: nil,
                kind: "capture", capturePath: store.pathForCapture(filename: "new.md"))
            XCTAssertGreaterThan(id, 0)
            XCTAssertEqual(try store.readRecent().first?.capturePath, store.pathForCapture(filename: "new.md"))
        }
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-read-regression-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func execute(_ path: String, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}
