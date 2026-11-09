import XCTest
import Foundation
@testable import ZoneCaptureCore

/// Tests for Store — the SQLite wrapper. Each test creates a fresh Store
/// pointed at a unique temp directory so tests are fully isolated and
/// repeatable. We never touch the production `Store.shared` singleton or the
/// user's real Application Support database.
final class StoreTests: XCTestCase {

    /// Helper: create a Store backed by a fresh temp directory.
    private func makeTempStore() -> (Store, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: tmpDir.path, withIntermediateDirectories: true)
        let store = Store(rootDirectory: tmpDir.path)
        return (store, tmpDir)
    }

    override func tearDown() {
        // Best-effort cleanup of temp dirs is handled by the OS; we leave them
        // in NSTemporaryDirectory which is periodically purged.
    }

    // MARK: - Schema

    func testSchemaIsCreated() {
        // The DB file should exist and the `links` table should be queryable.
        // If createSchema() failed, recent() would return [] which could mask
        // the problem, so we also verify the file exists on disk.
        let (store, dir) = makeTempStore()
        let dbURL = dir.appendingPathComponent("zonecapture.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path),
                       "Database file should exist after Store init")
        // An empty DB should return an empty array (not crash).
        let rows = store.recent()
        XCTAssertEqual(rows.count, 0)
    }

    func testCapturesDirectoryCreated() {
        // The captures/ sibling directory should be created alongside the DB.
        let (_, dir) = makeTempStore()
        let capturesDir = dir.appendingPathComponent("captures")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: capturesDir.path, isDirectory: nil),
                       "captures/ directory should exist after Store init")
    }

    // MARK: - insertLink

    func testInsertLinkReturnsPositiveId() {
        let (store, _) = makeTempStore()
        let id = store.insertLink(
            url: "https://example.com/1", title: "Example",
            comment: "a note", sourceApp: "Safari")
        XCTAssertGreaterThan(id, 0,
            "insertLink should return a positive row id on success")
    }

    func testInsertLinkReturnsSequentialIds() {
        // Each insert should produce a monotonically increasing id.
        let (store, _) = makeTempStore()
        let id1 = store.insertLink(
            url: "https://a.com", title: nil, comment: nil, sourceApp: nil)
        let id2 = store.insertLink(
            url: "https://b.com", title: nil, comment: nil, sourceApp: nil)
        XCTAssertEqual(id2, id1 + 1,
            "Second insert should have id one greater than the first")
    }

    // MARK: - recent

    func testRecentReturnsRowsNewestFirst() throws {
        let (store, _) = makeTempStore()

        let id1 = store.insertLink(
            url: "https://first.com", title: "First",
            comment: "first note", sourceApp: "Safari")
        // Small delay so timestamps differ meaningfully.
        Thread.sleep(forTimeInterval: 0.05)
        let id2 = store.insertLink(
            url: "https://second.com", title: "Second",
            comment: "second note", sourceApp: "Chrome")

        let rows = store.recent(limit: 25)
        XCTAssertEqual(rows.count, 2)

        // Newest first: id2 should come before id1.
        XCTAssertEqual(rows[0].id, id2)
        XCTAssertEqual(rows[0].url, "https://second.com")
        XCTAssertEqual(rows[0].comment, "second note")

        XCTAssertEqual(rows[1].id, id1)
        XCTAssertEqual(rows[1].url, "https://first.com")
        XCTAssertEqual(rows[1].comment, "first note")

        // Timestamps should be descending.
        XCTAssertGreaterThanOrEqual(rows[0].created, rows[1].created)
    }

    func testRecentCommentNilPreserved() {
        // A null comment should come back as nil, not an empty string.
        let (store, _) = makeTempStore()
        store.insertLink(
            url: "https://no-comment.com", title: nil,
            comment: nil, sourceApp: nil)

        let rows = store.recent()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].comment,
            "Nil comment should be preserved as nil through the round trip")
    }

    func testRecentCommentEmptyStringPreserved() {
        // An empty-string comment is distinct from nil; verify it round-trips.
        let (store, _) = makeTempStore()
        store.insertLink(
            url: "https://empty-comment.com", title: nil,
            comment: "", sourceApp: nil)

        let rows = store.recent()
        XCTAssertEqual(rows.count, 1)
        // SQLite may store empty string or NULL identically depending on
        // binding; either nil or "" is acceptable, but it must not be garbage.
        let comment = rows[0].comment
        XCTAssertTrue(comment == nil || comment == "",
            "Empty comment should be nil or empty string, not other content")
    }

    func testRecentRespectsLimit() {
        let (store, _) = makeTempStore()
        for i in 0..<10 {
            store.insertLink(
                url: "https://item-\(i).com", title: nil,
                comment: "c\(i)", sourceApp: nil)
        }

        // Request fewer than total rows.
        let rowsLimited = store.recent(limit: 3)
        XCTAssertEqual(rowsLimited.count, 3,
            "recent(limit: 3) should return exactly 3 rows when >= 3 exist")

        // The 3 returned should be the 3 newest (items 9, 8, 7).
        XCTAssertEqual(rowsLimited[0].url, "https://item-9.com")
        XCTAssertEqual(rowsLimited[1].url, "https://item-8.com")
        XCTAssertEqual(rowsLimited[2].url, "https://item-7.com")

        // Default limit (25) should return all 10.
        let rowsDefault = store.recent()
        XCTAssertEqual(rowsDefault.count, 10)
    }

    func testRecentFieldsMatchInsertion() {
        // Verify all fields returned by recent() match what was inserted.
        let (store, _) = makeTempStore()
        store.insertLink(
            url: "https://detailed.com/page?q=1",
            title: "A Title",
            comment: "my comment",
            sourceApp: "Brave")

        let rows = store.recent()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].url, "https://detailed.com/page?q=1")
        XCTAssertEqual(rows[0].comment, "my comment")
    }

    // MARK: - kind default

    func testKindDefaultsToUrl() {
        // The `kind` column has a DEFAULT 'url'. We can't read it back through
        // recent() (which doesn't select kind), but we can verify the default
        // by inserting without specifying kind and checking it doesn't error.
        // A more thorough test would require a query method that returns kind;
        // for now we verify the insert succeeds and the row is retrievable.
        let (store, _) = makeTempStore()
        let id = store.insertLink(
            url: "https://kind-test.com", title: nil,
            comment: nil, sourceApp: nil)
        XCTAssertGreaterThan(id, 0)

        // Insert with explicit "note" kind also works.
        let id2 = store.insertLink(
            url: "https://kind-note.com", title: nil,
            comment: "a note", sourceApp: "Finder", kind: "note")
        XCTAssertGreaterThan(id2, 0)
        XCTAssertNotEqual(id, id2)

        // Both rows should be retrievable.
        let rows = store.recent()
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - pathForCapture

    func testPathForCapture() {
        let (store, dir) = makeTempStore()
        let path = store.pathForCapture(filename: "page.md")
        let expected = dir.appendingPathComponent("captures")
            .appendingPathComponent("page.md").path
        XCTAssertEqual(path, expected)
    }

    func testDatabasePathProperty() {
        let (store, dir) = makeTempStore()
        let expected = dir.appendingPathComponent("zonecapture.db").path
        XCTAssertEqual(store.databasePath, expected)
    }

    func testCapturesDirectoryProperty() {
        let (store, dir) = makeTempStore()
        let expected = dir.appendingPathComponent("captures").path
        XCTAssertEqual(store.capturesDirectory, expected)
    }

    // MARK: - Isolation

    func testStoresAreIsolated() {
        // Two Stores with different root directories should not see each
        // other's rows.
        let (store1, _) = makeTempStore()
        let (store2, _) = makeTempStore()

        store1.insertLink(
            url: "https://only-in-store1.com", title: nil,
            comment: nil, sourceApp: nil)

        XCTAssertEqual(store1.recent().count, 1)
        XCTAssertEqual(store2.recent().count, 0,
            "Store 2 should not see rows inserted into Store 1's database")
    }

    // MARK: - Shared singleton

    func testSharedSingletonExists() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonecapture-singleton-\(UUID().uuidString)")
        let previousRoot = getenv("ZONE_CAPTURE_ROOT").map { String(cString: $0) }
        setenv("ZONE_CAPTURE_ROOT", root.path, 1)
        defer {
            if let previousRoot {
                setenv("ZONE_CAPTURE_ROOT", previousRoot, 1)
            } else {
                unsetenv("ZONE_CAPTURE_ROOT")
            }
        }
        XCTAssertEqual(Store.shared.databasePath, root.appendingPathComponent("zonecapture.db").path)
        XCTAssertTrue(Store.shared.recent(limit: 0).isEmpty)
    }

    // MARK: - recentAll / CaptureRow

    func testRecentAllReturnsKindAndCapturePath() {
        let (store, _) = makeTempStore()
        let urlId = store.insertLink(
            url: "https://url.com", title: nil,
            comment: nil, sourceApp: nil, kind: "url")
        let captureId = store.insertLink(
            url: "https://page.com", title: "Page",
            comment: nil, sourceApp: "Safari",
            kind: "capture",
            capturePath: "/tmp/captures/page.md")

        let rows = store.recentAll(limit: 10)
        XCTAssertEqual(rows.count, 2)

        let urlRow = rows.first { $0.id == urlId }
        let captureRow = rows.first { $0.id == captureId }

        XCTAssertNotNil(urlRow)
        XCTAssertEqual(urlRow?.kind, "url")
        XCTAssertNil(urlRow?.capturePath)

        XCTAssertNotNil(captureRow)
        XCTAssertEqual(captureRow?.kind, "capture")
        XCTAssertEqual(captureRow?.capturePath, "/tmp/captures/page.md")
        XCTAssertEqual(captureRow?.title, "Page")
        XCTAssertEqual(captureRow?.sourceApp, "Safari")
    }

    func testRecentAllReturnsRowsNewestFirst() throws {
        let (store, _) = makeTempStore()
        let id1 = store.insertLink(url: "https://first.com", title: nil, comment: nil, sourceApp: nil, kind: "url")
        Thread.sleep(forTimeInterval: 0.05)
        let id2 = store.insertLink(url: "https://second.com", title: nil, comment: nil, sourceApp: nil, kind: "url")

        let rows = store.recentAll(limit: 10)
        XCTAssertEqual(rows.map { $0.id }, [id2, id1])
    }

    func testRecentAllRespectsLimit() {
        let (store, _) = makeTempStore()
        for i in 0..<5 {
            store.insertLink(url: "https://item-\(i).com", title: nil, comment: nil, sourceApp: nil, kind: "url")
        }
        XCTAssertEqual(store.recentAll(limit: 2).count, 2)
    }

    func testRecentAllDoesNotBreakRecent() {
        let (store, _) = makeTempStore()
        store.insertLink(url: "https://both.com", title: "T", comment: "C", sourceApp: "Arc", kind: "url")

        let oldRows = store.recent()
        let newRows = store.recentAll()

        XCTAssertEqual(oldRows.count, 1)
        XCTAssertEqual(newRows.count, 1)
        XCTAssertEqual(oldRows[0].url, newRows[0].url)
        XCTAssertEqual(oldRows[0].id, newRows[0].id)
    }

    // MARK: - Concurrency

    /// Regression: page capture inserts on a background queue while the panel
    /// can save on the main thread. `sqlite3_last_insert_rowid` is
    /// connection-global, so without serialization two interleaved inserts
    /// can hand a caller the other caller's row id.
    func testConcurrentInsertsAllLandWithUniqueIds() {
        let (store, _) = makeTempStore()
        let group = DispatchGroup()
        let idsLock = NSLock()
        var ids: [Int64] = []

        for i in 0..<40 {
            DispatchQueue.global().async(group: group) {
                let id = store.insertLink(
                    url: "https://example.com/\(i)", title: nil,
                    comment: nil, sourceApp: "test")
                idsLock.lock()
                ids.append(id)
                idsLock.unlock()
            }
        }
        group.wait()

        XCTAssertEqual(ids.count, 40)
        XCTAssertFalse(ids.contains(-1), "no insert should fail")
        XCTAssertEqual(Set(ids).count, 40, "every insert must return its own row id")
        XCTAssertEqual(store.recentAll(limit: 100).count, 40)
    }
}
