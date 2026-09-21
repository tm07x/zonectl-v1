# Native Page Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the shipped Python page extractor with compiled Swift while preserving existing captures and making extraction failures bounded and observable.

**Architecture:** Keep the AppKit executable and existing store. Add a leaf `ZoneCaptureExtraction` module for contracts, HTML extraction, and Markdown; a bundled Swift `ZoneCaptureExtractor` executable isolates synchronous parsing. Native network/process/file services feed the existing coordinator through async interfaces, with journaled artifact publication before database acknowledgement.

**Tech Stack:** Swift tools 5.9+, macOS 13+, Foundation/URLSession, SwiftSoup pinned initially to 2.6.0, AppKit, system SQLite, XCTest, SwiftPM, and macOS code signing. No Rust, Python, SwiftNIO, hosted extractor, or S3 SDK in this phase.

## Global Constraints

- Approved spec: `docs/superpowers/specs/2026-09-16-native-page-extraction-design.md`.
- Planning baseline: `b837f95`; production code baseline: `9c668cf`.
- Repository: `/Users/tm07x/GROKKED-INK/VM-APPS/zonecapture`.
- macOS deployment floor remains 13; Swift tools floor remains 5.9.
- "The extraction deadline is 20 seconds across fetch, redirects, and parsing."
- "then force-terminate the owned helper after at most one additional second."
- "Limit redirects to five"; reject HTTPS-to-HTTP and non-HTTP(S) redirects.
- "Enforce a 10 MiB limit on the decoded HTTP body during receipt".
- "Bound traversal to 200,000 DOM nodes and depth 256, and emitted Markdown to 10 MiB."
- "Bound title and URL fields to 8 KiB each and helper JSON output to 64 MiB including escaping."
- Preserve both default shortcuts and the unattended page-capture flow.
- Preserve old DB IDs, rows, Markdown, sidecars, and production data directories.
- Do not add runtime Python, PATH/source-tree fallback, JavaScript extraction, cloud dependencies, automatic collection, API endpoints, or transfers.
- AppKit state stays main-actor confined. Network, process waits, and file work stay off the main actor.
- Tests use disposable roots and owned fixture processes. Never reset the user's DB, uninstall Python, stop their everyday app, or overwrite an installed bundle without explicit consent.
- Build/test on this machine with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. This is command-scoped, not a change to global `xcode-select`.
- Run red before green for each regression. Compilation failure at a new seam is an acceptable first red; behavioral fixes also need a failing behavioral assertion.
- New mutable services use actors. Keep the existing Store lock boundary; do not rewrite unrelated storage or add `@unchecked Sendable` to all of Store.
- Document any narrowly scoped Foundation callback synchronization, never block an async executor on a semaphore.
- Inspect status and staged diff before commits; use configured Git identity and normal hooks. Never push as an implicit part of this plan.

---

## Scope and execution gate

This plan implements phase 1 only. The GUI diagnostic supervisor, stable fault
catalog, localhost API, public capture UUID migration, topic revisions, and
HTTPS/S3 delivery have separate approved specs and later plans.

The plan is documentation, not validated implementation code. The tests and
snippets below are requirements for the executing engineer to compile and run.
Do not report them as passing because this file was reviewed.

Before execution, use the isolated-workspace skill and check the actual branch.
Do not mix this work with the older
`docs/superpowers/plans/2026-09-04-automatic-context-capture.md`; automatic
context capture and that plan's system-library-only restriction are not part
of this owner-approved extraction revision.

Read the native spec, `Package.swift`, `PageExtractor.swift`,
`CaptureCoordinator.swift`, `Store.swift`, `AppDelegate.swift`, and
`Tests/TESTS_CONTEXT.md`. That test-context document contains historical counts;
measure current counts rather than copying them.

Dependency evidence: SwiftSoup's documented SwiftPM installation uses 2.6.0,
and its Swift 5 support predates that release. Documentation was consulted via
Context7 `/scinfu/swiftsoup`, including `getChildNodes()`, `select`, and `attr`.
Resolve and compile the exact version before relying on a newer master-only
API. Do not silently float the dependency if a compatibility test fails.

## File map and dependency direction

All paths below are repository-relative. Shell commands explicitly target the
absolute repository; substitute the isolated workspace's absolute root if used.

| Path | Responsibility |
|---|---|
| `Sources/ZoneCaptureExtraction/ExtractionFailure.swift` | Typed safe failures, no arbitrary error payloads |
| `Sources/ZoneCaptureExtraction/ExtractionPolicy.swift` | Limits, URL validation, monotonic deadline value |
| `Sources/ZoneCaptureExtraction/ExtractionTiming.swift` | Injected monotonic now/deadline wait seam |
| `Sources/ZoneCaptureExtraction/PageDocument.swift` | Codable request/result DTOs and extraction metadata |
| `Sources/ZoneCaptureExtraction/ReadableDocument.swift` | Restricted typed block/inline tree |
| `Sources/ZoneCaptureExtraction/HTMLContentExtractor.swift` | SwiftSoup selection and bounded DOM-to-tree conversion |
| `Sources/ZoneCaptureExtraction/MarkdownRenderer.swift` | Tree-to-Markdown escaping and bounded output |
| `Sources/ZoneCaptureCore/PageCapture/PageFetching.swift` | Async fetch protocol |
| `Sources/ZoneCaptureCore/PageCapture/NativePageFetcher.swift` | Ephemeral URLSession adapter |
| `Sources/ZoneCaptureCore/PageCapture/FetchOperation.swift` | Per-request delegate state and exact-once completion |
| `Sources/ZoneCaptureCore/PageCapture/PageTextDecoder.swift` | BOM/header/meta/UTF-8 decoding |
| `Sources/ZoneCaptureCore/PageCapture/DocumentParsing.swift` | Async parse protocol |
| `Sources/ZoneCaptureCore/PageCapture/NativeParserService.swift` | Helper launch, deadline/cancellation, result validation |
| `Sources/ZoneCaptureCore/PageCapture/HelperLocation.swift` | Bundle-relative executable resolution, no fallback |
| `Sources/ZoneCaptureCore/PageCapture/CaptureDraft.swift` | Local metadata for one capture |
| `Sources/ZoneCaptureCore/PageCapture/CapturePublishing.swift` | Async durable publication protocol |
| `Sources/ZoneCaptureCore/PageCapture/CaptureJournal.swift` | Owned paths and recoverable publication state |
| `Sources/ZoneCaptureCore/PageCapture/CaptureArtifactWriter.swift` | Bounded atomic files, sidecar/frontmatter, cleanup |
| `Sources/ZoneCaptureCore/PageCapture/NativeCapturePublisher.swift` | Files + serialized Store acknowledgement/recovery |
| `Sources/ZoneCaptureExtractor/main.swift` | Native parsing command, fixed file protocol |
| `Sources/ZoneCapture/AppDelegate.swift` | Thin composition and async hotkey UI handling |
| `Sources/ZoneCaptureCore/CaptureCoordinator.swift` | One capture at a time, fetch → parse → publish |
| `Sources/ZoneCaptureCore/Store.swift` | Timestamp injection, exact path-reference query, bounded DB waits |
| `Package.swift`, `Package.resolved` | New targets, pinned SwiftSoup, fixture resources |
| `make-app.sh` | Build/sign helper and app; no Python or pip |
| `Tests/ZoneCaptureExtractionTests/` | Pure policy/content/renderer tests |
| `Tests/ZoneCaptureTests/Native*Tests.swift` | Fetch/helper/publication integration tests |
| `Tests/ZoneCaptureTests/Support/` | Actor fakes, disposable roots, native fixtures |
| `Tests/Fixtures/ParserFixture/main.swift` | Test-only compiled helper modes, never packaged |
| `tools/check-native-bundle.sh` | Packaging assertions, no network or app launch |
| `README.md`, `Tests/TESTS_CONTEXT.md` | Accurate runtime/build/test documentation |

