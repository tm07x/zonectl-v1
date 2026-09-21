# Local clean-data API and explicit outbound transfers

Date: 2026-09-16
Status: Written spec approved in conversation; implementation is a later, separately planned phase.
Repository baseline: `462ef8e` (documentation); app baseline: `9c668cf`.

## Goal and boundaries

Make normalized captures available for external processing without introducing
an interpreter or hosted-service dependency into ZoneCapture. Accept clean
captures and derived topics back through an authenticated local API.

This is phase 3, after
[native extraction](2026-09-16-native-page-extraction-design.md) and
[GUI testing/diagnostics](2026-09-16-gui-testing-and-diagnostic-handoffs-design.md).
All app-side API, serialization, transfer, and credential handling is Swift.

The chosen architecture is a localhost API inside the running Mac app, plus
optional outbound HTTPS and S3 transfers. There is no hosted ZoneCapture API,
LAN listener, inbound internet access, tunnel, or always-running service.
The API is unavailable when the app is closed.

Local persistence remains authoritative. Network delivery never gates capture.
There is no automatic sync, remote deletion, conflict-merging engine, trajectory
inference, or automatic agent execution in this phase.

## Meaning of clean data

"Clean" means structured metadata plus readable Markdown, rather than raw HTML,
SQLite dumps, or absolute file paths. It does not mean anonymous or harmless.
Page text, titles, source URLs, notes, and topics can contain sensitive material.

Use a versioned Codable contract shared by imports, API reads, export files,
and outbound transfers. JSON is the v1 exchange format; Markdown is a field,
not a machine-specific file pointer.

Capture fields:

| Field | Contract |
|---|---|
| `capture_id` | Stable UUID, preserved across export/import |
| `kind` | `url`, `note`, or `capture` |
| `captured_at` | UTC RFC 3339 timestamp |
| `url` | HTTP(S) source URL; may be null for notes |
| `title`, `source_app` | Nullable descriptive metadata |
| `markdown` | Nonempty readable content for `capture`; otherwise nullable |
| `note` | Optional user note; omitted unless explicitly authorized |
| `topic` | Nullable current topic |
| `topic_revision` | Nonnegative revision used for conditional topic updates |
| `topic_provenance` | Nullable processor/model/time metadata, treated as untrusted |
| `extraction` | Nullable extractor/version and final-URL metadata |

Never include local paths, SQLite row IDs as portable identity, authentication
material from app configuration, browser cookies, or diagnostics. Source content
may itself contain secrets; there is no claim of perfect automatic redaction.
Reject URL user-info credentials. The export UI makes source URL/content
inclusion visible and requires explicit selection and destination confirmation.

Notes are excluded by default. A read client needs a separate `notes:read`
grant and must explicitly request notes. UI exports have a separate include-notes
control, initially off.

## Native components and storage

- A Swift data-exchange service validates DTOs and calls the shared serialized
  store and capture writer. It does not bypass capture persistence guarantees.
- A Swift HTTP adapter uses SwiftNIO's HTTP/1.1 codec and event loop, pinned
  through SwiftPM, rather than hand-rolling an HTTP parser.
- A snapshot builder constructs selected export payloads without exposing
  file paths. It reports missing/corrupt artifacts rather than omitting them
  silently.
- A Foundation `URLSession` transfer client sends the immutable staged payload.
- Keychain-backed credential handling builds on `SecretStore`.
- The existing shared diagnostic service records safe boundary failures.

Add a durable public UUID mapping and topic revision/provenance through an
additive, transactional database migration. Backfill each existing row once.
Preserve existing integer IDs, `links.topic`, timestamps, and capture paths.
Create stable public IDs for new GUI captures too. Do not migrate by exporting
and recreating the user's database. Test upgrade and interrupted-migration paths
on copies/fixtures before touching production.

Imported Markdown/sidecars receive locally generated paths. Reuse the journaled
artifact publication contract from phase 1. No API parameter specifies a file
path, SQL query, command, URL to fetch, or destination to contact.

## Listener and access control

Disabled by default. The user enables it in a small native "Data access" window,
which shows the bind address, active port, clients/scopes, and revoke controls.
Enabling the API does not enable outbound transfers.

- Bind only IPv4 `127.0.0.1`, never `0.0.0.0`, a LAN address, or a public address.
- Let the OS select an available port. Publish only address, port, API version,
  and app-session identity in an owner-only local descriptor for client discovery.
  Never put tokens in that file.
- Issue independent cryptographically random 256-bit bearer tokens per named
  client. Store secrets in Keychain, not UserDefaults, environment variables,
  URLs, reports, or Git. User-initiated token display/copy is the only initial
  sharing path; tokens are not discoverable through the API.
