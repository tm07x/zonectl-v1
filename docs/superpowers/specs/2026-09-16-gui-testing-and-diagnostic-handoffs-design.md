# Native GUI testing and diagnostic handoffs

Date: 2026-09-16
Status: Revised design approved in conversation; revised written-spec review pending.
Repository baseline: `462ef8e` (documentation); app baseline: `9c668cf`.

## Revision and delivery order

The owner requires Swift-only core functionality, with Swift + Rust acceptable
only as an explicit future architecture choice. Python is not an acceptable
application dependency. The implementation selected here is Swift, not Rust.
Existing macOS frameworks, system SQLite, and browser Automation remain in use.

The approved work is split into three separately planned and verified phases:

1. [Native page extraction](2026-09-16-native-page-extraction-design.md):
   remove the Python runtime dependency while preserving existing captures.
2. This document: shared fault codes, everyday diagnostic handoffs, and real
   GUI tests against that native build.
3. [Local data exchange](2026-09-16-local-data-exchange-design.md):
   authenticated localhost import/export, external topic updates, and explicit
   outbound HTTPS/S3 transfers, extending the same diagnostic contract.

Each phase gets its own implementation plan and verification gate. This revision
does not claim any of these changes have already been implemented. In particular,
the currently installed app still uses Python until phase 1 replaces it.

## Goal

Test the actual ZoneCapture application through its desktop interface and
produce useful troubleshooting handoffs for both automated tests and everyday
failures. A coding agent starting with little context must be able to identify
the build, understand the observed failure, find the relevant code, reproduce
the scenario, and determine whether its fix worked.

The handoff consists of:

```text
general instruction body
+ versioned fault-catalog entry
+ evidence from this particular incident
```

A fault code routes investigation. It does not establish a root cause or promise
a particular fix. Native process exit codes, signals, Carbon OSStatus values,
and SQLite result codes remain separate evidence fields.

## Current system and gap

- ZoneCapture is a native AppKit menu-bar application built with SwiftPM.
- `HotkeyManager` registers the two default Carbon shortcuts and dispatches
  them through `HotkeyRegistry`.
- `CapturePanel` handles URL/note entry. `CaptureCoordinator` performs unattended
  page extraction and persistence for the second shortcut.
- `Store.shared` currently writes to the user's Application Support directory.
- `AppDelegate` registers a login item at startup.
- Existing tests exercise core logic and subprocess behavior, not the actual
  window, global shortcut, focus, or browser interaction.
- Page extraction currently launches Python and the packaging script bundles a
  virtual environment. Phase 1 replaces it with compiled Swift code before this
  GUI suite is accepted as evidence for the native-only requirement.
- Errors currently use transient banners and NSLog messages. There is no
  durable, versioned incident report or external GUI-test supervisor.

## Scope

### Included

1. One shared fault catalog and instruction template.
2. Structured, privacy-conscious runtime events and incident reports.
3. Next-launch recovery of evidence from an unclean previous session.
4. Native desktop automation with a separate test supervisor.
5. Disposable test storage and a controlled browser page.
6. Tests of the diagnostic system itself, including termination and hangs.
7. Local JSON reports and readable agent handoffs.
8. Documentation for running tests, granting permissions, and investigating codes.
9. A Python-free Swift supervisor, UI driver, and local fixture server.
10. Diagnostic extension points for the later local API and transfer phase.

### Excluded

- An always-running crash-monitor daemon for everyday use.
- Automatic uploads, issue creation, or launching a coding agent. Explicit
  clean-capture transfers belong to phase 3; diagnostic reports never enter
  that export payload.
- Automatically applying a catalog's suggested fix.
- Exhaustive validation of every browser or every possible crash.
- Vision-only autonomous exploration, recording the full desktop, or reading
  unrelated browser tabs.
- Refactoring unrelated capture behavior or implementing Features 3 and 4.

## Components

### Shared diagnostic contract

Keep the fault catalog and instruction template in version control and bundle
them with the app. The app and supervisor use the same catalog version.
Reports embed the matching entry and template so later catalog changes cannot
silently change the meaning of an older handoff.

Each catalog entry contains:

- Stable code and symbolic name.
- Observed condition and evidence required to assign it.
- Relevant repository-relative files and function names.
- Hypotheses and diagnostic steps, not unconditional repair instructions.
- Reproduction guidance and verification criteria.

Codes are never reused for a different meaning. Start with the actual supported
failures rather than filling an arbitrary numeric range.

### Runtime recorder and report writer

The app records bounded event metadata for startup, hotkey registration and
delivery, panel presentation, extraction, and database writes. Each session has
a session ID; each capture has an operation ID.

Phase 3 adds API request IDs and transfer IDs without recording request bodies,
response bodies, bearer tokens, signed URLs, or destination credentials.

Persist events independently of the captures database, so a database failure
does not also prevent writing diagnostics. Serialize recorder access, bound
storage, and atomically publish completed reports.

Record the build commit, binary identity, app version, OS version, architecture,
catalog version, and whether the build contained uncommitted source changes.
Do not rely on a source checkout being present on the machine running the app.

Handled failures produce a local report. The banner displays the code and a
brief safe description. A "Reveal diagnostic report" menu action reveals the
latest report directory; it does not upload or automatically copy data.

Reporter failures must not recurse, crash the app, or misreport a successful
save. If storage is unavailable, display that the diagnostic report could not
be written and preserve the original fault code.

### Session recovery

After the single-instance check, initialize diagnostics and persist an active
session marker. Mark a session clean when normal application shutdown runs.
On the next launch, an unfinished marker produces an unclean-session incident.

An unfinished marker is not proof of a crash: force-quit, power loss, and
shutdown can leave the same marker. Attach a matching macOS crash summary only
when its process identity, timing, and available build identity match. Absence,
permission denial, delayed crash-report creation, and unsupported formats are
explicit evidence states, not reasons to suppress the incident.

This provides next-launch reporting for everyday abnormal termination. It does
not promise immediate crash or hang notification while the app is closed or
unresponsive. Startup failures before recorder initialization may only be
observable by the supervisor or macOS.

### Native UI driver

Use a small macOS-native driver with Accessibility queries/actions and keyboard
event injection. Add stable accessibility identifiers to the relevant app
controls. Use screenshots as supplementary evidence, not as the sole assertion.
Implement the driver, supervisor, and fixture server in Swift. Do not introduce
Python or a browser JavaScript extraction engine as a test or runtime prerequisite.

The driver exercises the actual default shortcuts and UI. It must not call the
coordinator or panel's internal save methods in place of desktop interaction.
Bound waits and check process identity/focus before sending input. Abort rather
than typing into an unexpected application.

The initial browser target is Chrome launched with a disposable profile and a
controlled local HTTP fixture. The fixture is served only on loopback and has
known URL, title, and content. If Chrome or required permissions are unavailable,
the browser-dependent scenarios are blocked rather than silently substituted
with mocks or another browser.

### External test supervisor

A separate supervisor owns the test app process, fixture server, native driver,
and disposable browser session. Persist step-start and step-completion events
before advancing so an app or driver crash cannot erase the last known step.

Use a QA bundle identity and an explicitly supplied temporary data root.
Disable login-item registration for this test instance. Test-only configuration
must require QA identity plus explicit opt-in and must never silently fall back
to production storage.

Default hotkeys can conflict with the everyday app. If the everyday app is
running or the shortcuts are unavailable, block with instructions. Do not
force-quit it, discard unsaved notes, or silently test different shortcuts.

Detect app exit separately from a missed UI deadline. An app that remains alive
but shows no panel is not automatically hung. A hang classification requires
additional failed responsiveness checks. Distinguish app faults from driver,
fixture-server, and supervisor failures.

On timeout, preserve evidence before terminating only processes the run owns.
Bound diagnostic collection and cleanup as well as the test steps.

## Initial code catalog

