# Campfire — Roda + Sequel

An object-oriented Ruby reimplementation of [37signals' Campfire](https://github.com/basecamp/once-campfire), focused on shared messaging workflows and its message benchmarks. Roda handles HTTP routing, Sequel handles SQLite queries and transactions, and a small compiled ERB renderer serves HTML. Rails, Active Record, Redis, Node, and an asset build are not runtime dependencies.

**This is a partial port, not full Rails feature parity.** Text-message behavior is checked against the Rails application, but the editor, media handling, live-update transport, and parts of the UI differ. Read the [compatibility report](docs/compatibility.md) before using it as a replacement.

## Run

Requires Ruby 4.0 and SQLite with FTS5 (included in the bundled sqlite3 gem).

```sh
bundle install
bundle exec rake db:migrate
bundle exec rake dev
```

Visit **http://127.0.0.1:9292** and create the first administrator. The database defaults to `storage/campfire.sqlite3`. Start the optional delivery worker in another terminal:

```sh
bundle exec ruby bin/worker
```

Use the invitation in Account settings to add people. Passwords must be 12–72 bytes. For sample data, use the isolated benchmark seed below; it does not populate the normal application database.

## Implemented

- First-run setup, invitations, bcrypt passwords, encrypted session cookies, revocation, CSRF protection, and sign-in throttling.
- Open/private rooms, membership management, notification preferences, and direct conversations unique to their participant set.
- Messages, safe HTML, editing/deletion, boosts, idempotent posting, file uploads/downloads, and raster image previews.
- Indexed cursor pagination, message permalinks, room-scoped FTS5 search, and per-user search history.
- Unread room state, presence heartbeats, and live changes including edits/deletions through a durable polling feed.
- User profiles, administrator roles, deactivation, banning, invitation rotation, bots, bot key rotation, and bot message/boost APIs.
- Durable background jobs, `@Name` mentions, bot webhooks with text replies, and optional Web Push notifications.
- A read-only Rails importer, automated tests, and the benchmark workloads from the supplied Rails app.

This is a new frontend and database schema, **not a drop-in Rails/Hotwire replacement**. See [compatibility](docs/compatibility.md) before importing an existing installation.

## Architecture and speed

`App` owns middleware and the top-level route tree. Private modules in `lib/campfire/routes/` group message, room, user, account, and shared request handling. They call `Service`, which coordinates authorization and transactions. `Repository` owns Sequel datasets and bulk loading. `User` and `Room` hold domain behavior; `Page` holds presentation data. `Renderer` has precompiled templates. `Authentication`, `Uploads`, `JobQueue`, `Delivery`, and `Importer` have separate responsibilities. A dependency container connects them, so tests use isolated databases and delivery transports.

- SQLite WAL, a connection pool, a Ruby busy handler that releases the GVL, and short `BEGIN IMMEDIATE` write transactions.
- `(room_id, created_at, id)` cursor index; no message OFFSET scans and deterministic handling of identical timestamps.
- One joined query for message/creator data and two bulk queries for boosts and attachments, regardless of page size.
- FTS5 with permission filtering before the result limit and triggers that update the index in the message transaction.
- A database-local fast parser for the UTC timestamp format, with Sequel's normal parser retained for other formats.
- Precompiled ERB and escaped string rendering; no per-message partial evaluation or ORM object graph.
- No response cache, process-local authorization cache, or special benchmark authentication bypass.
- Outbound HTTP runs in the worker, outside message writes and request handling.

SQLite uses `synchronous=NORMAL`: the database remains consistent after a crash, but a power failure can lose the latest committed transactions. Tune this in `Database.connect` if stronger durability is needed.

## Tests and benchmarks

```sh
bundle exec rake test
bundle exec ruby bench/seed.rb --output tmp/bench-seed
bundle exec ruby bench/message_hot_paths.rb --seed tmp/bench-seed
ruby bench/compare_http.rb --seed tmp/bench-seed --duration 10 --rounds 2
```

The seed has 2,000 messages, 100 users, 12 open rooms, 8 direct rooms, and boosts. The benchmark drivers snapshot the fixture database before running; they do not benchmark against the normal application database. HTTP requests use the supplied Rails `BenchmarkHTTPClient` unchanged, including normal CSRF login, keep-alive, full response consumption, and mandatory HTTP 200 results.

The final comparison was rerun after the route refactor and behavior fixes on 2026-10-06. Both production Puma servers used Ruby 4.0.2 with YJIT, five threads, and matching fixtures. **All 276,946 measured requests returned HTTP 200 with zero transport errors.** Medians of four rounds at **16 concurrent clients**:

| Shared read workload | Rails req/s | Roda req/s | Roda / Rails |
| --- | ---: | ---: | ---: |
| Room (40 messages) | 128 | 1,333 | 10.38× |
| Earlier messages (40) | 247 | 2,061 | 8.35× |
| Sidebar | 265 | 2,600 | 9.81× |
| Search (100 matches) | 108 | 932 | 8.65× |

These are application measurements on shared text-reading workloads, **not a framework-only speedup or full feature equivalence**. Roda returns 14.7–16.0× less HTML and has a simpler frontend. All rounds are retained, including substantial timing variation. [Detailed results](docs/performance.md#live-rails-and-roda-comparison) include concurrency 1, latency, response sizes, ranges, and resource use; [per-round JSON evidence](bench/recorded/2026-10-06/) and [reproduction commands](bench/README.md#reproduce-the-recorded-rails-comparison) are published.

Validation: **37 tests / 241 assertions** and **54 live Rails/Roda behavior checks** passed. The audit compares rendered message content, pagination, sidebars, writes/search updates, CSRF, ownership, and private-room isolation. It found and fixed sidebar and boost-ownership mismatches. [Compatibility details and remaining gaps](docs/compatibility.md) explain exactly what is verified.

## Import Rails data

Work from a consistent backup of the Rails SQLite database and Active Storage directory. The destination must be new:

```sh
bundle exec ruby bin/import-rails \
  --source /path/to/rails-backup.sqlite3 \
  --destination storage/imported.sqlite3 \
  --storage /path/to/rails-active-storage \
  --files storage/files
DATABASE_PATH=storage/imported.sqlite3 bundle exec rake dev
```

The importer opens the source read-only, preserves IDs/password hashes/memberships, sanitizes message HTML, rebuilds FTS, and copies message attachments when `--storage` is provided. Existing Rails sessions are not imported. Import fails and rolls back on incompatible duplicate records or missing attachment files. Keep the original backup: embedded Action Text objects and other unsupported Rails-specific features are not losslessly represented.

## Production

Set `SESSION_SECRET` to at least 64 random bytes, retain it across restarts, and put Puma behind an HTTPS reverse proxy. Never reuse the documented benchmark fixture secret in production.

```sh
export SESSION_SECRET="$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')"
RACK_ENV=production HOST=127.0.0.1 PORT=9292 bundle exec puma -C config/puma.rb
```

Configuration: `DATABASE_PATH`, `UPLOAD_ROOT`, `HOST`, `PORT`, `MAX_THREADS` (5), `DB_POOL` (5), and `WEB_CONCURRENCY` (0). Start with one process/five threads. Use a pool at least as large as the thread count. Extra Puma workers have their own database pools and share durable state through SQLite. Use local disk, not a network filesystem, for the database and WAL files.

Secure cookies are enabled in production. `DISABLE_SSL=true` is only for deliberate local HTTP testing. The reverse proxy should overwrite forwarded headers and apply upload limits. Uploads are capped at 25 MB, served only after room authorization, and use attachment disposition except for explicitly requested supported image previews.

For Docker, set `SESSION_SECRET`, then run `docker compose up --build`. The compose file binds port 9292 to loopback, shares a persistent volume, and starts the delivery worker after the web app becomes healthy. Docker build/start were not available for verification in this workspace.

For Web Push, generate VAPID keys with the installed `web-push` gem and configure `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, and `VAPID_SUBJECT` (a `mailto:` contact URL) for the web and worker processes. Then enable notifications from Profile in a supported HTTPS browser. Notification preferences are in Room settings. The delivery tests use fake transports; actual push-provider delivery requires your keys and subscription.

Webhook URLs are administrator-controlled and, like the Rails app, may point at internal services. Push subscription URLs must use HTTPS and resolve only to public IPs; connections pin the checked IP and retain TLS hostname verification. Neither path follows redirects. Jobs retry with backoff up to eight attempts; inspect the `jobs` table for exhausted jobs. Delivery is at-least-once. Text replies use deterministic client message IDs to avoid duplicate messages on a retry.

Back up SQLite through its backup API, and back up `storage/files` and your secrets separately. Events and unattached files are retained; plan retention/cleanup for long-lived, high-volume installations.

## License

[MIT](MIT-LICENSE). The source reference and reused benchmark HTTP client are copyright 37signals, LLC.
