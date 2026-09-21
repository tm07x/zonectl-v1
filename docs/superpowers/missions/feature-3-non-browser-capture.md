# Mission: Feature 3 — Non-browser app capture

## Goal

When the frontmost app is **not** a browser, capture its identity, a focused-window screenshot, and a user comment. Run the screenshot through a vision model to extract text / context, then store it in the same SQLite DB as `kind='capture'` with a pointer to the screenshot file and generated notes.

## Why now

Feature 2 (page-content extraction) is complete and the app is healthy:
- 47 Swift tests, 7 Python tests, all green.
- Core and app wiring support `kind='capture'` + `capture_path`.
- Keychain-backed `SecretStore` is in place for API keys.
- Architecture diagram exists at `docs/zonecapture-architecture.html`.

The natural next capability is capturing things that live outside the browser: terminal output, design tools, PDFs, chat windows, etc.

## Scope

### In scope
- Detect non-browser frontmost app (reusing `URLFetcher.detectFrontmost()`).
- Capture a screenshot of the focused window using `screencapture -l <windowID>` or `CGWindowListCopyWindowInfo`.
- Minimal floating panel for a comment (no URL field, just context + note).
- Vision-model call (configurable provider; first pass via an HTTP API key stored in Keychain) to extract visible text / summarize context.
- Store row with `kind='capture'`, `source_app`, screenshot file path, and the vision output as `comment` / a sidecar.
- `zonectl list` / `open <id>` already handle `capture_path`; extend if needed.
- Tests for the screenshot + vision seams with fakes; manual GUI verification for the hotkey.

### Out of scope
- Screen recording / video capture.
- Complex multi-window selection.
- Real-time AI chat / routing DSL (that's Feature 4).

## Success criteria

1. Pressing ⌘⇧⌥L (or a dedicated non-browser hotkey) when a non-browser app is frontmost brings up a comment panel.
2. The panel shows the app name and a preview/thumbnail path.
3. After typing a note and pressing Return, a screenshot + sidecar are written to `captures/` and a DB row is inserted.
4. `zonectl open <id>` opens the screenshot for capture rows.
5. All new logic is covered by tests; no regressions in existing 54 tests.
6. README updated with Feature 3 usage.

## Seams to test (TDD)

- `WindowCapture` protocol + `ScreenCaptureWindowCapture` (screenshot file production).
- `VisionClient` protocol + a concrete HTTP client that takes an image and returns text.
- `NonBrowserCaptureCoordinator` that coordinates screenshot → vision → `Store.insertLink`.
- `AppDelegate` routing: browser → page capture, non-browser → non-browser capture.

## Proposed hotkey

Reuse **⌘⇧⌥L** with context-aware routing:
- If frontmost app is a browser → Feature 2 page-content capture.
- If frontmost app is anything else → Feature 3 screenshot + vision capture.

This keeps the cognitive load low: one "deep capture" shortcut regardless of app.

## Risks / open questions

- Screenshot APIs require screen-recording permission; need `SCContentSharingPicker` or `CGWindow` + TCC handling.
- Vision API key storage: use existing `KeychainSecretStore`.
- Which vision provider? Start with whatever is already available to `tm07x` (OpenAI, Anthropic, Cloudflare, etc.) and make it swappable.
- Error model: if vision fails, still save the screenshot with an empty comment so nothing is lost.

## Deliverables

1. Updated architecture diagram showing Feature 3 flow.
2. Implementation commits for the seams above.
3. Test suite additions.
4. README section.
5. Manual verification log.

## State at mission start

- Branch: `main`
- HEAD: `5f6edf9`
- Remotes: `github` and `gitlab` both in sync.
