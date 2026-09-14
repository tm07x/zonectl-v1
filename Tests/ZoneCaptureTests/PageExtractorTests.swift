import XCTest
@testable import ZoneCaptureCore

/// Tests for the page-extraction seam.
///
/// The actual Python readability/markdownify script is an external process;
/// these tests exercise the Swift wrapper and JSON parser through a fake
/// runner so they run offline and fast.
final class PageExtractorTests: XCTestCase {

    // MARK: - parseOutput

    func testParseOutputReturnsExtractionResult() throws {
        let json = """
        {
          "capture_path": "/tmp/captures/2026-09-14-example-abc123.md",
          "json_path": "/tmp/captures/2026-09-14-example-abc123.json",
          "title": "Example Domain",
          "word_count": 42
        }
        """.data(using: .utf8)!

        let result = try PageExtractor.parseOutput(json)
        XCTAssertEqual(result.capturePath, "/tmp/captures/2026-09-14-example-abc123.md")
        XCTAssertEqual(result.jsonPath, "/tmp/captures/2026-09-14-example-abc123.json")
        XCTAssertEqual(result.title, "Example Domain")
        XCTAssertEqual(result.wordCount, 42)
    }

    func testParseOutputThrowsOnInvalidJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try PageExtractor.parseOutput(data)) { error in
            guard case ExtractionError.invalidOutput = error else {
                XCTFail("Expected invalidOutput, got \(error)")
                return
            }
        }
    }

    func testParseOutputThrowsWhenFieldsMissing() {
        let data = """
        {"title": "Only title"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try PageExtractor.parseOutput(data)) { error in
            guard case ExtractionError.invalidOutput = error else {
                XCTFail("Expected invalidOutput, got \(error)")
                return
            }
        }
    }

    // MARK: - PageExtractor with fake runner

    func testExtractCallsRunnerAndReturnsResult() throws {
        let expected = ExtractionResult(
            capturePath: "/out/page.md",
            jsonPath: "/out/page.json",
            title: "Page",
            wordCount: 7)
        let runner = FakeExtractionRunner(stub: expected)
        let extractor = PageExtractor(runner: runner)

        let result = try extractor.extract(url: "https://example.com", outDir: "/out")

        XCTAssertEqual(result, expected)
        XCTAssertEqual(runner.lastURL, "https://example.com")
        XCTAssertEqual(runner.lastOutDir, "/out")
    }

    func testExtractPropagatesRunnerError() {
        let runner = FakeExtractionRunner(error: ExtractionError.executionFailed("boom"))
        let extractor = PageExtractor(runner: runner)

        XCTAssertThrowsError(try extractor.extract(url: "https://example.com", outDir: "/out")) { error in
            guard case ExtractionError.executionFailed(let msg) = error else {
                XCTFail("Expected executionFailed, got \(error)")
                return
            }
            XCTAssertEqual(msg, "boom")
        }
    }

    func testExtractPassesCustomTimeout() throws {
        let expected = ExtractionResult(
            capturePath: "/out/page.md",
            jsonPath: "/out/page.json",
            title: "Page",
            wordCount: 1)
        let runner = FakeExtractionRunner(stub: expected)
        let extractor = PageExtractor(runner: runner)

        _ = try extractor.extract(url: "https://example.com", outDir: "/out", timeout: 120)
        XCTAssertEqual(runner.lastTimeout, 120)
    }

    // MARK: - PythonExtractionRunner

    func testPythonRunnerThrowsWhenScriptMissing() {
        let runner = PythonExtractionRunner(scriptPath: "/nonexistent/zone_extract.py")
        XCTAssertThrowsError(try runner.run(url: "https://example.com", outDir: "/out", timeout: 10)) { error in
            guard case ExtractionError.scriptNotFound = error else {
                XCTFail("Expected scriptNotFound, got \(error)")
                return
            }
        }
    }
}

// MARK: - Test doubles

final class FakeExtractionRunner: ExtractionRunner, @unchecked Sendable {
    var stub: ExtractionResult?
    var error: Error?
    var lastURL: String?
    var lastOutDir: String?
    var lastTimeout: TimeInterval?

    init(stub: ExtractionResult? = nil, error: Error? = nil) {
        self.stub = stub
        self.error = error
    }

    func run(url: String, outDir: String, timeout: TimeInterval) throws -> ExtractionResult {
        lastURL = url
        lastOutDir = outDir
        lastTimeout = timeout
        if let error = error { throw error }
        return stub ?? ExtractionResult(
            capturePath: "/out/default.md",
            jsonPath: "/out/default.json",
            title: "Default",
            wordCount: 0)
    }
}