Dependency DAG:

```text
ZoneCaptureExtraction → SwiftSoup + Foundation
ZoneCaptureCore → ZoneCaptureExtraction + existing macOS/system SQLite
ZoneCaptureExtractor → ZoneCaptureExtraction
ZoneCapture → ZoneCaptureCore + ZoneCaptureExtraction
test targets → corresponding libraries; no library imports either executable
```

The helper shares only extraction types/code, not Store or the app bootstrap.
File count reflects distinct responsibilities, not a new multi-package hierarchy.
Public DTO initializers are required across module boundaries; synthesized memberwise
initializers on public Swift structs are not public.

## Shared interfaces

These are the names all tasks use. Define them in the listed files, not in a
second parallel registry. Defaults belong to `ExtractionPolicy`, not repeated
magic numbers in each service.

```swift
// ExtractionFailure.swift
public enum ExtractionFailure: String, Error, Codable, Sendable {
    case invalidURL, redirectRejected, httpFailure, transportFailure
    case unsupportedContent, invalidEncoding, noReadableContent, limitExceeded
    case helperUnavailable, helperFailed, invalidHelperResult
    case deadlineExceeded, cancelled, artifactIO, persistence, recoveryRequired, busy
}
```

```swift
// PageDocument.swift; each DTO has an explicit public initializer.
public struct FetchedPage: Codable, Equatable, Sendable {
    public let requestedURL: URL
    public let finalURL: URL
    public let text: String
    public let mediaType: String
    public init(requestedURL: URL, finalURL: URL, text: String, mediaType: String) {
        self.requestedURL = requestedURL; self.finalURL = finalURL
        self.text = text; self.mediaType = mediaType
    }
}
public struct ParsedPage: Codable, Equatable, Sendable {
    public let title: String
    public let markdown: String
    public let wordCount: Int
    public init(title: String, markdown: String, wordCount: Int) {
        self.title = title; self.markdown = markdown; self.wordCount = wordCount
    }
}
public struct ParserRequest: Codable, Sendable {
    public let version: Int
    public let page: FetchedPage
    public init(page: FetchedPage) { self.version = 1; self.page = page }
}
public struct ParserResponse: Codable, Sendable {
    public let version: Int
    public let result: ParsedPage?
    public let failure: ExtractionFailure?
    public init(result: ParsedPage?, failure: ExtractionFailure?) {
        self.version = 1; self.result = result; self.failure = failure
    }
}
```

```swift
// ExtractionPolicy.swift
public struct ExtractionPolicy: Sendable {
    public let bodyBytes = 10 * 1024 * 1024
    public let metadataBytes = 8 * 1024
    public let jsonBytes = 64 * 1024 * 1024
    public let nodeCount = 200_000
    public let depth = 256
    public let redirectCount = 5
    public let duration: Duration = .seconds(20)
    public let terminationGrace: Duration = .seconds(1)
    public init() {}
}
public struct ExtractionDeadline: Sendable {
    public let instant: ContinuousClock.Instant
    public init(now: ContinuousClock.Instant, duration: Duration) {
        instant = now.advanced(by: duration)
    }
    public func check(now: ContinuousClock.Instant) throws {
        if now >= instant { throw ExtractionFailure.deadlineExceeded }
        try Task.checkCancellation()
    }
}
```

```swift
// Protocols in the three correspondingly named core files.
public protocol PageFetching: Sendable {
    func fetch(_ url: URL, deadline: ExtractionDeadline) async throws -> FetchedPage
}
public protocol DocumentParsing: Sendable {
    func parse(_ page: FetchedPage, deadline: ExtractionDeadline) async throws -> ParsedPage
}
public protocol CapturePublishing: Sendable {
    func publish(_ draft: CaptureDraft, operationID: UUID) async throws -> Int64
    func recover() async throws
}
// CaptureDraft.swift
public struct CaptureDraft: Sendable {
    public let fetched: FetchedPage
    public let parsed: ParsedPage
    public let capturedAt: Date
    public let sourceApp: String?
    public let comment: String?
    public init(fetched: FetchedPage, parsed: ParsedPage, capturedAt: Date,
                sourceApp: String?, comment: String?) {
        self.fetched = fetched; self.parsed = parsed; self.capturedAt = capturedAt
        self.sourceApp = sourceApp; self.comment = comment
    }
}
```

Production services take the policy, paths/session factory, and clocks through
initializers. Define the clock seam in task 1 and use it in fetcher, parser, and
coordinator:

```swift
public struct ExtractionTiming: Sendable {
    public let now: @Sendable () -> ContinuousClock.Instant
    public let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
    }
    public init() {
        let clock = ContinuousClock()
        self.init(now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
    }
}
```

Tests can hold `now` at a captured instant and use a continuation-backed actor
to release deadline waits. This avoids synchronously reading a mutable actor
clock. Pure boundary tests pass explicit instants to `ExtractionDeadline.check`.
Do not add mutable global test overrides.

## Task 1: Establish native contracts and URL/limit policy

**Files:** Create the four extraction contract/timing files above, the three async
protocol files and `CaptureDraft.swift`; modify `Package.swift`; create
`Tests/ZoneCaptureExtractionTests/ExtractionPolicyTests.swift`.

**Consumes:** Foundation values only.
**Produces:** Shared interfaces above plus
`ExtractionPolicy.validatedURL(_ raw: String) throws -> URL`.
The old Python implementation remains runnable until task 7 switches packaging.

- [ ] **1. Write the URL policy regression first.**

```swift
import XCTest
@testable import ZoneCaptureExtraction

final class ExtractionPolicyTests: XCTestCase {
    func testOnlyBoundedCredentialFreeHTTPURLsAreAccepted() throws {
        let policy = ExtractionPolicy()
        let accepted = try policy.validatedURL("https://example.test/article")
        XCTAssertEqual(accepted.host, "example.test")
        for value in ["file:///etc/passwd", "javascript:alert(1)",
                      "https://user:password@example.test/", "https:///missing-host",
                      "https://example.test/" + String(repeating: "x", count: 8192)] {
            XCTAssertThrowsError(try policy.validatedURL(value), value)
        }
    }
    func testDeadlineFailsAtTheBoundary() throws {
        let now = ContinuousClock().now
        let deadline = ExtractionDeadline(now: now, duration: .seconds(20))
        XCTAssertNoThrow(try deadline.check(now: now.advanced(by: .seconds(19))))
        XCTAssertThrowsError(try deadline.check(now: now.advanced(by: .seconds(20))))
    }
}
```

- [ ] **2. Run red with the new test target declared but implementation absent.**

Use the target declarations shown in step 3 and create the supplied article
fixture from task 2 before the first run, so SwiftPM resource discovery succeeds.
The initial extraction source can contain only `import Foundation`; the policy
symbols must still be absent when the regression runs. A missing resource folder
is not the intended red.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --filter ExtractionPolicyTests
```

Expected: missing native types/member failure, not a TCC or network failure.

- [ ] **3. Add contracts and the concrete URL rule.**

```swift
// Add inside ExtractionPolicy.
public func validatedURL(_ raw: String) throws -> URL {
    guard raw.utf8.count <= metadataBytes,
          let parts = URLComponents(string: raw),
          let scheme = parts.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = parts.host, !host.isEmpty,
          parts.user == nil, parts.password == nil,
          let url = parts.url else { throw ExtractionFailure.invalidURL }
    return url
}
```

Use this exact dependency edge; retain the existing package platforms/targets:

```swift
.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.6.0")
```

```swift
.target(name: "ZoneCaptureExtraction", dependencies: ["SwiftSoup"],
        path: "Sources/ZoneCaptureExtraction"),