- Assign only approved scopes: `captures:read`, `notes:read`, `captures:write`,
  and `topics:write`. None of these grants permission to initiate app-managed
  transfers. Revocation takes effect on subsequent requests.
- Require authentication for every endpoint. Reject browser Origin requests;
  do not enable CORS or cookie authentication. Validate Host against the exact
  loopback listener authority to resist DNS rebinding.
- Bound concurrent connections to 16, headers to 16 KiB, requests to 64 MiB,
  and a request's total lifetime to 15 seconds. Enforce body limits while
  reading, including chunked input; do not trust Content-Length alone.
- Process at most two request bodies concurrently and reject excess work rather
  than accumulating unbounded buffers. The wire limit allows JSON escaping of a
  10 MiB Markdown field; field-level decoded limits still apply.
- Rate-limit each authenticated client to 60 requests/minute, with burst 10.
  Apply the same rate/burst limit globally to unauthenticated attempts.
  Report 429 without incident spam.
- If Keychain access or binding fails, leave the API unavailable and show a
  safe error. Do not fall back to anonymous access or another network interface.

Loopback HTTP is intentional for same-machine native/CLI clients. It is not a
security boundary against a fully compromised user account. Remote endpoints
and S3 always require HTTPS.

## Version 1 endpoints

| Method and path | Scope | Behavior |
|---|---|---|
| `GET /v1/captures` | `captures:read` | Paginated metadata summaries and opaque next cursor |
| `GET /v1/captures/{capture_id}` | `captures:read` | One complete clean capture; notes need the extra grant and explicit flag |
| `POST /v1/captures` | `captures:write` | Validate and import one normalized capture; never fetch its URL |
| `PUT /v1/captures/{capture_id}/topic` | `topics:write` | Conditional topic update with processor provenance |

Single-capture reads/imports use `{schema_version: 1, capture: ...}`.
Lists use `{schema_version: 1, captures: [...], next_cursor: ...}` and omit
Markdown/notes. Default page size is 50, maximum 100. The cursor establishes a
bounded scan and deterministic order; new inserts appear in a subsequent scan.
Topic metadata can change between a list and an item read. Invalid/expired
cursors fail explicitly rather than silently restarting.

Import validates the schema version, UUID, timestamps, supported kind,
required fields, field lengths, and Markdown restrictions. Maximum Markdown
is 10 MiB, note 64 KiB, URL/title 8 KiB each, topic 4 KiB, and provenance 8 KiB,
within the overall request limit. Reject raw HTML/unsafe link schemes, path
fields, and unsupported schema fields rather than executing or fetching them.
All imported text remains untrusted.

Require a source URL for `url` and `capture`. For a `note`, map a null URL to
the existing database's empty-string convention and back to null at the API
boundary; do not change the legacy NOT NULL column or invent a placeholder URL.
Validate Markdown structurally, preserving HTML examples inside code blocks
as text rather than rejecting them as active markup. If legacy Markdown does
not satisfy the clean contract, report an export validation failure identifying
the affected capture, without overwriting its original file or silently dropping
content. A legacy-sanitization/migration UI is outside this phase.

Successful new import returns 201 only after durable local persistence.
An identical retry returns 200 with the existing identity, not a second row.
Compare supplied immutable capture fields; an omitted note does not erase a
stored note. Reusing an ID with conflicting immutable content returns 409.
Import does not overwrite an existing topic: changes use the topic endpoint.
An initial non-null topic/provenance also requires `topics:write`; otherwise
reject it as insufficient scope. For new imports carrying topic data, start the
local revision at 1 and preserve the exported revision in provenance only.
Start untagged imports at revision 0. A source system's revision never replaces
the destination's concurrency counter.

Topic updates submit `schema_version`, `topic`, `expected_revision`, and
processor provenance. Update only when the revision matches, increment it
atomically, and record the authenticated client and local receipt time.
Return 409 with the current revision on a stale update. Retrying a request with
an uncertain result requires reading the current state first. This supports
external topicalization from `VISION.md`; it does not run an inference model.

HTTP outcomes distinguish malformed input (400), unauthenticated (401), forbidden
(403), unknown ID (404), conflict (409), oversized payload (413), unsupported
media type (415), rate limit (429), and internal persistence failure (500).
Use JSON errors with safe `code`, `message`, and `request_id`; include
`incident_id` only when a report was actually written. No stack traces or
arbitrary database/server error strings go to clients.

## Explicit export and delivery

Add "Export selected captures" to the native data-access surface. Select
records, choose whether to include notes, inspect destination and payload size,
then confirm. A grant to read the API permits that client to read the approved
fields; the app cannot control what an external client does with received data.

Build an immutable JSON snapshot:

```text
{ schema_version: 1, export_id, exported_at, captures: [Capture, ...] }
```

