import Foundation

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
    /// Returns the new row id, or -1 if the store insert fails.
    @discardableResult
    public func capturePage(url: String, sourceApp: String?, comment: String?) throws -> Int64 {
        let result = try extractor.extract(
            url: url,
            outDir: store.capturesDirectory)
        return store.insertLink(
            url: url,
            title: result.title,
            comment: comment,
            sourceApp: sourceApp,
            kind: "capture",
            capturePath: result.capturePath)
    }
}