.testTarget(name: "ZoneCaptureExtractionTests",
            dependencies: ["ZoneCaptureExtraction"],
            path: "Tests/ZoneCaptureExtractionTests",
            resources: [.copy("Fixtures")])
```

Add `ZoneCaptureExtraction` to `ZoneCaptureCore` dependencies. Keep the Fixtures
directory and supplied HTML created for the red run.
Add `ZoneCaptureExtraction` explicitly to the existing `ZoneCaptureTests` target
and import it in tests using shared DTOs; do not depend on implicit re-exports.
Do not add the helper target before its source file exists. Track the root
`Package.resolved`; review dependency license and resolved revision.

- [ ] **4. Rerun the command from step 2; then run the full Swift suite.**

Expected: policy tests green; legacy tests unchanged. Record the result, do not
assume package resolution alone establishes compatibility.

- [ ] **5. Commit this independently testable boundary after the commit gate.**

Message: `feat: define native page extraction contracts`.

## Task 2: Extract readable content and render safe Markdown

**Files:** Create `ReadableDocument.swift`, `HTMLContentExtractor.swift`,
`MarkdownRenderer.swift`; create `HTMLContentExtractorTests.swift`,
`MarkdownRendererTests.swift` under `Tests/ZoneCaptureExtractionTests`;
create `Tests/ZoneCaptureExtractionTests/Fixtures/article.html`.

**Consumes:** `FetchedPage`, `ExtractionPolicy`, SwiftSoup.
**Produces:**
`HTMLContentExtractor.init(policy: ExtractionPolicy)`,
`HTMLContentExtractor.extract(_ page: FetchedPage) throws -> ReadableDocument`,
`MarkdownRenderer.init(policy: ExtractionPolicy)`,
`MarkdownRenderer.render(_ document: ReadableDocument) throws -> ParsedPage`.

- [ ] **1. Write the migrated fixture and a failing acceptance test.**

```html
<!doctype html><html><head><title>Example Title</title></head>
<body><nav>Home About</nav><article><h1>Real Headline</h1>
<p>This is the main content that matters.</p>
<p>Second paragraph of substance. <a href="/next">Read next</a>.</p>
<pre><code>print("&lt;safe&gt;")</code></pre></article>
<footer>Copyright Noise</footer><script>alert("do not run")</script></body></html>
```

```swift
func testExtractsArticleRatherThanNavigationOrActiveMarkup() throws {
    let location = try XCTUnwrap(Bundle.module.url(
        forResource: "article", withExtension: "html", subdirectory: "Fixtures"))
    let source = URL(string: "https://example.test/page")!
    let page = FetchedPage(requestedURL: source, finalURL: source,
        text: try String(contentsOf: location, encoding: .utf8),
        mediaType: "text/html")
    let document = try HTMLContentExtractor(policy: ExtractionPolicy()).extract(page)
    let result = try MarkdownRenderer(policy: ExtractionPolicy()).render(document)
    XCTAssertEqual(result.title, "Example Title")
    XCTAssertTrue(result.markdown.contains("main content that matters"))
    XCTAssertTrue(result.markdown.contains("(https://example.test/next)"))
    XCTAssertFalse(result.markdown.contains("Copyright Noise"))
    XCTAssertFalse(result.markdown.contains("<script"))
    XCTAssertFalse(result.markdown.contains("do not run"))
    XCTAssertTrue(result.markdown.contains("print(\"<safe>\")"))
    XCTAssertGreaterThan(result.wordCount, 0)
}
```

Place the method in an XCTestCase with `import ZoneCaptureExtraction`. Add a
table-driven suite of literal HTML/expected Markdown pairs for the tags below,
including an HTML-looking string inside a fenced code block.

- [ ] **2. Run the new classes red.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --filter 'HTMLContentExtractorTests|MarkdownRendererTests'
```

- [ ] **3. Define the restricted tree and implement DOM conversion.**

```swift
public indirect enum ReadableInline: Equatable, Sendable {
    case text(String), code(String), emphasis([ReadableInline])
    case strong([ReadableInline]), link([ReadableInline], URL), lineBreak
}
public indirect enum ReadableBlock: Equatable, Sendable {
    case paragraph([ReadableInline]), heading(Int, [ReadableInline])
    case code(String), quote([ReadableBlock])
    case list(ordered: Bool, items: [[ReadableBlock]])
    case table(header: [[ReadableInline]], rows: [[[ReadableInline]]])
}
public struct ReadableDocument: Equatable, Sendable {
    public let title: String
    public let blocks: [ReadableBlock]
    public init(title: String, blocks: [ReadableBlock]) {
        self.title = title; self.blocks = blocks
    }
}
```

Use `SwiftSoup.parse(page.text, page.finalURL.absoluteString)`, then:

1. Before recursive conversion, walk `Node.getChildNodes()` using an explicit
   `(node, depth)` stack; fail above either node/depth limit.
2. Remove `nav, footer, header, aside, script, style, noscript, template, form,
   button, input, select, textarea, iframe, object, embed, svg, canvas` and
   elements marked `hidden` or `aria-hidden=true`.
3. From nonempty `article`/`main` candidates, choose the highest text score,
   preferring `article` on equal score and then document order.
4. If none exists, score `section, div, body` blocks by non-link text length
   plus 80 per paragraph, minus twice linked-text length. Exclude empty blocks;
   break ties by shallower depth then document order. Select one root, not all
   overlapping candidates. Do not drop all content merely for being short.
5. Title precedence is nonempty document title, first main heading, then final
   host. Decode entities through SwiftSoup; enforce the metadata bound.
6. Convert only known semantic nodes into the tree below; unknown wrappers
   contribute their children. Comments and executable nodes contribute nothing.
7. For plain text, create paragraphs separated by blank lines without HTML parsing.

Bound every conversion traversal, not just final rendering. Check for empty
rendered text as well as empty DOM selection.

| HTML | Tree conversion |
|---|---|
| `p`, text-bearing wrappers | paragraph preserving inline order |
| `h1`–`h6` | heading with corresponding level |
| `em`, `i`, `strong`, `b` | emphasis/strong |
| `code` outside `pre` | inline code from decoded text |
| `pre` | fenced-code block preserving whitespace |
| `blockquote` | quote of recursively converted blocks |
| `ul`, `ol`, `li` | ordered/unordered list, including nested blocks |
| `table`, `tr`, `th`, `td` | padded rectangular table; synthetic empty header if absent |
| `br` | explicit line break |
| `a[href]` | HTTP(S) resolved link; invalid/unsafe href becomes plain child text |
| `img` | alt text only, never fetch or emit an external image |

The link conversion uses the shared policy, including URL user-info rejection:

```swift
func resolvedLink(_ raw: String, base: URL, policy: ExtractionPolicy) -> URL? {
    guard let absolute = URL(string: raw, relativeTo: base)?.absoluteURL else { return nil }
    return try? policy.validatedURL(absolute.absoluteString)
}
```

Scope this method inside `HTMLContentExtractor`; do not create a free function.

- [ ] **4. Render only the typed tree, with bounded appends.**

