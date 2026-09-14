# ZoneCapture

A tiny macOS app for capturing URLs, notes, and page content **without leaving your flow**.

You're deep in a task, you hit a link worth keeping — instead of swapping spaces
and breaking your zone, you press **⌘⇧L**. A small floating panel appears with
the URL of your frontmost browser tab already filled in (the tab title is
saved along with it). You type a one-line note, hit **Return**, and it's saved
to a local SQLite database. The panel disappears. You never left the keyboard.

Press **⌘⇧⌥L** to capture the *full page content* instead: ZoneCapture downloads
the page, extracts readable Markdown + YAML frontmatter, writes a `.md`/`.json`
sidecar to `captures/`, and records it as `kind='capture'` with a pointer to the
file. Read it later with `zonectl open <id>`.

This is v0.2: core URL capture (v0.1) **plus Feature 2 page-content extraction**,
both working end-to-end. Features 3–4 (non-browser app screenshots, the durable
zone-mode AI chat + routing DSL) are noted under **Roadmap** below.

## Build & install

```bash
cd VM-APPS/zonecapture
./make-app.sh          # builds release, installs to /Applications, launches
# or
./make-app.sh build    # build only, launches from ./build/ZoneCapture.app
```

Requires the Xcode Command Line Tools (Swift 5.9+). No external dependencies —
SQLite is linked against the system `libsqlite3`.

On launch the app registers itself as a **login item** (`SMAppService`), so
the ⌘⇧L hotkey keeps working after a reboot. Manage it under
System Settings → General → Login Items & Extensions.

## Using it

### URL capture (⌘⇧L)

