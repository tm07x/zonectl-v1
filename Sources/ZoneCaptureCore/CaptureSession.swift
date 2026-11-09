import Foundation

public struct CaptureSession {
    public private(set) var sourceApp = ""
    private var request: UUID?
    private var captured: URLFetcher.Result?

    public init() {}

    @discardableResult
    public mutating func begin(sourceApp: String) -> UUID {
        let request = UUID()
        self.request = request
        self.sourceApp = sourceApp
        captured = nil
        return request
    }

    public mutating func end() {
        request = nil
        captured = nil
    }

    @discardableResult
    public mutating func apply(_ result: URLFetcher.Result, request: UUID) -> Bool {
        guard self.request == request else { return false }
        captured = result
        return true
    }

    public func title(for url: String) -> String? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captured, !url.isEmpty, captured.error == nil,
              url == captured.url.trimmingCharacters(in: .whitespacesAndNewlines),
              captured.title?.isEmpty == false else { return nil }
        return captured.title
    }
}