The renderer's internal `append(_:)` throws before `output.utf8.count` would
exceed `bodyBytes`. Escape backslash, brackets, Markdown punctuation, and `<`/`>`
in ordinary text. Preserve code text without interpreting it.

Use this fence method inside the renderer:

```swift
func fenced(_ text: String) -> String {
    let longest = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" })
        .map(\.count).max() ?? 0
    let fence = String(repeating: "`", count: max(3, longest + 1))
    return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
}
```

Render inline code with a backtick delimiter longer than any run in its text,
padding when needed to preserve edge spaces/backticks. Render links with an
angle-delimited, percent-encoded destination so parentheses cannot escape the
destination. Never carry `javascript:`, `data:`, `file:`, or raw HTML through.
Use two spaces plus newline for explicit breaks; separate block output with
blank lines. Indent nested list blocks under their item marker. Escape pipes
inside table cells and flatten cell line breaks to spaces. Emit `---` header
separators and pad short rows rather than losing cells.

The final result is computed from the rendered body:

```swift
let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
guard !body.isEmpty else { throw ExtractionFailure.noReadableContent }
return ParsedPage(title: document.title, markdown: body,
                  wordCount: body.split(whereSeparator: \.isWhitespace).count)
```

Here `output` is the renderer's bounded accumulator and `document` is its
`render(_:)` argument. Reset the accumulator for each call, or keep it local.

- [ ] **5. Run green plus hostile/limit fixtures.**

Add fixtures for malformed HTML, an unsafe link, multibyte text at the byte
limit, over-depth trees, over-node trees, empty content, nested lists, and
backticks/pipes in code/table cells. Each must assert a specific result or
`ExtractionFailure`, not merely "did not crash". Run task 2's command and the
policy tests. Commit: `feat: extract readable Markdown with Swift`.

## Task 3: Bounded native HTTP fetch and text decoding

**Files:** Create `PageTextDecoder.swift`, `FetchOperation.swift`,
`NativePageFetcher.swift`; create `NativePageFetcherTests.swift` and
`PageTextDecoderTests.swift`; create
`Tests/ZoneCaptureTests/Support/HTTPFixtureServer.swift`.

**Consumes:** `PageFetching`, policy, deadline, URLSession.
**Produces:** `NativePageFetcher` actor implementing `PageFetching`, initialized
with `policy: ExtractionPolicy` and `timing: ExtractionTiming = ExtractionTiming()`;
`PageTextDecoder.init(policy: ExtractionPolicy)`,
`PageTextDecoder.decode(_ data: Data, mediaType: String, charset: String?) throws -> String`;
an owned Swift loopback HTTP fixture with `start() async throws -> URL`,
`stop() async`, and immutable configured response scenarios.

- [ ] **1. Write the small-limit and charset regressions.**

```swift
func testUTF8AndDeclaredCharsetDecodeWithoutLoss() throws {
    let decoder = PageTextDecoder(policy: ExtractionPolicy())
    XCTAssertEqual(try decoder.decode(Data("æøå".utf8),
        mediaType: "text/plain", charset: nil), "æøå")
    XCTAssertEqual(try decoder.decode(Data([0x63, 0x61, 0x66, 0xe9]),
        mediaType: "text/plain", charset: "windows-1252"), "café")
    XCTAssertThrowsError(try decoder.decode(Data([0xff]),
        mediaType: "text/plain", charset: "utf-8"))
}
```

Use a pure chunk accumulator test for the 10 MiB bound so tests do not depend
on socket buffering to exercise the limit:

```swift
func testDecodedBodyOverflowIsFailureNotTruncation() throws {
    var body = BoundedBody(maxBytes: 3)
    try body.append(Data([1, 2, 3]))
    XCTAssertThrowsError(try body.append(Data([4]))) {
        XCTAssertEqual($0 as? ExtractionFailure, .limitExceeded)
    }
}
```

Define `BoundedBody` in `FetchOperation.swift` as a file-local implementation
type exposed internally to `@testable` tests, not a new public API.

- [ ] **2. Run red.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --filter 'NativePageFetcherTests|PageTextDecoderTests'
```

- [ ] **3. Implement bounded receipt and deterministic charset selection.**

```swift
struct BoundedBody {
    let maxBytes: Int
    private(set) var data = Data()
    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= maxBytes - data.count else {
            throw ExtractionFailure.limitExceeded
        }
        data.append(chunk)
    }
}
```

The per-request `URLSessionDataDelegate` accumulates the *decoded/decompressed*
chunks delivered by URLSession. Never use an unbounded `data(for:)` call and
then check size afterward. Configure `.ephemeral`, nil cookie storage, no
credential storage, no cache, and `.reloadIgnoringLocalCacheData`.

`FetchOperation` owns response state, redirect count, cancellable task, bounded
body, and continuation. Serialize delegate state on its own delegate queue;
confine cancellation to that queue and document this Foundation adapter
exception. A short exact-once continuation guard may use the concurrency
carve-out, but no ongoing domain state belongs in an unchecked global.

| Callback/condition | Action |
|---|---|
| Headers, status not 2xx | cancel; `.httpFailure` |
| MIME not HTML/XHTML/plain text | cancel; `.unsupportedContent` |
| Advertised length over bound | cancel early; `.limitExceeded` |
| Data chunk exceeds bound | cancel immediately; `.limitExceeded` |
| Redirect count becomes six | refuse; `.redirectRejected` |
| Redirect violates URL policy or downgrades HTTPS | refuse; `.redirectRejected` |
| Auth challenge | no stored credentials; default server-trust handling only |
| Deadline/cancellation | cancel underlying URLSession task and finish exactly once |
| URLSession transport failure | safe category, not raw localized description |
| Complete | decode, enforce UTF-8 bound, return `FetchedPage` |

Resolve a relative redirect against the current response URL. Keep the original
requested URL separate from the accepted final URL. Reject embedded user-info
before requests and at every redirect. Preserve a typed policy failure when
URLSession subsequently reports cancellation.

Decoder selection is BOM → header charset → HTML meta within 1,024 bytes →
UTF-8. Detect UTF-8/UTF-16/UTF-32 BOMs longest-first and remove the BOM bytes.
Use IANA charset conversion via CoreFoundation; reject invalid/unsupported
encodings. The bounded ASCII meta scan recognizes both `charset=` and
`http-equiv=content-type` declarations, with quoted or unquoted attributes.
Do not decode with replacement characters or reinterpret invalid UTF-8 as Latin-1.
The resulting UTF-8 string must also fit the body limit.

- [ ] **4. Test actual HTTP behavior using the Swift fixture.**

The fixture uses Network.framework bound explicitly to `127.0.0.1`, an
OS-selected port, bounded accepted requests, and preconfigured byte responses.
It is not a production HTTP server. Implement fixture routes for:

```text
/ok           200 text/html; charset=utf-8 + fixture article
/plain        200 text/plain + Unicode text
/status       404 + bounded body
/redirect/N   302 Location: /redirect/(N-1), ending at /ok
/chunked      200 Transfer-Encoding: chunked, without Content-Length
/large        200 with bytes beyond the body bound
/stalled      send headers then keep the owned connection open until cancelled
/binary       200 application/pdf
```

Assertions cover all routes, response close, cancellation, final URL, and
refused redirects. Test HTTPS downgrade policy directly with synthetic
HTTPURLResponse/request values; a real TLS fixture is not required to validate
the redirect decision. A timeout test releases an injected deadline wait and
asserts the underlying task closes, rather than sleeping to "let it finish".

- [ ] **5. Run green and commit.**