Take a coherent snapshot of metadata, with immutable capture artifacts.
An importer can iterate `captures` and submit the same individual representation
to `POST /v1/captures`; no database-file conversion is required. Topic updates
to existing IDs still require the conditional topic endpoint.

Offer three destinations using the same payload:

1. **Local JSON file:** selected by the user, with normal overwrite confirmation.
2. **HTTPS endpoint:** one explicit POST to a configured destination; optional
   bearer credential stored in Keychain. Send export ID as an idempotency key.
   The recipient may ignore that key, so exactly-once delivery is not promised.
3. **S3:** PUT one JSON object using a user-supplied, short-lived presigned HTTPS
   upload URL for a unique object key. Support the signed Content-Type and
   required headers; reject unsupported signing requirements before sending.

S3 signing is performed by the owner's existing tools/service, not by an AWS
CLI or embedded AWS account key in ZoneCapture. The app does not create buckets,
change bucket policies, list/delete objects, or promise a backup/restore system.
Bucket privacy, encryption, retention, and signing permissions remain the
owner's responsibility. Require a dedicated non-existing object key; warn that
a presigned PUT alone cannot prove uniqueness and may overwrite an existing
object. Where the signer supports conditional creation, honor its signed header.

Signed URLs and required secret headers are credentials. Keep them out of logs,
diagnostics, normal preferences, exported data, and screenshot evidence.
Persistent endpoint credentials use Keychain; one-shot presigned URLs stay in
memory only for the transfer and are discarded afterward. Redact URL queries
in confirmation/status displays.

Only user-confirmed destinations are contacted. Do not follow redirects for
POST/PUT transfers, forward credentials to a redirected host, weaken TLS checks,
or use destination URLs supplied by imported captures. Never attach cookies.

Limit an export to 64 MiB and stream from an owner-only staging file, not an
unbounded memory buffer. Reject larger selections with instructions to split
them. Allow one transfer at a time, with a 60-second total deadline, cancellation,
and a visible result. Bound server-response reads to 64 KiB and do not log bodies.

Do not automatically retry uploads. A timeout/cancellation/disconnection after
sending bytes has an unknown remote outcome, not proof of failed delivery.
Retain only the owned staged payload for up to 24 hours for explicit retry, with
a 64 MiB total staging budget. Expired S3 URLs require a replacement; retrying
an HTTPS POST is allowed only after warning about possible duplication.
Any replacement URL gets fresh destination confirmation.

A 2xx response means the endpoint accepted the request, not that downstream
processing completed. S3 success means the PUT was acknowledged, not that the
data has been restored or independently verified. Failed delivery does not
undo or delete the local capture.

## Diagnostics, testing, and acceptance

Extend the shared catalog with the reserved `ZC-600`–`ZC-612` entries from the
diagnostics spec. Do not introduce a second error index. Expected client
rejections produce safe API responses and bounded counters, not endless reports.
HTTP status, safe network error category, operation ID, and delivery outcome
remain separate from the fault code.

Acceptance requires:

1. Native schema tests, additive migration tests, legacy capture export,
   stable UUIDs, duplicate import, revision conflict, and crash-safe persistence.
2. Round trips through the real loopback listener and disposable data root,
   covering all capture kinds, Markdown fidelity, and note-scope isolation.
3. Missing/revoked tokens, insufficient scopes, disallowed Origin/Host, invalid
   schema, traversal/unsafe markup attempts, excessive body/header sizes,
   chunked bodies, deadlines, and rate limits.
4. Concurrent GUI writes and API imports/reads/topic updates without corrupted
   rows, duplicate IDs, deadlocks, or success responses after failed persistence.
5. Swift transfer integration tests against owned HTTP/TLS fixtures: exact JSON
   payload/headers, signed-URL handling, non-2xx errors, redirects, timeout,
   cancellation, uncertain outcomes, explicit retry, and bounded staging.
   Production TLS validation stays enabled; test-only trust is isolated to QA.
6. Supervised real-app GUI scenarios for enabling/disabling access, issuing and
   revoking a synthetic client token, importing a synthetic capture, observing it
   in the UI, and exporting to an owned fixture destination.
7. A separately authorized live S3 smoke test with synthetic data and a fresh
   test object key. Record it as blocked/not run without permission and a valid
   presigned URL; mocked PUT tests alone do not establish S3 interoperability.
   Report the created object key for owner cleanup; do not delete remote objects.
8. Privacy checks demonstrating that tokens, signed URLs, content, and notes do
   not leak into diagnostic events, handoffs, or screenshots. Deliberately
   selected clean data appears only in its intended export/destination.

Never test against the everyday app's data, publish real captures, or provision
cloud resources as an implicit consequence of implementing this spec.
