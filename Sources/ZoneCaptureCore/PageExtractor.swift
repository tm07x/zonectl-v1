import Foundation

/// Errors that can occur while extracting a web page to Markdown + JSON.
public enum ExtractionError: Error, Equatable {
    /// The configured Python script does not exist.
    case scriptNotFound
    /// The runner produced a non-zero exit or could not be launched.
    case executionFailed(String)
    /// The runner produced output that could not be decoded as the expected
    /// JSON structure.
    case invalidOutput
    /// The runner exited successfully but returned an error payload.
    case runnerError(String)
}

/// Result of a successful page extraction.
public struct ExtractionResult: Codable, Equatable {
    public let capturePath: String
    public let jsonPath: String
    public let title: String
    public let wordCount: Int

    enum CodingKeys: String, CodingKey {
        case capturePath = "capture_path"
        case jsonPath = "json_path"
        case title
        case wordCount = "word_count"
    }
}

/// Something that can download a URL and write a Markdown + JSON capture.
public protocol ExtractionRunner: Sendable {
    /// Runs the extraction synchronously (the underlying process is blocking).
    /// Throws `ExtractionError` on failure.
    func run(url: String, outDir: String, timeout: TimeInterval) throws -> ExtractionResult
}

/// Runs `tools/zone_extract.py` in a subprocess and parses its JSON stdout.
public final class PythonExtractionRunner: ExtractionRunner {
    public let scriptPath: String

    public init(scriptPath: String) {
        self.scriptPath = scriptPath
    }

    public func run(url: String, outDir: String, timeout: TimeInterval) throws -> ExtractionResult {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ExtractionError.scriptNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptPath, url, "--out", outDir, "--timeout", String(Int(timeout))]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ExtractionError.executionFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            let message = errString?.isEmpty == false ? errString! : "exit code \(process.terminationStatus)"
            throw ExtractionError.executionFailed(message)
        }

        // On success the script prints the extraction result JSON.
        // On failure it prints {"error": "..."} and exits non-zero, so we
        // only reach here for success.
        return try PageExtractor.parseOutput(outData)
    }
}

/// Thin facade over an `ExtractionRunner` that stays testable by injection.
public final class PageExtractor {
    private let runner: ExtractionRunner

    public init(runner: ExtractionRunner) {
        self.runner = runner
    }

    /// Extracts `url` into `outDir` using the configured runner.
    @discardableResult
    public func extract(url: String, outDir: String, timeout: TimeInterval = 60) throws -> ExtractionResult {
        try runner.run(url: url, outDir: outDir, timeout: timeout)
    }

    /// Parses the JSON contract returned by `zone_extract.py` on success.
    public static func parseOutput(_ data: Data) throws -> ExtractionResult {
        do {
            return try JSONDecoder().decode(ExtractionResult.self, from: data)
        } catch {
            // Also attempt to surface a runner error payload if one sneaks in.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String {
                throw ExtractionError.runnerError(err)
            }
            throw ExtractionError.invalidOutput
        }
    }
}