Run task 3's command and the complete Swift suite.
Commit: `feat: fetch pages with bounded native networking`.

## Task 4: Bundle a Swift parser process with a cancellable supervisor

**Files:** Create `Sources/ZoneCaptureExtractor/main.swift`,
`NativeParserService.swift`, `HelperLocation.swift`,
`Tests/Fixtures/ParserFixture/main.swift`,
`Tests/ZoneCaptureTests/NativeParserServiceTests.swift`; modify `Package.swift`.

**Consumes:** `ParserRequest`, `ParserResponse`, extractor/renderer, deadline.
**Produces:**
`NativeParserService.init(helperURL: URL, temporaryRoot: URL, policy: ExtractionPolicy, timing: ExtractionTiming = ExtractionTiming())`,
`NativeParserService.parse(_:deadline:)`,
`HelperLocation.resolve(in bundleURL: URL) throws -> URL`.

- [ ] **1. Write a missing-helper test and a protocol-validation test.**

```swift
func testMissingHelperIsAnExplicitFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = NativeParserService(helperURL: root.appendingPathComponent("missing"),
                                     temporaryRoot: root, policy: ExtractionPolicy())
    let source = URL(string: "https://example.test/")!
    do {
        _ = try await service.parse(
            FetchedPage(requestedURL: source, finalURL: source,
                        text: "<p>Hello</p>", mediaType: "text/html"),
            deadline: ExtractionDeadline(now: ContinuousClock().now, duration: .seconds(2)))
        XCTFail("missing helper must fail")
    } catch {
        XCTAssertEqual(error as? ExtractionFailure, .helperUnavailable)
    }
}
```

Protocol tests decode literal JSON: wrong version, both result and failure,
neither result nor failure, negative/incorrect word count, empty Markdown,
over-limit title, unexpected path-bearing fields, and malformed JSON. Each must
throw `.invalidHelperResult` or `.limitExceeded`, not return success.

- [ ] **2. Run red; then add executable targets and compile them explicitly.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --filter NativeParserServiceTests
```

```swift
.executableTarget(name: "ZoneCaptureExtractor",
    dependencies: ["ZoneCaptureExtraction"], path: "Sources/ZoneCaptureExtractor"),
.executableTarget(name: "ParserFixture", dependencies: [],
    path: "Tests/Fixtures/ParserFixture")
```

`ParserFixture` is a test-only product. Explicitly build it for helper integration
tests, never copy it into a shipping app. It has modes `success`, `malformed`,
`fail`, `flood`, and `stall`. Tests copy its executable to owned paths named
`ParserFixture-success`, `ParserFixture-stall`, etc., then pass that absolute
path as `helperURL`. The fixture derives its mode from its executable basename:

```swift
let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let mode = executableName.replacingOccurrences(of: "ParserFixture-", with: "")
```

Only the test fixture interprets those names. Its remaining argv is the same
`--input`/`--output` protocol as production; no production helper fault flags,
extra runner arguments, or hidden app environment switches are needed.

- [ ] **3. Implement the fixed helper protocol and restricted output.**

The production helper accepts exactly `--input <path> --output <path>`. No URL
fetch, arbitrary output directory, command execution, dynamic library loading,
or descendant process. The parent creates both locations in a fresh owned root.

```swift
// Successful execution body inside the helper's command type.
let request = try JSONDecoder().decode(ParserRequest.self, from: inputData)
guard request.version == 1 else { throw ExtractionFailure.invalidHelperResult }
let policy = ExtractionPolicy()
let document = try HTMLContentExtractor(policy: policy).extract(request.page)
let parsed = try MarkdownRenderer(policy: policy).render(document)
let response = ParserResponse(result: parsed, failure: nil)
let encoded = try JSONEncoder().encode(response)
guard encoded.count <= policy.jsonBytes else { throw ExtractionFailure.limitExceeded }
try encoded.write(to: outputURL, options: [.atomic])
```

`inputData` is read only after checking regular-file type, no symlink, and bounded
file size; validate the decoded request fields too. For extraction errors write
`ParserResponse(result: nil, failure: safeFailure)` and exit nonzero. An unexpected
Swift error becomes `.helperFailed`, not a serialized arbitrary description.

Reject unknown top-level response keys before Codable decoding, including any
path field; the fixed response schema has only `version`, `result`, and `failure`.
Content safety is tested at the typed-tree renderer boundary in task 2, not by
an ad hoc regular-expression Markdown sanitizer in the process supervisor.

Use mode-0700 operation directories and mode-0600 files. The parent opens/reads
only its predetermined regular output file. Never trust helper-returned paths.
JSON is bounded on disk before loading; post-read bounds still apply.

- [ ] **4. Implement the process lifecycle state machine.**

`NativeParserService` owns one process operation. Store `Process` and pending
continuation in actor-isolated state. Install `terminationHandler` before
launching. Bridge that callback through a task into the actor and use the
operation UUID to reject stale/duplicate completion.

```text
idle → starting → running → completed
                  running → terminating → force-terminated → completed
                  running → exited-with-error → completed
```

Create the deadline task before launch; a cancellation arriving while starting
must be remembered and acted on before/after `run()`. Set stdout/stderr to
`FileHandle.nullDevice`. The flood fixture must therefore never block the parent.
Do not wait synchronously with `waitUntilExit()` or collect arbitrary stderr.

On deadline or cancellation: mark the reason once, call `terminate()` only on
the owned running process, schedule a one-second grace deadline, and send SIGKILL
only if that same process operation is still alive. Retain ownership until its
termination callback is handled. Cancel timers on ordinary exit and cleanup;
never use a recycled PID from a stale timer.

Pass the same `ExtractionDeadline` from fetching to parsing. No fresh 20-second
budget at the helper boundary. If already expired, do not launch. Deadline
completion and cancellation resume the caller exactly once after bounded cleanup.
Unexpected helper exit preserves a safe numeric exit/signal category for future
diagnostics, without treating an empty output file as a successful parse.

Location resolution is deterministic:

```swift
public func resolve(in bundleURL: URL) throws -> URL {
    let candidate = bundleURL.appendingPathComponent("Contents/Helpers/ZoneCaptureExtractor")
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
        throw ExtractionFailure.helperUnavailable
    }
    return candidate
}
```

This method belongs to the value type `HelperLocation`. Tests inject a synthetic
bundle root; the app passes `Bundle.main.bundleURL`.

- [ ] **5. Run real helper tests and green lifecycle regressions.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --product ZoneCaptureExtractor
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --product ParserFixture
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --filter NativeParserServiceTests
```

Pass test executable paths explicitly from SwiftPM's `--show-bin-path`; do not
hardcode `.build/arm64-apple-macosx` or use the user's PATH to find a parser.
Test cancellation before launch, during execution, normal completion racing
deadline, malformed output, crash, stdout/stderr flood, stall/forced termination,
path/symlink rejection, cleanup, and a second successful operation after timeout.
Use a deliberately injected fixture stall, not a real website, as the watchdog
regression. Commit: `feat: isolate native parsing in a bounded Swift helper`.

## Task 5: Publish compatible artifacts with recoverable ownership

**Files:** Create `CaptureJournal.swift`, `CaptureArtifactWriter.swift`,
`NativeCapturePublisher.swift`; modify `Store.swift`; create
`NativeCapturePublisherTests.swift`; extend `StoreTests.swift`.

**Consumes:** `CaptureDraft`, serialized Store, caller-supplied captures root.
**Produces:** `NativeCapturePublisher` actor implementing `CapturePublishing`;
`Store.hasCapturePath(_ path: String) throws -> Bool`;
optional `createdAt: Date = Date()` appended to `Store.insertLink(...)`.

