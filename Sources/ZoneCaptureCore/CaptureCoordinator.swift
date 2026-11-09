import Foundation

/// Errors specific to the capture orchestration step.
public enum CaptureError: Error, Equatable, CustomStringConvertible {
    /// Extraction succeeded but the database row could not be written.
    /// Without this, the caller would show a success banner while the
    /// capture silently never appeared in `zonectl list`.
    case storeInsertFailed

    public var description: String {
        switch self {
        case .storeInsertFailed: return "captured, but the database write failed"
        }
    }
}

/// Orchestrates page-content extraction and persistence.
///
/// Uses a `PageExtractor` to fetch and convert a page to Markdown + JSON,
/// then records the capture in the `Store` with `kind = "capture"` and a
/// pointer to the Markdown file.
public final class CaptureCoordinator {
    private let extractor: PageExtractor
    private let store: Store

    public init(extractor: PageExtractor, store: Store) {
        self.extractor = extractor
        self.store = store
    }

    /// Downloads `url`, writes a Markdown + JSON capture, and inserts a row.
    /// Returns the new row id. Throws `CaptureError.storeInsertFailed` when
    /// the store reports failure (`insertLink` signals it with -1).
    @discardableResult
    public func capturePage(url: String, sourceApp: String?, comment: String?) throws -> Int64 {
        let directory = URL(fileURLWithPath: store.capturesDirectory)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var persisted = false
        defer {
            if !persisted {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let result = try extractor.extract(
            url: url,
            outDir: directory.path)
        let id = store.insertLink(
            url: url,
            title: result.title,
            comment: comment,
            sourceApp: sourceApp,
            kind: "capture",
            capturePath: result.capturePath)
        guard id >= 0 else { throw CaptureError.storeInsertFailed }
        persisted = true
        return id
    }
}
