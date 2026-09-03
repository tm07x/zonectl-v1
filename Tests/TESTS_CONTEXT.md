# ZoneCapture Tests — Context for Review Agent

## What was tested

### Store (15 tests — `StoreTests.swift`)
SQLite wrapper tested via a temp-directory initializer so each test gets an
isolated, throwaway database. No test touches `Store.shared`'s production DB
(except a read-only sanity check on the singleton).

- **Schema creation**: DB file exists on disk after init; `links` table is
  queryable (empty `recent()` returns `[]`, not a crash).
- **Captures directory**: sibling `captures/` dir is created.
- **insertLink**: returns a positive row id; sequential inserts produce
  monotonically increasing ids.
- **recent**: returns rows newest-first (verified by id and timestamp
  ordering); fields (url, comment) match what was inserted; nil comment
  round-trips as nil; empty-string comment round-trips as nil-or-empty.
- **recent(limit:)**: respects the limit (3 of 10 rows returned, and they are
  the 3 newest); default limit returns all rows.
- **kind default**: insert without specifying `kind` succeeds; insert with
  `kind: "note"` also succeeds.
- **pathForCapture / databasePath / capturesDirectory**: return correct paths
  under the custom root.
- **Isolation**: two Stores with different roots don't see each other's rows.

### URLFetcher (16 tests — `URLFetcherTests.swift`)
Pure logic only — script selection and output parsing.

- **parse()**: url-only (title nil), url+title, empty input, whitespace
  trimming, newline-only edge case.
- **scriptForApp()**: returns non-nil for Safari, Chrome, Edge, Brave, Arc;
  returns nil for Firefox and unknown apps (Xcode, Finder). Case-insensitive
  name matching. BundleId fallback matching. All supported scripts reference
  `theURL`, `theTitle`, and `linefeed` (the output format `parse()` expects).

## What was intentionally NOT tested

- **`URLFetcher.captureFrontmost()`**: executes AppleScript via
  `NSAppleScript.executeAndReturnError` against whichever browser is
  frontmost. Requires a running browser, TCC automation permission, and a
  deterministic frontmost app — impossible in a headless unit test. The pure
  logic it depends on (`scriptForApp` + `parse`) is fully covered.
- **`HotkeyManager`**: uses Carbon `RegisterEventHotKey` for system-wide
  shortcuts. Requires a running event loop and modifies global system state
  (installed hotkey handler). Not unit-testable without side effects.
- **`CapturePanel`**: NSPanel-based GUI with focus management, mouse
  positioning, and field editing. Requires a window server and human
  interaction. Not unit-testable.
- **`AppDelegate`**: wires up NSStatusBar, NSMenu, and the hotkey. Tightly
  coupled to AppKit application lifecycle. Not unit-testable.

## Refactor made to enable testing

**Library split**: extracted `Store.swift` and `URLFetcher.swift` from the
executable target into a new library target `ZoneCaptureCore`
(`Sources/ZoneCaptureCore/`). The executable target `ZoneCapture` now
`import ZoneCaptureCore` and retains `main.swift`, `AppDelegate.swift`,
`HotkeyManager.swift`, `CapturePanel.swift`.

**Package.swift target layout** (3 targets):
1. `.target(name: "ZoneCaptureCore", ...)` — library; links sqlite3.
2. `.executableTarget(name: "ZoneCapture", dependencies: ["ZoneCaptureCore"], ...)` — app; links sqlite3.
3. `.testTarget(name: "ZoneCaptureTests", dependencies: ["ZoneCaptureCore"], ...)` — tests.

**Access-level changes in ZoneCaptureCore**:
- `Store` class, `URLFetcher` enum, `URLFetcher.Result` struct: `public`.
- Public API members (`shared`, `insertLink`, `recent`, `pathForCapture`,
  `databasePath`, `capturesDirectory`, `captureFrontmost`, `Result` fields):
  `public`.
- `Store.init(rootDirectory:)`: `internal` — testable via `@testable import`
  but not part of the public API. Lets tests point Store at a temp dir.
- `URLFetcher.scriptForApp` and `URLFetcher.parse`: changed from `private` to
  `internal` — testable via `@testable import`, not exposed publicly.
- `Store.init()` (production): changed to `private convenience init` that
  delegates to `init(rootDirectory:)`.

**No behavioral changes**: `Store.shared` still uses the same Application
Support path. `make-app.sh` still copies the `ZoneCapture` executable binary
(unchanged name). `./make-app.sh build` verified working.

## How to run the tests

```bash
cd /Users/tm07x/GROKKED-INK/VM-APPS/zonecapture

# XCTest requires full Xcode (not just Command Line Tools) on this machine:
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test

# Build only:
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build

# App bundle build:
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./make-app.sh build
```

## Results

31 tests, 0 failures (15 Store + 16 URLFetcher).
