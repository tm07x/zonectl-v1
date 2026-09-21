import Foundation
import SQLite3

/// A thin wrapper around the C SQLite API. Intentionally dependency-free.
///
/// The database lives in a fixed, stable location so captures survive app
/// rebuilds/reinstalls: `~/Library/Application Support/ZoneCapture/zonecapture.db`.
/// Parsed-page markdown (feature 2) lands in a sibling `captures/` directory and
/// the DB row points to the file path.
/// Errors surfaced via `Store.onError` so the app layer can show user-facing
/// feedback instead of failing silently. Every error is also NSLog'd.
public enum StoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case schemaFailed(String)
    case insertFailed(String)
    case queryFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let msg): return "database open failed: \(msg)"
        case .schemaFailed(let msg): return "schema creation failed: \(msg)"
        case .insertFailed(let msg): return "write failed: \(msg)"
        case .queryFailed(let msg): return "read failed: \(msg)"
        }
    }
}

public final class Store {
    public static let shared = Store()

    /// App-layer hook for surfacing database errors in the UI. Insert
    /// failures are additionally visible via `insertLink`'s -1 return.
    public var onError: ((StoreError) -> Void)?

    /// Serializes all database access. The panel saves on the main thread
    /// while page capture inserts on a background queue, and SQLite's C API
    /// is not safe to drive concurrently on one connection even in
    /// serialized mode (the step → last_insert_rowid sequence is not atomic).
    private let lock = NSLock()

    private func report(_ error: StoreError) {
        NSLog("[ZoneCapture] store error: \(error)")
        // Never invoke app code on the caller's thread — it may hold the
        // lock and may be a background queue. Hop to main so UI state stays
        // main-confined and a callback can't deadlock by re-entering Store.
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    /// SQLite destructor flag: copy bound strings immediately.
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let dbPath: String
    private let capturesDir: String
    private var db: OpaquePointer?

    /// Production initializer — uses the standard Application Support directory.
    private convenience init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.path ?? NSTemporaryDirectory()
        let root = (appSupport as NSString).appendingPathComponent("ZoneCapture")
        self.init(rootDirectory: root)
    }

    /// Testable initializer — lets tests point the Store at a temp directory
    /// so each test gets an isolated, throwaway database.
    internal init(rootDirectory: String) {
        let root = rootDirectory
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        dbPath = (root as NSString).appendingPathComponent("zonecapture.db")
        capturesDir = (root as NSString).appendingPathComponent("captures")
        try? FileManager.default.createDirectory(
            atPath: capturesDir, withIntermediateDirectories: true)
        open()
        createSchema()
    }

    private func open() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            report(.openFailed("\(dbPath): \(msg)"))
        }
        // WAL for durability + concurrent reads.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    }

    private func createSchema() {
        let ddl = """
        CREATE TABLE IF NOT EXISTS links (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            url         TEXT NOT NULL,
            title       TEXT,
            comment     TEXT,
            source_app  TEXT,
            kind        TEXT NOT NULL DEFAULT 'url',
            capture_path TEXT,
            created_at  REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_links_created ON links(created_at DESC);
        """
        if sqlite3_exec(db, ddl, nil, nil, nil) != SQLITE_OK {
            report(.schemaFailed(String(cString: sqlite3_errmsg(db))))
        }
        // Forward-compatible column for the inference stage (see VISION.md):
        // the topic a capture belongs to. Discovered later, never lost.
        // Migrated onto existing databases as well.
        addColumnIfMissing("topic", type: "TEXT")
    }

    private func addColumnIfMissing(_ column: String, type: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(links);", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1),
               String(cString: namePtr) == column {
                exists = true
                break
            }
        }
        if !exists {
            let sql = "ALTER TABLE links ADD COLUMN \(column) \(type);"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                report(.schemaFailed("add column \(column): \(String(cString: sqlite3_errmsg(db)))"))
            }
        }
    }

    @discardableResult
    public func insertLink(
        url: String,
        title: String?,
        comment: String?,
        sourceApp: String?,
        kind: String = "url",
        capturePath: String? = nil
    ) -> Int64 {
        let sql = """
        INSERT INTO links (url, title, comment, source_app, kind, capture_path, created_at)
        VALUES (?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            report(.insertFailed("prepare: \(String(cString: sqlite3_errmsg(db)))"))
            return -1
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, comment, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, sourceApp, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, kind, -1, SQLITE_TRANSIENT)
        if let cp = capturePath {
            sqlite3_bind_text(stmt, 6, cp, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            report(.insertFailed("step: \(String(cString: sqlite3_errmsg(db)))"))
            return -1
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// A fully populated capture row, including kind and capture_path.
    public struct CaptureRow: Equatable {
        public let id: Int64
        public let url: String
        public let title: String?
        public let comment: String?
        public let sourceApp: String?
        public let kind: String
        public let capturePath: String?
        public let topic: String?
        public let created: Date
    }

    /// Returns the most recent N captures, newest first.
    public func recent(limit: Int = 25) -> [(id: Int64, url: String, title: String?, comment: String?, created: Date)] {
        let sql = "SELECT id, url, title, comment, created_at FROM links ORDER BY created_at DESC, id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        var rows: [(Int64, String, String?, String?, Date)] = []
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            report(.queryFailed(String(cString: sqlite3_errmsg(db))))
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let url = String(cString: sqlite3_column_text(stmt, 1))
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let comment = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let ts = sqlite3_column_double(stmt, 4)
            rows.append((id, url, title, comment, Date(timeIntervalSince1970: ts)))
        }
        return rows
    }

    /// Returns the most recent N captures with all columns, newest first.
    public func recentAll(limit: Int = 25) -> [CaptureRow] {
        let sql = """
        SELECT id, url, title, comment, source_app, kind, capture_path, topic, created_at
        FROM links ORDER BY created_at DESC, id DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        var rows: [CaptureRow] = []
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            report(.queryFailed(String(cString: sqlite3_errmsg(db))))
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let url = String(cString: sqlite3_column_text(stmt, 1))
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let comment = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let sourceApp = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let kind = String(cString: sqlite3_column_text(stmt, 5))
            let capturePath = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let topic = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let ts = sqlite3_column_double(stmt, 8)
            rows.append(CaptureRow(
                id: id,
                url: url,
                title: title,
                comment: comment,
                sourceApp: sourceApp,
                kind: kind,
                capturePath: capturePath,
                topic: topic,
                created: Date(timeIntervalSince1970: ts)))
        }
        return rows
    }

    public func pathForCapture(filename: String) -> String {
        (capturesDir as NSString).appendingPathComponent(filename)
    }

    public var databasePath: String { dbPath }
    public var capturesDirectory: String { capturesDir }
}
