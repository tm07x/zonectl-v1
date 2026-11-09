import Foundation
import XCTest
@testable import ZoneCaptureCore

final class PythonDrainRegressionTests: XCTestCase {
    func testRapidExitJoinsBothDrainsBeforeDecodingFinalChunks() throws {
        let script = try stub("""
            import json, os, threading
            def warnings():
                for _ in range(128):
                    os.write(2, b'warning' * 1024)
            worker = threading.Thread(target=warnings)
            worker.start()
            payload = json.dumps({"capture_path": "/out/a.md", "json_path": "/out/a.json",
                                  "title": "Z" * 131072 + "final chunk", "word_count": 42}).encode()
            for start in range(0, len(payload), 997):
                os.write(1, payload[start:start + 997])
            worker.join()
            """)
        let runner = PythonExtractionRunner(scriptPath: script)
        for _ in 0..<20 {
            let result = try runner.run(url: "https://example.com", outDir: "/out", timeout: 10)
            XCTAssertEqual(result.title, String(repeating: "Z", count: 131072) + "final chunk")
            XCTAssertEqual(result.wordCount, 42)
        }
    }

    func testNonzeroExitIncludesFinalStderrChunk() throws {
        let script = try stub("""
            import os
            for _ in range(128):
                os.write(2, b'x' * 8192)
            os.write(2, b'FINAL-DIAGNOSTIC')
            raise SystemExit(1)
            """)
        let runner = PythonExtractionRunner(scriptPath: script)
        XCTAssertThrowsError(try runner.run(url: "https://example.com", outDir: "/out", timeout: 10)) { error in
            guard case ExtractionError.executionFailed(let message) = error else {
                return XCTFail("Expected executionFailed, got \(error)")
            }
            XCTAssertTrue(message.hasSuffix("FINAL-DIAGNOSTIC"))
        }
    }

    private func stub(_ source: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zonecapture-drain-\(UUID().uuidString).py")
        try source.write(to: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path.path
    }
}
