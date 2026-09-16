# Native page extraction, without Python

Date: 2026-09-16
Status: Design approved in conversation; written-spec review pending.
Repository baseline: `462ef8e` (documentation); app baseline: `9c668cf`.

## Goal and hard constraint

ZoneCapture must capture browser URLs and page content using compiled Swift
code and macOS system frameworks. It must not require Python, a virtual
environment, pip, Homebrew, a source checkout, or a cloud extraction service
for core functionality.

The owner permits Swift + Rust, but this design chooses Swift throughout.
Adding Rust later requires a justified, reviewed design change. This is not
a promise to eliminate macOS's system SQLite or browser Automation APIs.

This is phase 1 of the
[GUI testing and diagnostic handoff revision](2026-09-16-gui-testing-and-diagnostic-handoffs-design.md).
It precedes that suite and the
[local data-exchange phase](2026-09-16-local-data-exchange-design.md).
No implementation is asserted by this design document.

## Current implementation to replace

- `Sources/ZoneCaptureCore/PageExtractor.swift` invokes `PythonExtractionRunner`.
- `tools/zone_extract.py` fetches HTML, uses readability/markdownify, and writes
  Markdown plus a JSON sidecar.
- `Sources/ZoneCapture/AppDelegate.swift` locates the script and bundled Python.
- `make-app.sh` copies the script and installs a Python virtual environment.
- `CaptureCoordinator` records the resulting file path in `Store`.

Keep the user-facing shortcuts and unattended page-capture flow. Preserve
existing database IDs, capture files, frontmatter, and sidecars. Never rewrite
old captures merely to migrate the extractor.

## Architecture

Separate four responsibilities behind testable Swift boundaries:

1. **Page fetcher:** Foundation `URLSession` performs bounded HTTP(S) requests
   and returns bytes, encoding/content-type information, and the final URL.
2. **Content extractor:** a Swift HTML parser, selected here as SwiftSoup,
   identifies main content and converts it to a typed, restricted document.
   Pin the dependency and record its license during implementation.
3. **Markdown renderer:** Swift converts that document to Markdown and metadata
   without passing arbitrary HTML through to the output.
4. **Capture writer/coordinator:** publishes owned artifacts and records their
   paths through the existing serialized store.

Fetching and file work stay off the AppKit main thread. UI updates return to
the main thread. Use async Swift interfaces instead of retaining a blocking
Python-shaped runner contract solely for compatibility.

### Native parsing isolation and deadline

Use a bundled, compiled Swift helper for HTML parsing/rendering. It shares the
pure extraction module with unit tests. This is a native executable, not an
interpreter or script fallback.

This boundary is deliberate: cancellation cannot forcibly stop a third-party
synchronous parser running inside the menu-bar process. A helper lets the app
enforce a hard deadline without killing itself.

The app owns one parsing helper at a time. Give it an owner-only per-operation
directory containing bounded input and output files. Pass paths as individual
arguments, never through a shell. Resolve the helper relative to the installed
bundle; do not search PATH or the source tree.

Use files for the result protocol and discard ordinary helper stdout/stderr,
so neither can fill an unread pipe. Validate helper exit status, result schema,
output size, and output locations before accepting success. A malformed result
is an extraction failure, not a successful empty capture.

The extraction deadline is 20 seconds across fetch, redirects, and parsing.
On expiry or cancellation, cancel the network task, request helper termination,
then force-terminate the owned helper after at most one additional second.
Clean up only its owned temporary files. The helper must launch no descendants.
Persistence has its own bounded error handling; it is not hidden inside a
network-only timeout. Reject additional page captures as busy rather than
creating an unbounded queue while one extraction is running.

## Fetch and content contract

- Accept HTTP(S) page URLs only. Never interpret a URL as a local file or command.
- Use an ephemeral session without importing browser cookies or credentials.
- Limit redirects to five; reject HTTPS-to-HTTP downgrades and non-HTTP(S)
  redirect targets. Ordinary explicitly requested HTTP pages remain supported.
- Enforce a 10 MiB limit on the decoded HTTP body during receipt, regardless
  of a missing or inaccurate Content-Length. Exceeding it fails explicitly;
  do not silently truncate and report a complete capture.
- Accept HTML/XHTML and plain text; reject unsupported content types and invalid
  encodings with a typed error. Decode using BOM, then HTTP charset, then an
  HTML meta charset within the first 1,024 bytes, then UTF-8, in that order.
  Unsupported labels or invalid byte sequences fail explicitly. Apply the
  10 MiB limit to the resulting UTF-8 text too, before passing it to the helper.
- Prefer semantic article/main content, falling back to scored text blocks.
  Exclude navigation, script, style, form, and obvious non-content elements.
- Preserve headings, paragraphs, lists, emphasis, code, quotes, tables, and
  useful HTTP(S) links. Resolve relative links against the final page URL.