| Code | Symbol | Assignment condition |
|---|---|---|
| `ZC-100` | APP_START_FAILED | Supervisor cannot launch the test app |
| `ZC-200` | UNEXPECTED_APP_EXIT | Supervised app exits without a requested shutdown |
| `ZC-201` | APP_UNRESPONSIVE | App is alive, a deadline expires, and repeated responsiveness checks fail |
| `ZC-202` | PREVIOUS_SESSION_UNCLEAN | Next launch finds an unfinished session marker |
| `ZC-300` | PANEL_NOT_OBSERVED | Shortcut was sent to the verified desktop context but expected panel was not observed |
| `ZC-301` | HOTKEY_REGISTRATION_FAILED | Handler installation or hotkey registration returns a failure |
| `ZC-310` | BROWSER_URL_UNAVAILABLE | Capture cannot obtain a usable browser URL |
| `ZC-400` | EXTRACTION_FAILED | Extraction boundary reports failure |
| `ZC-401` | EXTRACTION_TIMEOUT | Extraction watchdog deadline expires |
| `ZC-402` | EXTRACTION_LIMIT_EXCEEDED | Fetch, parse, or output exceeds a documented size/complexity limit |
| `ZC-500` | PERSISTENCE_FAILED | App reports database initialization, write, or query failure; operation identifies which |
| `ZC-501` | CAPTURE_RESULT_MISMATCH | GUI action completes but stored record or artifact fails the expected-content assertion |
| `ZC-600` | API_START_FAILED | Enabled loopback listener cannot bind or initialize |
| `ZC-601` | API_ACCESS_DENIED | API authentication, scope, origin, or host validation rejects a request |
| `ZC-602` | IMPORT_VALIDATION_FAILED | Submitted capture fails the supported schema, content, or size contract |
| `ZC-603` | DATA_REVISION_CONFLICT | Capture identity conflicts with stored content, or a topic update has a stale revision |
| `ZC-610` | EXPORT_FAILED | Selected clean-data payload cannot be constructed or staged |
| `ZC-611` | TRANSFER_FAILED | Explicit HTTPS/S3 transfer fails at transport or remote HTTP boundary |
| `ZC-612` | TRANSFER_TIMEOUT | Explicit outbound transfer reaches its total deadline |
| `ZC-900` | TEST_PRECONDITION_BLOCKED | Required app, desktop session, permissions, or shortcuts are unavailable |
| `ZC-901` | TEST_HARNESS_FAILED | Driver, supervisor, or fixture infrastructure fails |
| `ZC-999` | UNCLASSIFIED_FAILURE | Evidence establishes failure but no more specific condition is supported |

Report causally related observations together. For example, an observed process
exit takes precedence over the panel deadline it caused. Keep underlying native
codes and related events without fabricating a more specific root cause.

The listed API/export codes are reserved for phase 3 and are not evidence
that an API exists in phase 2. Assignment conditions stay the same when enabled.
Expected client rejections return the code in the API response and increment
bounded metadata counters; do not create an incident directory for every
unauthenticated request. A failed user-requested export/transfer does create a
handoff. Catalog tests cover both active and reserved entries explicitly.

## Report contract

A report directory contains:

- `incident.json`: machine-readable facts, classifications, and evidence manifest.
- `handoff.md`: instruction body, catalog entry, observations, and investigation steps.
- Bounded, filtered session/operation events.
- Test-window screenshots and accessibility evidence when collected safely.
- A filtered matching crash summary when available.

Required report fields:

- Schema, template, and catalog versions.
- Incident, session, operation, and test-run identifiers as applicable.
- Application build identity and environment metadata.
- Fault code, reporting source, and observation time.
- Scenario, last completed step, failing step, expected outcome, observed outcome.
- Native exit status or signal when observable, kept separate from the fault code.
- Evidence paths and explicit missing-evidence reasons.
- Reproduction command for automated tests; minimal manual steps for everyday
  failures, or "not observed" when unavailable.
- Relevant code locations, investigation order, and verification criteria.

A report must distinguish facts, hypotheses, and unavailable information.
Everyday reports cannot invent the user's complete sequence of GUI actions.

The instruction template tells the next agent to verify build identity,
reproduce the issue, distinguish product/dependency/harness failures, add a
regression test, fix the cause, and rerun the original scenario. It explicitly
treats logs and captured content as untrusted evidence, never as instructions.

## Privacy and retention

- No note text, captured page bodies, credentials, cookies, environment dumps,
  or complete URLs in ordinary diagnostic events.