- [ ] **1. Write exact-data and failure assertions.**

Use the existing disposable `Store(rootDirectory:)` pattern. Publish a synthetic
draft with timestamp `Date(timeIntervalSince1970: 1234)`, source URL
`https://example.test/page`, final URL `https://example.test/final`, title
`A "quoted" title`, Markdown `# Hello\n\nWorld`, and nil note.

```swift
let id = try await publisher.publish(draft, operationID: operationID)
let rows = store.recentAll()
XCTAssertEqual(rows.count, 1)
XCTAssertEqual(rows[0].id, id)
XCTAssertEqual(rows[0].created, draft.capturedAt)
XCTAssertEqual(rows[0].url, draft.fetched.requestedURL.absoluteString)
XCTAssertEqual(rows[0].kind, "capture")
let path = try XCTUnwrap(rows[0].capturePath)
let markdown = try String(contentsOfFile: path, encoding: .utf8)
XCTAssertTrue(markdown.hasPrefix("---\n"))
XCTAssertTrue(markdown.contains(draft.parsed.markdown))
XCTAssertTrue(try store.hasCapturePath(path))
```

Here the test creates `draft` with the shared initializer, `operationID = UUID()`,
and `publisher = NativeCapturePublisher(store: store, capturesRoot: capturesRoot)`.
Derive `capturesRoot` from that test store, never `Store.shared`.

Repeat the same operation ID and expect the same committed row, not a duplicate.
Make a broken test store using a directory at `zonecapture.db`; publication
must throw and never acknowledge a saved capture.

- [ ] **2. Run red.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --filter 'NativeCapturePublisherTests|StoreTests'
```

- [ ] **3. Add bounded, throwing Store operations without changing old callers.**

Append `createdAt: Date = Date()` to `insertLink` and bind that argument instead
of constructing another Date at insert time. All existing calls remain valid.
Set a finite SQLite busy timeout (1,000 ms) on successful open.

Add the path-reference query using the same lock/prepare/bind/finalize discipline
as existing methods:

```sql
SELECT 1 FROM links WHERE capture_path = ? LIMIT 1;
```

Return true on `SQLITE_ROW`, false on `SQLITE_DONE`, and throw `StoreError.queryFailed`
for prepare/step failure. A failed query must never mean "unreferenced" during
recovery. Use `SQLITE_TRANSIENT`, not a borrowed Swift string pointer.

Add `Store.captureID(forPath:) throws -> Int64?` with the same query selecting
`id`; the publisher uses it for interrupted commit/idempotent recovery.
Document this small bridge as existing lock-serialized SQLite, not a new
Sendable guarantee for arbitrary Store mutation.

- [ ] **4. Write artifacts and a durable journal before the DB insert.**

```swift
struct CaptureJournal: Codable {
    enum State: String, Codable { case prepared, published, committed, aborted }
    let operationID: UUID
    let markdownName: String
    let sidecarName: String
    let markdownSHA256: String
    let sidecarSHA256: String
    var state: State
    var rowID: Int64?
}
```

Generate names from the operation UUID, not the page title:
`<UUID>.md`, `<UUID>.json`. Put journal/staging data in
`captures/.operations/<UUID>/` and publish artifacts directly under `captures/`.
Never accept path separators or absolute paths in journal basenames. Resolve
and validate ownership before reads/deletes; symlinked operation paths are
quarantined, not followed.

Use `JSONEncoder` for the sidecar and JSON string encoding for each YAML scalar.
Preserve `title`, `url`, `site`, `captured_at`, `word_count`, `markdown`, plus
additive `final_url` and extractor identity/version. Compute a UTC RFC 3339
timestamp once from `draft.capturedAt` and use it in both files and the DB row.
No source-app note or unrelated user data goes into the helper request.
Construct bounded artifact bytes first and compute their SHA-256 with CryptoKit
for the prepared journal. During recovery, compare actual content against those
hashes before treating an operation as intact; a filename alone is insufficient.
Limit sidecar JSON to 64 MiB and Markdown-with-frontmatter to the body bound plus
64 KiB of metadata, while the Markdown body itself stays within 10 MiB.

```text
1. Create owned operation directory and prepared journal.
2. Write/flush staged Markdown and sidecar; validate byte limits.
3. Atomically rename both individual artifacts into their final locations.
4. Atomically update/flush the journal to published.
5. Insert DB row pointing at final Markdown; require a positive row ID.
6. Atomically update/flush journal to committed with row ID.
7. Return acknowledged row ID; retain a small committed receipt for replay.
```

Renaming two files is not one atomic action. The journal must recover interruption
between either rename and before/after insert. Use owner-only files, atomic
same-filesystem replacement, and file/directory synchronization at the durable
boundaries. Do not promise power-loss durability from `Data.write(.atomic)` alone.

Keep committed receipts bounded to the latest 100 operation IDs. Do not evict
unresolved journals as a retention shortcut. If unresolved operations exceed
100, block further page capture with `.recoveryRequired` rather than grow without
bound or delete possibly valuable artifacts. URL/note capture stays available.

- [ ] **5. Implement conservative recovery and inject each interruption.**

| Evidence | Recovery |
|---|---|
| Valid owned prepared journal, no DB reference | remove only owned staged/final artifacts; mark aborted |
| Published artifacts, DB reference exists | preserve artifacts; mark receipt committed with row ID |
| Published artifacts, exact DB query confirms no reference | remove only owned artifacts; mark aborted |
| DB query fails or commit outcome remains uncertain | preserve journal/files; `.recoveryRequired` |
| Referenced artifact missing/corrupt | preserve evidence; `.recoveryRequired`, never delete the row |
| Malformed journal, traversal, symlink, unknown file ownership | preserve/quarantine within owned root; never follow/delete target |
| Existing user files without a journal | do not modify |

Use a constructor-injected publication-boundary hook in tests, not an environment
switch exposed by the shipping app. The hook can throw at each numbered boundary
above. After each injected stop, recreate the publisher over the same disposable
root and run `recover()`. Assert exact remaining rows/artifacts, not just absence
of a crash. Preserve any already acknowledged data when journal cleanup fails.

- [ ] **6. Run green and commit.**

Rerun task 5's command and concurrent Store insertion regressions.
Commit: `feat: journal native capture artifact publication`.

## Task 6: Switch coordinator and AppKit wiring to native async capture

**Files:** Rewrite `CaptureCoordinator.swift`; update `AppDelegate.swift`;
rewrite `CaptureCoordinatorTests.swift`; add actor fakes in
`Tests/ZoneCaptureTests/Support/NativeCaptureFakes.swift`.

**Consumes:** `PageFetching`, `DocumentParsing`, `CapturePublishing`, policy.
**Produces:** `CaptureCoordinator` actor with
`capturePage(url:sourceApp:comment:) async throws -> Int64` and
`recover() async throws`.

- [ ] **1. Write the async orchestration and no-false-success regressions.**

Actor test doubles:

```swift
actor FakePageFetcher: PageFetching {
    let page: FetchedPage
    private(set) var calls = 0
    init(page: FetchedPage) { self.page = page }
    func fetch(_ url: URL, deadline: ExtractionDeadline) async throws -> FetchedPage {
        calls += 1
        return page
    }
}
actor FakeDocumentParser: DocumentParsing {
    let page: ParsedPage
    init(page: ParsedPage) { self.page = page }
    func parse(_ input: FetchedPage, deadline: ExtractionDeadline) async throws -> ParsedPage {
        page
    }
}
actor FakeCapturePublisher: CapturePublishing {
    var drafts: [CaptureDraft] = []
    let failure: ExtractionFailure?
    init(failure: ExtractionFailure? = nil) { self.failure = failure }
    func publish(_ draft: CaptureDraft, operationID: UUID) async throws -> Int64 {
        if let failure { throw failure }
        drafts.append(draft)
        return 1
    }
    func recover() async throws {}
}
```

The tests construct the three fakes, call the async method, then assign actor
properties to local values before passing them to XCTest autoclosures.

```swift
let publisher = FakeCapturePublisher(failure: .persistence)
let coordinator = CaptureCoordinator(fetcher: fetcher, parser: parser,
                                     publisher: publisher, policy: ExtractionPolicy())
