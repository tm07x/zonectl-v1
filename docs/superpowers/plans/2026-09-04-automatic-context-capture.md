# Automatic Context Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend ZoneCapture so the existing ⌘⇧L capture remains instant while an on-by-default background sampler records meaningful active-app and browser context locally.

**Architecture:** Keep the current menu-bar executable and `ZoneCaptureCore` library. Add a pure sampling policy that decides when context changed, platform adapters that read the active app/browser/window and capture a frontmost-window image, and a serial background coordinator that persists snapshots asynchronously. User-triggered links remain in `links`; automatic observations go into a separate `context_snapshots` table so existing recent-capture behavior is unchanged.

**Tech Stack:** Swift 5.9+, AppKit, NSWorkspace notifications, AppleScript/Accessibility adapters already used by ZoneCapture, system screenshot APIs or `screencapture`, SQLite via the existing C wrapper, XCTest.

## Global Constraints

- Preserve ⌘⇧L as the primary user-triggered capture shortcut.
- Do not record raw keystrokes.
- Automatic work must never block the capture panel or database write path.
- Keep all automatic context local under the existing ZoneCapture Application Support directory.
- Do not bypass browser authentication, paywalls, or macOS permission boundaries.
- Keep existing SwiftPM targets and system-library-only dependency policy.
- Continue using isolated temporary stores for tests.

---

## File Map

**Create**

- `Sources/ZoneCaptureCore/ContextSnapshot.swift` — value types and sampling identity used by core logic.
- `Sources/ZoneCaptureCore/SamplingPolicy.swift` — pure event/heartbeat/deduplication decisions.
- `Sources/ZoneCapture/ContextProvider.swift` — AppKit-facing active-app/window and browser-context adapter.
- `Sources/ZoneCapture/ContextMonitor.swift` — lifecycle, notification, timer, and asynchronous persistence coordinator.
- `Tests/ZoneCaptureTests/SamplingPolicyTests.swift` — deterministic policy tests.
- `Tests/ZoneCaptureTests/ContextStoreTests.swift` — isolated SQLite snapshot persistence tests.

**Modify**

- `Sources/ZoneCaptureCore/Store.swift` — migrate `context_snapshots` and expose insert/query methods.
- `Sources/ZoneCapture/AppDelegate.swift` — start/stop the monitor and expose a pause/resume menu action.
- `README.md` — document automatic context behavior, permissions, pause behavior, and local storage.
- `Tests/ZoneCaptureTests/StoreTests.swift` — verify the new schema does not alter existing link behavior.

---

### Task 1: Add the automatic snapshot data model and SQLite storage

**Files:**

- Create: `Sources/ZoneCaptureCore/ContextSnapshot.swift`
- Modify: `Sources/ZoneCaptureCore/Store.swift`
- Create: `Tests/ZoneCaptureTests/ContextStoreTests.swift`
- Modify: `Tests/ZoneCaptureTests/StoreTests.swift`

**Interfaces:**

- `ContextSnapshotIdentity(appBundleID: String?, appName: String, windowTitle: String?, url: String?, browserTabCount: Int?)`
- `ContextSnapshotRecord(identity: ContextSnapshotIdentity, screenshotPath: String?, extractedTextPath: String?, observedAt: Date)`
- `Store.insertContextSnapshot(_ snapshot: ContextSnapshotRecord) -> Int64`
- `Store.recentContextSnapshots(limit: Int = 25) -> [ContextSnapshotRecord]`

- [ ] **Step 1: Write failing store tests**

Add tests that initialize `Store(rootDirectory:)`, assert the `context_snapshots` table is created, insert a record, and verify all fields round-trip. Also assert an existing `links` insert and `recent()` result remain unchanged.

```swift
func testContextSnapshotRoundTrips() {
    let (store, _) = makeTempStore()
    let snapshot = ContextSnapshotRecord(
        identity: ContextSnapshotIdentity(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Example",
            url: "https://example.com",
            browserTabCount: 3),
        screenshotPath: "/tmp/example.png",
        extractedTextPath: nil,
        observedAt: Date(timeIntervalSince1970: 1234))

    let id = store.insertContextSnapshot(snapshot)
    XCTAssertGreaterThan(id, 0)

    let rows = store.recentContextSnapshots(limit: 1)
    XCTAssertEqual(rows.first?.identity.appName, "Safari")
    XCTAssertEqual(rows.first?.identity.url, "https://example.com")
    XCTAssertEqual(rows.first?.identity.browserTabCount, 3)
    XCTAssertEqual(rows.first?.screenshotPath, "/tmp/example.png")
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter ContextStoreTests
```

