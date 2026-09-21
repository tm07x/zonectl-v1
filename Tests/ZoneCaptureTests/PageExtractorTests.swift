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

    func testPythonRunnerParsesSuccessOutput() throws {
        let script = try makeStubScript("""
        import json
        print(json.dumps({"capture_path": "/out/a.md", "json_path": "/out/a.json", "title": "T", "word_count": 3}))
        """)
        let runner = PythonExtractionRunner(scriptPath: script)

        let result = try runner.run(url: "https://example.com", outDir: "/out", timeout: 10)

        XCTAssertEqual(result.capturePath, "/out/a.md")
        XCTAssertEqual(result.title, "T")
        XCTAssertEqual(result.wordCount, 3)
    }

    /// The script reports failures as {"error": "..."} on STDOUT with exit
    /// code 1 — stderr stays empty. The runner must surface that message.
    func testPythonRunnerSurfacesErrorPayloadFromStdout() throws {
        let script = try makeStubScript("""
        import json, sys
        print(json.dumps({"error": "HTTP Error 404: Not Found"}))
        sys.exit(1)
        """)
        let runner = PythonExtractionRunner(scriptPath: script)

        XCTAssertThrowsError(try runner.run(url: "https://example.com", outDir: "/out", timeout: 10)) { error in
            guard case ExtractionError.executionFailed(let msg) = error else {
                XCTFail("Expected executionFailed, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("404"), "payload message should reach the caller, got: \(msg)")
        }
    }

    func testPythonRunnerFallsBackToStderrMessage() throws {
        let script = try makeStubScript("""
        import sys
        sys.stderr.write("boom on stderr\\n")
        sys.exit(1)
        """)
        let runner = PythonExtractionRunner(scriptPath: script)

        XCTAssertThrowsError(try runner.run(url: "https://example.com", outDir: "/out", timeout: 10)) { error in
            guard case ExtractionError.executionFailed(let msg) = error else {
                XCTFail("Expected executionFailed, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("boom on stderr"), "stderr should reach the caller, got: \(msg)")
        }
    }

    /// Regression: reading pipes only after waitUntilExit() deadlocks as soon
    /// as the child fills a pipe buffer (~64 KB). This stub floods stderr far
    /// past that and then succeeds — the run must complete.
    func testPythonRunnerDoesNotDeadlockOnLargeStderr() throws {
        let script = try makeStubScript("""
        import json, sys
        sys.stderr.write("x" * (1024 * 1024))
        sys.stderr.flush()
        print(json.dumps({"capture_path": "/out/a.md", "json_path": "/out/a.json", "title": "Big", "word_count": 1}))
        """)
        let runner = PythonExtractionRunner(scriptPath: script)

        let result = try runner.run(url: "https://example.com", outDir: "/out", timeout: 20)
        XCTAssertEqual(result.title, "Big")
    }

    /// The script's own --timeout only bounds socket operations. A runaway
    /// child (DNS hang, pathological parse) must be killed by the runner.
    func testPythonRunnerKillsRunawayScript() throws {
        let script = try makeStubScript("""
        import time
        time.sleep(120)
        """)
        let runner = PythonExtractionRunner(scriptPath: script, watchdogGrace: 0.5)

        let start = Date()
        XCTAssertThrowsError(try runner.run(url: "https://example.com", outDir: "/out", timeout: 1)) { error in
            guard case ExtractionError.executionFailed(let msg) = error else {
                XCTFail("Expected executionFailed, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("timed out"), "expected a timeout message, got: \(msg)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 15,
                          "runaway child must be killed, not awaited")
    }

    /// The installed .app must use its bundled interpreter (the Command Line
    /// Tools python3 has no readability/markdownify). Verify the override is
    /// actually used to launch the script.
    func testPythonRunnerUsesCustomInterpreter() throws {
        let recordFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("python-args-\(UUID().uuidString)").path
        let fakePython = try makeStubScript("""
        #!/bin/sh
        printf '%s\\n' "$@" > "\(recordFile)"
        exec /usr/bin/env python3 "$@"
        """, posixPermissions: 0o755)
        let script = try makeStubScript("""
        import json
        print(json.dumps({"capture_path": "/out/a.md", "json_path": "/out/a.json", "title": "Custom", "word_count": 1}))
        """)
        let runner = PythonExtractionRunner(scriptPath: script, pythonPath: fakePython)

        let result = try runner.run(url: "https://example.com", outDir: "/out", timeout: 10)

        XCTAssertEqual(result.title, "Custom")
        let recorded = try String(contentsOfFile: recordFile, encoding: .utf8)
        XCTAssertTrue(recorded.contains(script),
                      "custom interpreter must be invoked with the script path, got: \(recorded)")
    }

    // MARK: - Stub helpers

    private func makeStubScript(
        _ contents: String,
        posixPermissions: Int? = nil
    ) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-\(UUID().uuidString)").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        if let posixPermissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: posixPermissions], ofItemAtPath: path)
        }
        return path
    }
}

// MARK: - Test doubles

/// Test double. @unchecked Sendable with plain mutable recording state:
/// safe only because the tests call it single-threaded. If a future test
/// drives concurrent captures, make this an actor first.
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