- Remove active HTML and unsafe URL schemes. Do not fetch images, execute page
  scripts, or render Markdown as trusted HTML.
- Bound traversal to 200,000 DOM nodes and depth 256, and emitted Markdown to
  10 MiB. The hard helper deadline also applies while the parser builds its tree.
- Bound title and URL fields to 8 KiB each and helper JSON output to 64 MiB
  including escaping. Oversized metadata/output is an explicit limit failure.
- Empty/non-readable content is a typed extraction failure, not a success banner.

Extraction aims to preserve useful content, not byte-identical Python output.
Fixture assertions define fidelity. Sites requiring a logged-in browser session,
client-side rendering, or paywall bypass are not added to this phase.

## Artifacts and persistence

Continue producing UTF-8 `.md` and `.json` files. Preserve the existing
frontmatter/sidecar fields: title, URL, site, captured_at, word_count, and the
sidecar's Markdown body. Add extractor identity/version as additive metadata.
Keep the requested source URL; record the final URL separately after redirects.
Reject credential-bearing URL user-info before fetching or persisting a source.

Use UTC RFC 3339 capture timestamps. Count words by whitespace-separated tokens,
matching the current convention; this is not a language-aware linguistic count.
Escape metadata scalars and do not derive writable paths from untrusted titles.
Generate collision-resistant file names under the configured captures directory.

Use staging files on the same filesystem, publish both artifacts, then insert
the capture row. Report success only after the store acknowledges persistence.
On a known pre-commit failure, remove only files created by that operation.

SQLite and the filesystem do not share an atomic transaction. Maintain a small,
owner-only operation journal so an interrupted publication can be reconciled on
restart. Reconciliation checks whether the database references an artifact
before cleaning it. If commit outcome or ownership is uncertain, retain it and
report the condition; never delete a possibly committed capture. Existing,
unjournaled user captures are never cleanup candidates.

## Failure contract

Use typed failures for invalid URL, HTTP/transport failure, unsupported content,
encoding failure, no readable content, size/complexity limit, helper startup or
protocol failure, deadline, artifact I/O, and database persistence.

Return safe user-facing summaries, with no arbitrary response body or signed
URL in banners/logs. Failed extraction must leave the app responsive and must
not produce a false success banner. File and database errors remain distinct.

Phase 2 maps these boundaries to `ZC-400`, `ZC-401`, `ZC-402`, and `ZC-500`.
Do not copy the catalog or create a competing diagnostic-code namespace in
phase 1.

## Packaging and migration

- Build and sign the Swift app and helper with SwiftPM and macOS tools.
  Sign embedded code before the outer app bundle.
- Remove Python helper/interpreter lookup and the extraction subprocess wrapper
  from the app. Remove venv creation, pip installation, and Python resource
  copying from `make-app.sh`.
- Remove the obsolete extraction script/dependencies/tests from the active
  extraction path after migrating useful fixtures to Swift. Git history retains
  the old implementation; production has no hidden Python fallback.
- The repository's optional Python `tools/zonectl` is a legacy developer tool,
  not bundled app functionality. It may remain separately documented and tested.
  Reading/exporting through the new API must not require it. A Swift CLI rewrite
  is outside this phase.
- Update README packaging/dependency claims and test documentation to match
  reality. Mark existing Python-era diagrams as historical or update them during
  implementation; do not present them as the native architecture.

SwiftSoup is a compiled Swift package dependency. "No Python" must not be
misrepresented as "no dependencies." Building may require downloading pinned
Swift packages; running the installed app does not.

## Verification and acceptance

1. Move extraction fixtures into Swift tests: main-content selection, titles,
   relative links, Unicode/charset handling, lists, code, tables, malformed HTML,
   boilerplate removal, empty pages, and escaped frontmatter.
2. Test HTTP status errors, redirect limits/downgrades, slow/stalled responses,
   decoded-body limits, unsupported types, and cancellation using owned fixtures.
3. Exercise the real helper protocol: success, malformed output, unexpected
   exit, output limits, intentional stall, forced termination, and cleanup.
   Label injected faults as tests, not discovered product crashes.
4. Verify existing capture files and database rows remain readable. Inject
   artifact/DB failures and interruption at each journal boundary; verify no
   false success, destructive recovery, or duplicate row.
5. Run the full Swift suite and build the release bundle. Inspect packaged
   resources, dependencies, helper signing, and app launch paths.
6. Run installed-bundle capture with a minimal environment and no accessible
   developer checkout or Python helpers. Do not uninstall the user's Python.
   Combine bundle inspection and process observation with this smoke test;
   a restricted PATH alone is not proof of zero Python dependency.
7. Exercise the real hotkeys against a synthetic browser fixture. Until phase 2
   automates this, record manual outcomes separately from unit-test results.

A passing native phase means capture works without Python and preserves data.
It does not mean the later GUI supervisor or API has been implemented.