Expected: compile failure because the snapshot types and Store methods do not exist.

- [ ] **Step 3: Add public core value types**

Define immutable `public struct` types in `ContextSnapshot.swift`. Use optional values for fields that require permissions or are unavailable for the current app. Normalize empty strings to `nil` in the initializer.

- [ ] **Step 4: Add the SQLite table and methods**

Add this migration to `createSchema()`:

```sql
CREATE TABLE IF NOT EXISTS context_snapshots (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    app_bundle_id     TEXT,
    app_name          TEXT NOT NULL,
    window_title      TEXT,
    url               TEXT,
    browser_tab_count INTEGER,
    screenshot_path   TEXT,
    extracted_text_path TEXT,
    observed_at       REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_context_observed
    ON context_snapshots(observed_at DESC);
```

Use prepared statements and the existing `StoreError` reporting path. `recentContextSnapshots` returns newest-first rows and reports query failures without throwing, matching `recent()`.

- [ ] **Step 5: Run focused and full tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter ContextStoreTests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

Expected: all snapshot tests and the existing test suite pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZoneCaptureCore/ContextSnapshot.swift Sources/ZoneCaptureCore/Store.swift Tests/ZoneCaptureTests/ContextStoreTests.swift Tests/ZoneCaptureTests/StoreTests.swift
git commit -m "feat: persist automatic context snapshots"
```

---

### Task 2: Implement deterministic sampling and deduplication policy

**Files:**

- Create: `Sources/ZoneCaptureCore/SamplingPolicy.swift`
- Create: `Tests/ZoneCaptureTests/SamplingPolicyTests.swift`

**Interfaces:**

- `SamplingPolicy.Configuration(heartbeat: TimeInterval = 60, minimumChangeInterval: TimeInterval = 2)`
- `SamplingPolicy.Decision`: `.capture`, `.skipDuplicate`, `.skipTooSoon`
- `SamplingPolicy.decision(for identity: ContextSnapshotIdentity, now: Date) -> Decision`
- `SamplingPolicy.reset()`

- [ ] **Step 1: Write failing policy tests**

Cover:

```swift
func testFirstObservationCaptures()
func testIdenticalObservationWithinHeartbeatSkips()
func testChangedURLCapturesImmediately()
func testChangedWindowCapturesImmediately()
func testHeartbeatCapturesUnchangedContextAfterSixtySeconds()
func testRapidDuplicateIsSuppressed()
```

Use fixed `Date(timeIntervalSince1970:)` values. Do not sleep in these tests.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter SamplingPolicyTests
```

Expected: compile failure because `SamplingPolicy` does not exist.

- [ ] **Step 3: Implement the minimal state machine**

The policy stores the last identity and observation time. A first observation captures. A changed identity captures unless it arrives inside `minimumChangeInterval`. An unchanged identity captures only after `heartbeat`. All other observations skip.

- [ ] **Step 4: Run focused and full tests**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter SamplingPolicyTests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ZoneCaptureCore/SamplingPolicy.swift Tests/ZoneCaptureTests/SamplingPolicyTests.swift
git commit -m "feat: add automatic context sampling policy"
```

---

### Task 3: Add the macOS context provider

**Files:**

- Create: `Sources/ZoneCapture/ContextProvider.swift`

**Interfaces:**

- `ContextProvider.captureCurrent() -> ContextSnapshotRecord`
- `ContextProvider.requestRequiredPermissions()`
- `ContextProvider.isBrowser(bundleID: String?, appName: String) -> Bool`

**Implementation requirements:**

- [ ] **Step 1: Implement active-app and window metadata**

Read `NSWorkspace.shared.frontmostApplication`, its localized name, bundle identifier, and the frontmost window title using the Accessibility API when available. If Accessibility permission is absent, return the app metadata and a `nil` window title rather than failing.

- [ ] **Step 2: Reuse browser URL logic**

Refactor the existing `URLFetcher` entry point only as needed so the provider can request the current URL/title without stealing focus. Preserve current browser matching and Firefox fallback behavior.

- [ ] **Step 3: Add screenshot capture**

Capture only the frontmost window when Screen Recording permission is available. Write a timestamped PNG below `Store.shared.capturesDirectory` and return its path. If the window cannot be identified or permission is absent, persist metadata with a `nil` screenshot path.

- [ ] **Step 4: Add browser tab count where available**

Use the existing browser AppleScript boundary for supported browsers. Failure to enumerate tabs must not prevent recording the active URL and app metadata.

- [ ] **Step 5: Build the app**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build -c release
```