1. Open a browser and navigate to a page you want to keep.
2. Press **⌘⇧L** (or click the bookmark icon in the menu bar → "Capture
   frontmost URL").
3. The URL is pre-filled. Type an optional note.
4. Press **Return** to save (or **Esc** to cancel). A brief "✓ Captured"
   banner confirms it landed.

### Page-content capture (⌘⇧⌥L)

1. Open a browser on the page you want to read later.
2. Press **⌘⇧⌥L**. ZoneCapture downloads the page, extracts the main content,
   and writes a Markdown file + JSON sidecar under `captures/`.
3. A "✓ Page captured" banner confirms it. No panel to dismiss.

Menu-bar menu:
- **Capture frontmost URL** — same as ⌘⇧L.
- **Capture page content** — same as ⌘⇧⌥L.
- **Recent captures…** — shows the last 12 rows (URL/tab title/note,
  timestamp, kind, capture path).
- **Reveal database in Finder** — opens the folder holding `zonecapture.db`.

## Where data lives

| Thing            | Path                                                        |
|------------------|-------------------------------------------------------------|
| SQLite database  | `~/Library/Application Support/ZoneCapture/zonecapture.db` |
| Parsed captures  | `~/Library/Application Support/ZoneCapture/captures/`      |

Fixed storage, survives app reinstalls. The `links` table:

```sql
CREATE TABLE links (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    url          TEXT NOT NULL,
    title        TEXT,
    comment      TEXT,
    source_app   TEXT,
    kind         TEXT NOT NULL DEFAULT 'url',  -- 'url' | 'note' | 'capture'
    capture_path TEXT,                          -- path to parsed markdown (feature 2)
    created_at   REAL NOT NULL
);
```

## Supported browsers (URL grab via AppleScript)

Safari, Google Chrome, Microsoft Edge, Brave, Arc — matched by **exact bundle
ID** (no fuzzy name matching, so the wrong browser can never be scripted or
launched). Firefox has no tab-URL AppleScript dictionary; ZoneCapture tries
the Accessibility API (address bar of the focused window) and otherwise opens
the panel with an empty URL field so you can paste.

## Hotkey configuration

- URL capture default: **⌘⇧L** (`hotkeyKeyCode` / `hotkeyModifiers`).
- Page-content capture default: **⌘⇧⌥L** (`pageHotkeyKeyCode` / `pageHotkeyModifiers`).

Change them without code (restart the app to apply):

```bash
defaults write com.grokink.zonecapture hotkeyKeyCode -int 37
defaults write com.grokink.zonecapture hotkeyModifiers -int 2816      # ⌘⌥L

defaults write com.grokink.zonecapture pageHotkeyKeyCode -int 37
defaults write com.grokink.zonecapture pageHotkeyModifiers -int 3328   # ⌘⇧⌥L
```

Carbon modifier masks: cmdKey 256 · shiftKey 512 · optionKey 2048 ·
controlKey 4096 (add to combine).

## Error feedback

Nothing fails silently:

- **Automation permission denied** → status line points to
  System Settings → Privacy & Security → Automation.
- **Browser unreadable** (not running, no tab, script error) → status line
  suggests pasting the URL.
- **Database write failure** → ✗ banner; the panel stays open with your text
  intact — press ↵ to retry.
- **Database read failure** → "Recent captures…" reports the error.
- **Hotkey not registered** (combo owned by another app) → the menu-bar entry
  is renamed with a ⚠︎ warning.

## Architecture

```
Sources/ZoneCapture/
  main.swift             entry point; LSUIElement accessory app
  AppDelegate.swift      menu-bar item + both hotkeys + recent/reveal actions
  HotkeyManager.swift    Carbon RegisterEventHotKey global shortcut
  CapturePanel.swift     floating NSPanel: URL field, note field, Save/Cancel
  URLFetcher.swift       per-browser AppleScript / Accessibility URL fetch
Sources/ZoneCaptureCore/
  Store.swift            SQLite wrapper; fixed-location DB + captures dir
  Secrets.swift          Keychain-backed SecretStore (AI-key groundwork)
  PageExtractor.swift    ExtractionRunner protocol + Python script runner
  CaptureCoordinator.swift wires extraction → Store.insertLink(kind='capture')
Resources/
  Info.plist             LSUIElement, Apple Events usage description
  ZoneCapture.entitlements
tools/
  zone_extract.py        fetch page → readability → Markdown + frontmatter + JSON
  zonectl              read-side CLI: list, search, export, open <id>
make-app.sh            build + bundle tools + (ad-hoc) sign + install/launch
```

See `docs/zonecapture-architecture.html` for an interactive diagram.

## Roadmap (features 3–4 from the project README)

- **Feature 2 — page content:** ✅ implemented. Downloads the page, extracts
  Markdown + frontmatter, writes `.md`/`.json` to `captures/`, stores
  `kind='capture'` with `capture_path`. Read it with `zonectl open <id>`.
- **Feature 3 — non-browser apps:** when the frontmost app isn't a browser,
  capture its name + a window screenshot (`screencapture -l`), run the image
  through a vision model for text/context, let you comment, then store with
  `kind='capture'`.
- **Feature 4 — zone-mode AI chat + router DSL:** a durable chat surface that
  understands your shorthand, treats dropped links/files as research dumps (no
  conversation), and routes content to other agents based on a small DSL and
  your active-task context.

## Tests

Swift: 59 XCTest tests covering Store, URLFetcher, Secrets, PageExtractor
(including real-subprocess runs against stub scripts: success, error payload,
stderr fallback, pipe-flood deadlock regression, runaway-process watchdog,
custom interpreter), CaptureCoordinator, and HotkeyRegistry. Python: 11
pytest tests covering `zone_extract.py` and `zonectl`. Authored via the
project's subagent-driven TDD rules.

```bash
swift test
/tmp/zc-test-venv/bin/python -m pytest tools/tests/
```

`swift test` needs a full Xcode toolchain (Command Line Tools ships no
XCTest). If `xcode-select -p` points at Command Line Tools, run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

## Packaging notes

`make-app.sh` bundles a self-contained Python venv into
`Contents/Resources/tools/venv` (a GUI app's `/usr/bin/env python3` resolves
to the Command Line Tools interpreter, which lacks the extraction
dependencies). Creating it needs network access at build time for pip.
