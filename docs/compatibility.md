# Rails application coverage

This port implements Campfire's application features with Roda, Sequel and an
independent Erubi renderer. It carries over the original frontend, including the
Lexxy editor, Turbo interactions, Stimulus controllers, styles, images and sounds.
**No Rails, Action View or ActiveSupport Ruby gems are direct or transitive runtime
dependencies.** The dependency and loaded-constant checks run in the test suite.

The reference is [Campfire](https://github.com/basecamp/once-campfire) revision
`d2155e85a01b8439c32a3604ebb7f39fea1ace0f`. The independent database schema, cookies,
signed tokens and file URLs differ; migrate data with the importer instead of
pointing Roda at a Rails database.

| Area | Implemented behavior | Verification |
| --- | --- | --- |
| Rendering and frontend | Compiled Erubi templates, escaped output, native helpers, original responsive UI, editor, reactions, menus, search, keyboard controls and asset import map | Renderer tests; live DOM/control comparison; desktop/mobile Chrome |
| Authentication | Setup, invitation signup, bcrypt login, CSRF, encrypted cookies, sign-in throttling, sign-out, session revocation, return URL and last-room navigation | Rack tests; live login/CSRF/privacy audit |
| Rooms | Open/private rooms, participant management, conversion between open/private, canonical direct conversations, deletion and notification preferences | Service/Rack tests; live form and private-room audit |
| Messages | Rich text, edit/delete, idempotent submission, boosts, pagination, permalinks, reply/copy controls, search and search history | Live Rails comparison; browser composer/reaction/edit/search checks |
| Rich content | Signed user mentions, room-scoped autocomplete, safe Open Graph embeds, autolinks, formatted/code content and built-in `/play` sounds | Rich-content tests; live autocomplete comparison |
| Realtime | Authenticated WebSockets, original client protocol, Turbo message/boost/sidebar updates, unread/read streams, presence, typing, reconnect refresh and permission revocation | Protocol tests; live Puma WebSocket audit; Chrome subscription and posting |
| Files | Multipart uploads, authorized downloads, raster thumbnails, video metadata/previews, PDF first-page previews and HTTP byte ranges | Upload/privacy tests; real libvips, FFmpeg and Poppler processing tests |
| Profiles and account | Avatar/logo upload, variants/removal, initials, bio/password/email, custom CSS, room-creation restriction and invitation rotation | Media/account tests; matching live forms |
| Administration | Roles, deactivation, release of deactivated email addresses, bans, session revocation and removal of banned content | Authorization/service tests |
| Transfer | Purpose-bound expiring sign-in links, QR codes and transfer form | Token/CSRF/revocation tests; live QR response check |
| Bots and API | Raw text/HTML and multipart messages, pagination headers, original message/boost JSON shapes, token rotation and membership/ownership checks | API/Rack tests |
| Delivery | Durable jobs, mention/direct bot webhooks, text/HTML/file replies, timeout messages, push preferences and presence checks, device management and test notifications | Fake-transport delivery tests, policy tests and ownership tests |
| PWA | Manifest/icons/shortcuts, installation instructions, notification controls, service worker, notification navigation and badge updates | Live manifest and asset audit; service-worker code review |
| Import | Accounts, users/passwords, rooms/memberships, messages, boosts, searches, bans, bot hooks, push subscriptions, attachments, avatars/logos and rewritten user mention tokens | Read-only source/checksum test and Rails fixture round trip |

## Live comparison

The expanded audit passed **83 checks** against production-mode Rails and Roda
servers. Both used disposable matching fixtures, normal login and CSRF protection.
[`bench/verify_parity.rb`](../bench/verify_parity.rb) compares:

- Ordered message IDs, body text and formatting, authors, timestamps and boosts.
- Per-message element counts, all eight reaction forms, frontend actions and Turbo
  frame IDs for room pages, both pagination directions, permalinks and search.
- Sidebar ordering, unread flags, suggested participants and hidden direct chats.
- Named form controls on ten room, profile, account and bot screens; autocomplete
  names/IDs; PWA metadata, logos and QR responses.
- Writes, search updates, authorship, boost ownership, anonymous access, CSRF,
  private-room membership and cross-room cursor isolation.

The audit caught and fixed a Turbo frame ID mismatch. The browser audit also
caught a missing HTML charset. These are examples of why comparing only visible
message text was insufficient.

The Roda tests include **68 tests / 511 assertions**. A separate live frontend audit
passed **136 asset and WebSocket checks**. Headless Chrome exercised the editor,
posting, reactions, Unicode, editing, search, profile and mobile layout, with no
JavaScript errors in the successful run. Screenshots were inspected locally.

## Deliberate implementation differences and test limits

Roda uses timestamp-plus-ID pagination to avoid losing messages with tied
timestamps; Rails uses timestamp boundaries. Roda sanitizes HTML and validates
inputs before persistence, limits uploads to 25 MB and message HTML to 100 KB,
requires 12–72-byte passwords, and expires sessions after 30 days. Error pages and
some rejection status codes differ. The reference returns HTTP 500 for the tested
unauthorized private-room message POST because its error rendering fails; Roda
returns 404. Neither persists that message.

Realtime events and delivery jobs are stored in SQLite. The server implements the
browser's Action Cable protocol directly with `websocket-driver`; it does not load
Action Cable Ruby or require Redis. Roda compiles templates once and renders each
response without fragment or response caching. Rails retains its normal production
Redis cache in the benchmark.

The automated checks cover the features listed above; they are not an exhaustive
proof of identical behavior for every possible input. Real push-provider delivery
and OS-level PWA installation need configured VAPID keys and a device; delivery
tests use fake transports. Only local Chrome was exercised, not Safari or Firefox.
Docker deployment was not run in this workspace. HTTP read benchmarks do not
measure browser rendering, uploads, write throughput or background delivery.

## Migration details

The importer opens the source SQLite database read-only and requires an empty
destination. It preserves IDs, bcrypt hashes and memberships, sanitizes message
HTML and rebuilds FTS. With `--storage`, it copies message files, user avatars and
account logos. User mention global IDs in the selected source database are
re-signed for Roda; legacy Marshal payloads are scanned as bytes, never executed.
Open Graph embed information is reconstructed when rendered. Derived previews are
regenerated from originals.

Existing Rails sessions, old signed URLs and generated variants are not imported.
Unknown embedded object types render as missing attachments. Inconsistent source
duplicates or missing original files fail the import and roll it back. Keep the
source backup. No production backup was supplied for a migration rehearsal.