Expected: the executable target compiles without changing the existing hotkey or panel behavior.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZoneCapture/ContextProvider.swift Sources/ZoneCaptureCore/URLFetcher.swift
git commit -m "feat: collect frontmost app context"
```

---

### Task 4: Add the background context monitor

**Files:**

- Create: `Sources/ZoneCapture/ContextMonitor.swift`
- Modify: `Sources/ZoneCapture/AppDelegate.swift`

**Interfaces:**

- `ContextMonitor.start()`
- `ContextMonitor.pause()`
- `ContextMonitor.resume()`
- `ContextMonitor.isPaused: Bool`
- `ContextMonitor.stop()`

- [ ] **Step 1: Implement lifecycle and scheduling**

Create a monitor owned strongly by `AppDelegate`. Register for `NSWorkspace.didActivateApplicationNotification`, schedule a 60-second timer on the main run loop, and funnel both triggers into one sampling method.

- [ ] **Step 2: Keep provider work off the main thread**

The sampling method must dispatch `ContextProvider.captureCurrent()` to a serial background queue, run `SamplingPolicy`, and call `Store.insertContextSnapshot` there. UI changes must be dispatched back to the main queue.

- [ ] **Step 3: Start it after existing app initialization**

In `applicationDidFinishLaunching`, start the monitor after Store error handling, login-item registration, and hotkey registration. Do not alter the existing `showPanel()` path.

- [ ] **Step 4: Add pause/resume menu action**

Add a menu item titled `Pause automatic context capture` that toggles to `Resume automatic context capture`. Pausing must stop both notification-triggered and heartbeat-triggered snapshots without affecting ⌘⇧L.

- [ ] **Step 5: Build and run existing tests**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./make-app.sh build
```

Expected: tests pass and the app bundle is assembled successfully.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZoneCapture/ContextMonitor.swift Sources/ZoneCapture/AppDelegate.swift
git commit -m "feat: run automatic context monitor"
```

---

### Task 5: Document behavior and perform manual validation

**Files:**

- Modify: `README.md`
- Modify: `VISION.md`

- [ ] **Step 1: Document the automatic mode**

Describe event-driven capture, the 60-second heartbeat, local storage, permissions, pause/resume, and the fact that raw keystrokes are never recorded.

- [ ] **Step 2: Document the first extraction boundary**

State that this slice records active app/window/browser context and frontmost-window screenshots where permissions allow. Visible page-text and structured table extraction remain the next worker stage.

- [ ] **Step 3: Run final verification**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build -c release
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./make-app.sh build
git status --short
```

Expected: all tests pass, release build succeeds, app bundle is created, and only intended source/documentation changes remain.

- [ ] **Step 4: Commit**

```bash
git add README.md VISION.md
git commit -m "docs: describe automatic context capture"
```

## Self-Review Checklist

- ☐ ⌘⇧L remains unchanged and still writes to `links`.
- ☐ Automatic snapshots use a separate table and cannot pollute recent user captures.
- ☐ The sampler never records keystrokes.
- ☐ Missing Accessibility, Automation, or Screen Recording permission degrades to available metadata.
- ☐ Sampling decisions are deterministic and independently tested.
- ☐ Background provider work never blocks the main AppKit event loop.
- ☐ Page-text and structured Lovdata extraction are explicitly deferred to the next slice rather than hidden in this foundation plan.
