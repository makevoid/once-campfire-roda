# Compatibility with the Rails source

This is a partial port. Shared text-message workflows and the supplied benchmark URLs are verified, but full functionality is **not equivalent** to Rails. It uses its own schema and frontend; it does not load Rails models, Rails plugins, Rails templates, or Rails cookies.

| Area | Behavior |
| --- | --- |
| Benchmark paths | `/rooms/:id`, `/rooms/:id/messages?before=:id`, `/users/me/sidebar`, `/searches?q=coffee` |
| Authentication | Same email/password login fields and `session_token` cookie name; new encrypted cookie format. Existing bcrypt hashes import, existing sessions do not. |
| Message paging | 40 messages per page, timestamp + ID cursor, 40 on either side of a permalink anchor; equal timestamps no longer cause skipped messages. |
| Search | SQLite FTS5 porter tokenizer, newest 100 authorized matches. Operators and punctuation are treated as words, not executable query syntax. |
| Permissions | Room membership required even for administrators. Authors/admins edit or delete messages. Direct rooms cannot become open/private rooms. |
| Boosts | Only the booster can remove a boost, including when another user is an administrator. |
| Sidebar | Visible shared/direct room order and unread flags follow Rails. Hidden direct chats still exclude their participants from suggestions; the suggestion count preserves Rails' current-user counting behavior. |
| Direct conversations | A unique canonical participant key replaces scanning all direct rooms. Any participant can delete a direct conversation through its direct-room endpoint. |
| Live changes | Database-backed two-second polling, 30-second room heartbeats, ten-second sidebar refresh. No Action Cable protocol, typing indicators, or Turbo stream HTML. |
| Unread delivery | Room-specific durable events and user-scoped sidebar state. The separate fanout benchmark is a transport-free computation probe. |
| HTML | A sanitized subset of ordinary HTML is preserved. The composer sends plain text; the edit screen accepts sanitized HTML. This is not the original Lexxy rich-text editor. |
| Attachments | Local files, room-authorized downloads, safe raster image previews. No Active Storage signed URLs, variants, video processing, or remote storage adapter. |
| Mentions | `@Name` triggers mention notifications/bot webhooks for current room members. Rails signed Action Text mention objects are not recognized. |
| Notifications | Optional Web Push plus unread indicators; configure VAPID and run `bin/worker`. Presence means a recent visible-page heartbeat. |
| Bots | `/rooms/:room_id/:bot_key/messages` supports GET/POST/PATCH/PUT/DELETE and nested boosts. Plain-text, HTML, JSON, or multipart posting; membership and ownership apply. Webhooks support text/HTML responses, not binary attachment responses. |
| Administration | Account name, room-creation restriction, invitations, roles, deactivation, bans, bot keys, bot webhook settings. |
| Not ported | Uploaded profile/account avatars, custom account CSS, QR codes/session transfer, sound effects, link unfurling/Open Graph embeds, and the original PWA installation UI. |

The API returns compact JSON for requests with `Accept: application/json`; HTML forms redirect after writes. JSON fields cover message ID, client ID, timestamps, HTML/plain body, creator, room, boosts, attachments, and URL. Some original Rails response shapes, error formats, named routes, and less-used methods differ.

## What was checked against live Rails

On 2026-10-06, [`bench/verify_parity.rb`](../bench/verify_parity.rb) passed 54 checks against separate production-mode Rails and Roda servers, using normal login and CSRF protection and disposable matching databases. The reference is Rails Campfire commit `d2155e85a01b8439c32a3604ebb7f39fea1ace0f`. The [saved report](../bench/recorded/2026-10-06/parity.json) lists each check.

- Room pages, earlier/later pagination, permalinks, and search returned identical ordered message IDs, text, basic HTML formatting, authors, timestamps, and boosts.
- Sidebars agreed on room order, unread flags in the fixture, suggested users, and the result of hiding a direct chat.
- Authenticated creation, author editing/deletion, search-index updates, and boost creation/removal worked on both. Anonymous access, missing CSRF, non-author editing, and another user's boost removal were rejected.
- Private-room members could read their messages; outsiders could not read/search/write them or use their IDs as cross-room cursors. The source Rails app returned HTTP 500 for the tested unauthorized private write because its error template was missing; Roda returned 404. Neither persisted the message. The report records that response difference.

The audit found and fixed two sidebar differences (hidden participants and suggestion counts) and an overly permissive administrator boost-removal rule. Regression tests cover those cases. The fixture builder also now stores whole-second timestamps in Active Record's native format, avoiding a synthetic pagination mismatch.

These checks establish shared behavior for the tested cases, not complete equivalence. They normalize message content rather than compare the whole HTML document. They do not verify browser controls, concurrent live delivery, rich Action Text objects, media, every search syntax, every error response, or every Rails feature. Rails' timestamp-only pagination also differs from Roda's timestamp-plus-ID boundary for tied timestamps. The Roda-only suite covers additional permissions, imports, uploads, durable events, concurrent writes, and delivery adapters; it cannot establish Rails parity for them.

## Import details

The importer reads accounts, users, rooms, memberships, messages/Action Text body, boosts, searches, bans, webhooks, and push subscriptions. It preserves primary keys. Message attachments are copied when a Rails storage directory is specified. The original source remains read-only.

Old embedded Action Text objects, inline blob embeds, image variants, avatars, custom style behavior, and signed attachable references are not migrated into equivalent interactive objects. HTML is sanitized during import, so retain the Rails backup if those details matter. Message attachments retain their files and filenames.

The new schema enforces unique participant sets, normalized email uniqueness, and per-user query uniqueness. Inconsistent source duplicates fail the import instead of silently selecting one record. Sessions are intentionally omitted. Source secrets are not used by Roda. This importer has automated tests against Rails-shaped fixture tables; no production backup was supplied for an end-to-end migration rehearsal.