do {
    _ = try await coordinator.capturePage(url: "https://example.test/page",
                                          sourceApp: "Safari", comment: nil)
    XCTFail("failed persistence must not return success")
} catch {
    XCTAssertEqual(error as? ExtractionFailure, .persistence)
}
let count = await publisher.drafts.count
XCTAssertEqual(count, 0)
```

In this test, `fetcher` and `parser` are the actor fakes initialized with the
same synthetic `FetchedPage`/`ParsedPage` used in task 5.

- [ ] **2. Run red before changing the coordinator.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture --filter CaptureCoordinatorTests
```

- [ ] **3. Implement one operation and one deadline per capture.**

```swift
public func capturePage(url: String, sourceApp: String?, comment: String?) async throws -> Int64 {
    guard !active else { throw ExtractionFailure.busy }
    active = true
    defer { active = false }
    let source = try policy.validatedURL(url)
    let deadline = ExtractionDeadline(now: timing.now(), duration: policy.duration)
    let fetched = try await fetcher.fetch(source, deadline: deadline)
    try deadline.check(now: timing.now())
    let parsed = try await parser.parse(fetched, deadline: deadline)
    try deadline.check(now: timing.now())
    let draft = CaptureDraft(fetched: fetched, parsed: parsed, capturedAt: wallNow(),
                             sourceApp: sourceApp, comment: comment)
    return try await publisher.publish(draft, operationID: UUID())
}
```

The actor stores `active = false`, `fetcher`, `parser`, `publisher`, `policy`,
`timing: ExtractionTiming`, and `wallNow: @Sendable () -> Date` injected by
its initializer (defaults `ExtractionTiming()` and `{ Date() }`). `recover()` also claims the active
gate while delegating to the publisher, so recovery and capture cannot overlap.

Keep the actor busy through durable persistence, not just through network fetch.
Test concurrent attempts with a continuation-controlled fake fetcher: wait until
the first call enters, issue the second, assert `.busy`, then release the first.
Do not use sleeps to establish this ordering.

Startup recovery failure disables page capture until addressed; never silently
fall back to an unjournaled writer. Normal URL/note capture remains available.

- [ ] **4. Replace AppDelegate's script/Python lookup and compose native services.**

Remove `findZoneExtractScript()` and `findBundledPython()`. Resolve the helper
using `HelperLocation` and construct the publisher from `Store.shared` and its
captures directory at the composition root only. Perform `recover()` before
enabling page capture.

Replace the page-capture callback's nested global/main dispatches with a
main-actor-owned `Task`. Snapshot the frontmost app synchronously as today;
perform its browser Automation call off-main, then await the native coordinator.
Pass `comment: nil`, preserving unattended capture.

```swift
// UI boundary inside an @MainActor task, after obtaining captured URL.
do {
    _ = try await coordinator.capturePage(
        url: captured.url, sourceApp: front.name, comment: nil)
    panel.showBanner("✓ Page captured")
} catch let failure as ExtractionFailure {
    panel.showBanner(failure.userMessage)
} catch {
    panel.showBanner("✗ Page capture failed")
}
```

Define this property inside `ExtractionFailure`:

```swift
public var userMessage: String {
    switch self {
    case .invalidURL: return "✗ Unsupported page URL"
    case .redirectRejected: return "✗ Page redirect was rejected"
    case .httpFailure: return "✗ Page server returned an error"
    case .transportFailure: return "✗ Page download failed"
    case .unsupportedContent: return "✗ Unsupported page content"
    case .invalidEncoding: return "✗ Page text could not be decoded"
    case .noReadableContent: return "✗ No readable page content"
    case .limitExceeded: return "✗ Page exceeds capture limits"
    case .helperUnavailable: return "✗ Native extractor is unavailable"
    case .helperFailed: return "✗ Native extraction failed"
    case .invalidHelperResult: return "✗ Native extractor returned invalid data"
    case .deadlineExceeded: return "✗ Page capture timed out"
    case .cancelled: return "Page capture cancelled"
    case .artifactIO: return "✗ Capture files could not be written"
    case .persistence: return "✗ Capture could not be saved"
    case .recoveryRequired: return "✗ Capture recovery needs attention"
    case .busy: return "Page capture already in progress"
    }
}
```

Never interpolate response text, URLs, filesystem paths, or arbitrary errors
into these messages.

Keep the capture task handle, cancel it on app termination, and ensure
cancellation reaches URLSession/helper ownership. Do not claim an in-process
task can survive app shutdown; the publication journal covers interrupted writes.
Do not change either registered shortcut or the URL-note panel's save logic.

- [ ] **5. Run green and build both app products.**

Run coordinator tests, the full Swift suite, and explicit builds for
`ZoneCapture`/`ZoneCaptureExtractor`. Existing Python wrapper tests remain until
task 7 removes the now-unused wrapper. Commit:
`refactor: route page capture through native async services`.

## Task 7: Ship the native bundle and retire extraction Python

**Files:** Modify `make-app.sh`, `Package.swift`, `README.md`,
`Tests/TESTS_CONTEXT.md`; create `tools/check-native-bundle.sh`; remove
`Sources/ZoneCaptureCore/PageExtractor.swift`,
`Tests/ZoneCaptureTests/PageExtractorTests.swift`,
`tools/zone_extract.py`, `tools/requirements.txt`,
`tools/tests/test_zone_extract.py` after confirming no remaining consumers.
Preserve `tools/tests/fixtures/example.html` if any legacy tool still uses it.

**Consumes:** Working native app/helper and migrated tests.
**Produces:** A non-launching release build mode, native bundle checks, and a
shipping bundle without any Python extraction resources.

- [ ] **1. Write the bundle check and demonstrate red against the old assembly.**

```bash
#!/bin/bash
set -euo pipefail
BUNDLE="${1:?Usage: check-native-bundle.sh /absolute/ZoneCapture.app}"
case "$BUNDLE" in /*) ;; *) echo "Bundle path must be absolute" >&2; exit 2 ;; esac
test -x "$BUNDLE/Contents/MacOS/ZoneCapture"
test -x "$BUNDLE/Contents/Helpers/ZoneCaptureExtractor"
if /usr/bin/find "$BUNDLE" \( -name '*.py' -o -name '*.pyc' -o -name 'pyvenv.cfg' \
    -o -name 'python*' -o -name 'pip*' -o -name 'ParserFixture' \) -print \
    | /usr/bin/grep . >/dev/null; then
    echo "Forbidden interpreter/test resource in bundle" >&2
    exit 1
fi
/usr/bin/file "$BUNDLE/Contents/Helpers/ZoneCaptureExtractor" | /usr/bin/grep 'Mach-O' >/dev/null
/usr/bin/codesign --verify --strict "$BUNDLE/Contents/Helpers/ZoneCaptureExtractor"
/usr/bin/codesign --verify --deep --strict "$BUNDLE"
echo "PASS native bundle structure and signatures"
```