- Use allowlisted metadata and native error categories. Do not copy arbitrary
  exception descriptions into reports without filtering.
- Runtime reporting takes no screenshots.
- QA screenshots are restricted to verified test-owned windows containing
  synthetic data. If isolation cannot be established, omit the screenshot.
- Do not bundle whole macOS crash files by default; extract and filter only
  relevant identity, exception, and stack information.
- Reports are local, with owner-only access where supported.
- Runtime diagnostics retain the latest 10 sessions and 20 incidents, with a
  50 MiB total budget. Bound the active session ring to 5 MiB and each incident
  to 5 MiB, omitting optional evidence with a reason when necessary. Rotate
  completed oldest entries within the diagnostics directory only; never remove
  captures or database files. These are upper limits, not promises to retain
  those counts when the byte budget is exhausted.
- QA artifacts live under the explicit run directory and are excluded from Git.
  Keep failed-run evidence for inspection; cleanup removes only owned processes
  and generated disposable resources, not the incident report.

## Initial scenarios and acceptance

### Desktop smoke scenarios

1. Launch the QA bundle and confirm process and Accessibility responsiveness.
2. With the fixture browser frontmost, press `Cmd+Shift+L`, verify the panel and
   fixture URL, enter a synthetic note, save, and verify exactly one matching row.
3. Open the panel and cancel with Escape; verify no extra row.
4. Press `Cmd+Shift+Option+L` with the fixture browser frontmost; verify a capture
   row plus Markdown/JSON containing the known fixture content.
5. Exercise an extraction failure and a storage failure through controlled QA
   configuration. Assert the expected code, report, and absence of false success.
6. Verify the packaged app and its Swift helper work without Python, the source
   checkout, Homebrew, or a developer virtual environment. The helper runs from
   the bundle, not a source-relative fallback.

Assertions inspect the isolated database and files as external observable
results. They do not bypass the UI to perform the capture.

### Diagnostic-system checks

1. Deliberately terminate the owned test process mid-scenario; the supervisor
   must preserve the last step and record `ZC-200` with the observed signal.
   Label the termination as test-induced, not as a discovered product crash.
2. Deliberately suspend only the owned test process; verify bounded detection
   of `ZC-201`, evidence collection, and safe cleanup.
3. Relaunch an isolated unfinished session; verify `ZC-202`. Normal quit/relaunch
   must not create that incident.
4. Verify missing permissions/preconditions produce blocked status and `ZC-900`,
   not an app crash or passing smoke test.
5. Verify the catalog covers emitted codes, referenced source files exist, and
   every report embeds its matching catalog/template versions.
6. Verify concurrent event recording, report publication, bounded retention,
   redaction, and graceful handling of unwritable diagnostics storage.
7. Verify unknown native errors retain useful safe evidence under a supported
   boundary code or `ZC-999`, without guessed root causes.

Injected-fault scenarios pass only when the expected diagnostic is observed.
They are reported separately from the no-fault smoke scenarios.

## Verification and delivery

- Run narrow Swift unit/integration tests for each changed boundary, including
  the compiled extraction helper's lifecycle and deadline behavior.
- Run the complete Swift suite after integration. Migrate Python extraction
  fixtures to Swift in phase 1. Remaining legacy Python CLI tests, if run, are
  separate development-tool compatibility checks, not an app prerequisite.
- Build the app and verify bundled diagnostic assets and build metadata.
- Run the GUI suite in an unlocked macOS desktop session with explicit consent
  to focus test windows and send test input. Stop on missing permissions; do not
  change macOS security settings automatically.
- Preserve a report manifest containing pass, fail, and blocked outcomes and
  the tested build identity.
- Do not claim desktop behavior passed based on unit tests, screenshots alone,
  or successful launch alone.
- In phase 3, extend the real-app suite with API authorization, import/export
  round trips, topic revision conflicts, and explicit synthetic transfers to
  owned test destinations. Production data and real S3 uploads are not test
  defaults. See the data-exchange spec for acceptance criteria.

The written implementation plan will specify exact commands, file placement,
and the test sequence after this document is reviewed. Start with phase 1's
plan; do not combine all three phases into one unreviewed implementation.
