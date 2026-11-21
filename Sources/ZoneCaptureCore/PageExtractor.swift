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

extension ExtractionError: CustomStringConvertible {
    /// Short, user-presentable description — the capture banner shows this.
    public var description: String {
        switch self {
        case .scriptNotFound: return "extractor script not found"
        case .executionFailed(let message): return message
        case .invalidOutput: return "extractor returned unreadable output"
        case .runnerError(let message): return message
        }
    }
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
///
/// Two lifecycle hazards are handled here because both have bitten in
/// practice:
///
/// - Both pipes are drained WHILE the child runs. Reading only after
///   `waitUntilExit()` deadlocks as soon as the child fills a pipe buffer
///   (~64 KB) — one chatty dependency warning wedges the capture forever.
/// - A watchdog kills the child after `timeout + watchdogGrace` seconds. The
///   script's own `--timeout` only bounds socket operations, not DNS lookups,
///   redirect chains, or pathological parsing.
public final class PythonExtractionRunner: ExtractionRunner {
    public let scriptPath: String

    /// Interpreter to launch the script with. The installed .app passes its
    /// bundled venv here because a GUI app's `/usr/bin/env python3` resolves
    /// to the Command Line Tools interpreter, which lacks the extraction
    /// dependencies. Nil keeps the old `/usr/bin/env python3` behaviour.
    public let pythonPath: String?

    /// Extra seconds past `timeout` before the watchdog kills the child.
    /// Internal (not private) so tests can shrink it.
    let watchdogGrace: TimeInterval

    public init(scriptPath: String, pythonPath: String? = nil, watchdogGrace: TimeInterval = 15) {
        self.scriptPath = scriptPath
        self.pythonPath = pythonPath
        self.watchdogGrace = watchdogGrace
    }

    public func run(url: String, outDir: String, timeout: TimeInterval) throws -> ExtractionResult {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ExtractionError.scriptNotFound
        }

        let process = Process()
        let scriptArgs = [scriptPath, url, "--out", outDir, "--timeout", String(Int(timeout))]
        if let pythonPath {
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = scriptArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + scriptArgs
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        defer {
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            throw ExtractionError.executionFailed(error.localizedDescription)
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let stdoutDrain = PipeDrain(stdout.fileHandleForReading)
        let stderrDrain = PipeDrain(stderr.fileHandleForReading)
        let deadline = DispatchTime.now() + timeout + watchdogGrace

        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            _ = try? stdoutDrain.finish(by: .now() + 2)
            _ = try? stderrDrain.finish(by: .now() + 2)
            throw ExtractionError.executionFailed("timed out after \(Int(timeout))s")
        }

        let outData = try stdoutDrain.finish(by: deadline)
        let errData = try stderrDrain.finish(by: deadline)

        guard process.terminationStatus == 0 else {
            // The script reports failures as {"error": "..."} on STDOUT with
            // exit code 1; stderr stays empty in that path. Surface the
            // payload so the banner can show the actual reason.
            if let payload = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
               let message = payload["error"] as? String {
                throw ExtractionError.executionFailed(message)
            }
            let errString = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExtractionError.executionFailed(
                errString?.isEmpty == false ? errString! : "exit code \(process.terminationStatus)")
        }

        // On success the script prints the extraction result JSON.
        return try PageExtractor.parseOutput(outData)
    }
}

private final class PipeDrain: @unchecked Sendable {
    private let done = DispatchGroup()
    private var result: Swift.Result<Data, Error>?

    init(_ handle: FileHandle) {
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.result = Swift.Result { try handle.readToEnd() ?? Data() }
            self.done.leave()
        }
    }

    func finish(by deadline: DispatchTime) throws -> Data {
        guard done.wait(timeout: deadline) == .success else {
            throw ExtractionError.executionFailed("timed out draining extractor output")
        }
        do {
            return try result!.get()
        } catch {
            throw ExtractionError.executionFailed("couldn't read extractor output: \(error.localizedDescription)")
        }
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
    public func extract(url: String, outDir: String, timeout: TimeInterval = 20) throws -> ExtractionResult {
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