Run with `/bin/bash` so executable permissions are not an accidental dependency.
The old assembled bundle must fail for a missing helper/Python resources.
If no disposable bundle exists, use a test-owned synthetic bundle to demonstrate
the missing-helper failure; do not assemble/install the old app into `/Applications`.

- [ ] **2. Build/sign the helper before the outer app.**

Add action `assemble` to `make-app.sh`: build and assemble, **no installation and
no launch**. Preserve existing `build` and `install` behavior for explicit users,
but automated checks must use `assemble`. Reject unknown action strings before
any destructive step.

Relevant assembly commands:

```bash
swift build -c release --arch arm64 --product ZoneCapture
swift build -c release --arch arm64 --product ZoneCaptureExtractor
BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
cp "$BIN_PATH/ZoneCaptureExtractor" "$APP_BUNDLE/Contents/Helpers/ZoneCaptureExtractor"
codesign --force --sign - "$APP_BUNDLE/Contents/Helpers/ZoneCaptureExtractor"
codesign --force --sign - --entitlements Resources/ZoneCapture.entitlements "$APP_BUNDLE"
```

These commands belong inside the existing script after its repository-relative
`cd`, not as standalone commands from a different directory. Copy any actual
SwiftPM resource bundles required by compiled targets; do not copy test fixtures.
`assemble` exits before `open` or `/Applications` writes.

Replace broad assembly deletion with a unique task-owned staging directory under
`build/`, then publish the generated bundle only after verifying ownership of the
previous build output. Never clean arbitrary untracked contents. Installation
is a separate explicitly authorized action, not part of these tests.

Remove all venv/script/requirements-copy/pip commands and the old runner source.
Remove Python extraction tests only after their fidelity/error/limit behaviors
have green native equivalents. Keep the optional legacy Python `zonectl` and
its tests documented as outside the shipped app.

- [ ] **3. Run native assembly and checks green.**

```bash
cd /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./make-app.sh assemble && /bin/bash /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture/tools/check-native-bundle.sh /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture/build/ZoneCapture.app
```

Expected: both binaries build/sign and checks pass without launching any GUI app.
Also inspect `otool -L` on both executables for interpreter/source-tree references.
Do not claim a string scan alone proves runtime independence.

- [ ] **4. Update docs and mark old diagrams historical.**

README must distinguish compiled SwiftSoup dependency from "no dependencies",
describe the native helper, build-time package downloads, offline runtime,
20-second deadline, explicit size failures, and the unbundled legacy CLI.
Record measured test commands/results and remove obsolete Python extraction
instructions. Do not remove Python instructions for `zonectl` if they still apply.

Add a short historical note next to the existing Python-era diagram links in
README, identifying commit `9c668cf`. Do not hand-edit generated Archify HTML
to pretend a newly validated diagram exists. Diagram regeneration is a separate
documentation follow-up, not an acceptance claim in this phase.

- [ ] **5. Run full Swift validation and commit.**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture
```

Expected: no test relies on Python for extraction. If legacy CLI tests are run,
report them separately. Commit: `build: ship native extraction without Python`.

## Task 8: Verify the native artifact and record honest delivery evidence

**Files:** Create
`docs/verification/2026-09-16-native-extraction.md`; modify tests only for
regressions found during this gate, following red/green.

**Consumes:** Task 7's generated release bundle.
**Produces:** Evidence distinguishing unit/integration, packaging, native runtime,
and real-hotkey outcomes. This task does not implement the phase-2 GUI supervisor.

- [ ] **1. Run all narrow tests plus the full Swift suite from the final commit.**

Record exact commands, exit codes, test counts, build identity, dirty/clean status,
architecture, and Xcode version. Capture failed and blocked checks as well.
Do not copy pre-migration test counts.

- [ ] **2. Exercise the packaged helper in a minimal environment.**

Use a new owner-only temp root, write the synthetic ParserRequest from task 4,
and invoke the actual bundled helper with absolute paths and an environment
containing only required system defaults. Inspect its JSON response and ensure
the process exits; no Python interpreter or source path may be consulted.

For the full app smoke, run a copied assembled bundle outside the source checkout
in a disposable macOS user/session with no accessible developer Python or repo.
Do not uninstall Python or alter the real user's home to fake isolation.
If no such session is available, record that full isolation check as blocked.
Combine dependency/resource inspection, process observation, and actual capture
results; a minimal PATH test alone is not proof.

- [ ] **3. Obtain consent before the real-hotkey smoke.**

Use an unlocked desktop, synthetic browser page, and disposable data context.
If the everyday app is running, stop and ask rather than quit it automatically.
Do not send keys to unknown/frontmost personal applications. Phase 1 may use a
manual tester in the disposable macOS account; no hidden production data-root
environment override is added just for this test.

Record these separate assertions:

```text
Cmd+Shift+L: panel appears with fixture URL; save synthetic note → one row.
Escape: cancel panel → no extra row.
Cmd+Shift+Option+L: no input panel; native content → Markdown + sidecar + row.
Fixture HTTP failure: safe error; no successful capture row.
Fixture parser stall: bounded failure; menu-bar app remains responsive.
Immediate second page capture: busy feedback; no second helper/duplicate capture.
```

Do not claim GUI behavior passed from successful launch, screenshots alone, or
direct coordinator calls. If permissions/desktop ownership are missing, mark
this gate blocked and report it clearly.

- [ ] **4. Review the implementation, fix regressions, and commit evidence.**

Use the code-review skill before declaring phase 1 ready. Review exact changes,
especially parser limits, cancellation/PID ownership, journal durability,
Store query failure semantics, safe banners, and build cleanup scope.
Reproduce accepted findings, add regressions, fix, and rerun the original checks.

The verification document must contain actual observations, not pre-filled
"PASS" entries. Commit: `docs: record native extraction verification`.
Do not install, push, or begin phase 2 without an explicit execution/delivery choice.

## Commit gate for every task

Stage only the listed task files after inspecting `git status`. Use dedicated
file paths, not `git add .`. Then inspect the full staged diff and run:

```bash
git -C /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture diff --cached --check
git -C /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture status --short
```

Use the exact task message stated above and include this trailer:

```text
Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>
```

Pass multiline messages through a quoted heredoc, not raw newlines in shell
arguments. Never override Git identity or bypass hooks. If a hook changes owned
files, review them and amend once. Missing Git identity is an environment blocker.

## Coverage map and final acceptance

| Approved requirement | Task/evidence |
|---|---|
| Swift-only extraction and explicit dependencies | 1, 4, 7 |
| Readable content, supported formatting, safe links | 2 |
| Charset order, HTTP status, redirects, bounded decoded bytes | 3 |
| Hard parsing deadline, cancellation, no pipe deadlock | 4, 6 |
| Same capture format, timestamps, escaped metadata | 5 |
| No false success, file/DB interruption recovery | 5, 6 |
| One capture at a time; unchanged shortcuts | 6, 8 |
| No bundled Python/PATH/source fallback | 4, 7, 8 |
| Existing captures and optional legacy CLI preserved | 5, 7 |
| Real packaged behavior with honest blocked reporting | 8 |
| Future diagnostics use typed native boundaries | 1, 6; catalog remains phase 2 |

Phase 1 is fully verified only when code, tests, packaging, desktop, and isolation
gates pass. If desktop/isolation checks cannot run, report implementation and
automated checks separately and keep those acceptance gates blocked. No API/S3
or diagnostic-supervisor completion claim follows from this phase.
