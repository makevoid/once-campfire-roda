<h1 align="center">Campfire — Roda + Sequel + Erubi</h1>

<h2 align="center">Rails vs. Roda benchmarks</h2>

<p align="center">
  <strong>16 concurrent clients · Median of 4 × 8-second rounds · Requests per second</strong><br>
  Ruby 4.0.7 + YJIT · Puma 8.0.2: 3 workers × 5 threads · Shared verification fixture
</p>

<table align="center">
  <thead>
    <tr>
      <th align="left">Workload</th>
      <th align="right">Rails req/s</th>
      <th align="right">Roda req/s</th>
      <th align="right">Roda / Rails</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Room (40 messages)</td>
      <td align="right">3,887</td>
      <td align="right"><strong>14,353</strong></td>
      <td align="right"><strong>3.69×</strong></td>
    </tr>
    <tr>
      <td>Earlier messages (40)</td>
      <td align="right">3,739</td>
      <td align="right"><strong>16,663</strong></td>
      <td align="right"><strong>4.46×</strong></td>
    </tr>
    <tr>
      <td>Sidebar</td>
      <td align="right">3,907</td>
      <td align="right"><strong>19,258</strong></td>
      <td align="right"><strong>4.93×</strong></td>
    </tr>
    <tr>
      <td>Search (13 matches)</td>
      <td align="right">4,147</td>
      <td align="right"><strong>19,080</strong></td>
      <td align="right"><strong>4.60×</strong></td>
    </tr>
    <tr>
      <td>Post message</td>
      <td align="right">222.8</td>
      <td align="right"><strong>502.4</strong></td>
      <td align="right"><strong>2.26×</strong></td>
    </tr>
  </tbody>
</table>

<p align="center">
  <strong>10,304,242 validated timed responses across all 8 routes · Zero errors</strong><br>
  Measured 2026-10-08 (UTC) · 27,757 acknowledged writes audited, including warmups.<br>
  Rails is faster on avatars and static CSS; all routes and ranges are reported.<br>
  <a href="docs/performance.md#live-rails-and-roda-comparison">Detailed results &amp; methodology</a> ·
  <a href="bench/recorded/2026-10-08-shared/">Recorded measurements</a> ·
  <a href="bench/verification/README.md">Reproduce</a> ·
  <a href="docs/upstream-update.md">Upstream update</a>
</p>

---

A port of [37signals’ Campfire](https://github.com/basecamp/once-campfire) using **Roda + Sequel + Erubi**, with the original frontend and an independent Ruby renderer. **No ActiveSupport, Action View, Active Record or other Rails Ruby dependencies.**

Updated through Campfire [`05c5a2c`](https://github.com/basecamp/once-campfire/commit/05c5a2c0d72f7fd74d7c2ace23cc123000f956b9). The table compares both production stacks serving matching Campfire data and frontend controls, including the full message UI, editor, reaction forms and menus. It measures repeated requests from one logged-in user with production caches enabled. [Coverage and verification](docs/compatibility.md) describe tested behavior and remaining limits.

## Run

Requires Ruby 4.0, SQLite with FTS5 (included by the sqlite3 gem), libvips, FFmpeg and Poppler. On macOS: `brew install ruby vips ffmpeg poppler`.

```sh
bundle install
bundle exec rake db:migrate
bundle exec rake dev
```

Open **http://127.0.0.1:9292** and create the first administrator. Invite people from Account settings. The database defaults to `storage/campfire.sqlite3`; files live in `storage/files`.

Start the delivery worker for bot webhooks and push notifications:

```sh
bundle exec ruby bin/worker
```

The application needs neither Redis nor Node. Frontend assets are included. After changing `frontend/`, run `bundle exec ruby bin/build_frontend` and restart Puma.

## Features

- Setup, invitations, authentication, Fetch Metadata/Origin forgery protection, sign-in throttling, profile/avatar management, account logos, custom CSS and session-transfer QR codes.
- Open/private rooms, participant management, direct conversations, unread state, presence, typing indicators and live Turbo updates over WebSockets.
- Lexxy rich text, signed mentions/autocomplete, Open Graph previews, sound messages, replies, reactions, editing, deletion, search and history.
- File uploads/downloads, image thumbnails, video/PDF previews, media seeking and room authorization.
- Administration, bans/deactivation, bot keys and APIs, webhook text/file replies, durable delivery jobs, Web Push and PWA controls.
- Read-only import of Rails data, including attachments, avatars/logos, user mentions and embedded-file metadata.

[Detailed compatibility](docs/compatibility.md) includes verification coverage, migration requirements and implementation differences. [Frontend provenance and licenses](THIRD_PARTY_NOTICES.md) identify the reused browser libraries.

## Architecture

`App` owns middleware and the route tree. Modules in `lib/campfire/routes/` handle request concerns and call `Service` for authorization and transactional writes. `Repository` owns Sequel datasets, pagination, search and bulk loading.

`UI::Engine` compiles Erubi templates into reusable Ruby methods. Frequently rendered messages and reactions use direct HTML with interpolated URLs. Small, independent helper modules handle forms, escaped attributes, rich content and other presentation needs. Presentation adapters wrap database rows; they do not persist or authorize. No Rails compatibility layer or standard-library monkey patches are used.

`Media`, `Tokens`, `API`, `Authentication`, `Delivery` and `Importer` have separate responsibilities. The realtime server implements the browser’s wire protocol with `websocket-driver`; SQLite events carry changes across Puma processes. Durable jobs keep outbound requests out of message writes.

Performance choices include indexed cursor pagination, bulk queries, FTS5 permission filtering before LIMIT, atomic message/index/unread writes, maintained message counters and background WAL checkpoints. Bounded response and row caches invalidate on database commits; message fragments depend on their rendered values. Authentication, session expiry and room access are checked before response reuse. Templates compile once. [The update audit](docs/upstream-update.md) documents invalidation, media limits, asynchronous deletion and pooled push connections.

## Tests and benchmarks

```sh
bundle exec rake test
ruby bin/benchmark --prepare --rounds 4 --duration 8
ruby bin/benchmark --rounds 4 --duration 8 --mixed-write-rate 10
```

Validation: **134 native tests**, passing on macOS (844 assertions) and Linux Ruby 4.0.7 (842 assertions), plus the shared harness checks and Chromium flow, **136 HTTP/WebSocket checks** and **11 desktop/mobile Chrome checks**. Platform skips cover unavailable libvips loaders. Tests cover cache invalidation and authorization, atomic writes, unread ordering, media processing and real local TLS reuse. The suite also rejects Rails gems and ActiveSupport/Action View constants. Real push-provider delivery and OS-level PWA installation remain untested.

`bin/benchmark` clones the public verification harness with `gh` over SSH and defaults to **Rails vs Roda only**. Its Rust client and response contracts are unchanged. The 169-message shared fixture includes real attachments; expected read content comes independently from its Rails SQL. Every timed response is validated, and every acknowledged POST is checked for its unique persisted ID, room and exact request token in its stored body and FTS entry. Four alternating rounds use separate server/client CPU sets in Docker Desktop. Rails retains Thruster and Redis; Roda uses Puma and SQLite jobs. Raw results stay in ignored `tmp/` directories.

See [measurements and methodology](docs/performance.md), [all recorded rounds](bench/recorded/2026-10-08-shared/), and [reproduction instructions](bench/verification/README.md). The [2026-10-06 comparison](docs/performance-2026-10-06.md), [single-process comparison](docs/performance-single-process.md) and [minimal-frontend measurements](docs/performance-partial-port.md) remain as historical reports; their fixtures and harness differ.

## Import Rails data

Use a consistent backup of the Rails SQLite database and its local Active Storage directory. The destination must be new:

```sh
bundle exec ruby bin/import-rails \
  --source /path/to/rails-backup.sqlite3 \
  --destination storage/imported.sqlite3 \
  --storage /path/to/rails-active-storage \
  --files storage/files
DATABASE_PATH=storage/imported.sqlite3 bundle exec rake dev
```

The importer opens the source read-only, preserves IDs/password hashes/memberships, sanitizes rich text, re-signs known user mentions and embedded-file metadata, rebuilds FTS/counters and copies original files. It generates previews during import; viewing a message never retries preview generation. Existing Rails sessions and signed URLs do not carry over. Import rolls back on incompatible duplicates or missing files. Retain the original backup; unknown embedded object types render as missing attachments. See [migration details](docs/compatibility.md#migration-details).

## Production

Set a stable `SESSION_SECRET` of at least 64 random bytes and put Puma behind an HTTPS reverse proxy:

```sh
export SESSION_SECRET="$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')"
RACK_ENV=production HOST=127.0.0.1 PORT=9292 bundle exec puma -C config/puma.rb
```

Configuration: `DATABASE_PATH`, `UPLOAD_ROOT`, `HOST`, `PORT`, `MAX_THREADS` (2), `DB_POOL` (5 per worker), and `WEB_CONCURRENCY` (`auto` in production, 0 in development). Auto uses the available CPU count minus two; machines with three or fewer CPUs use one process. Set an explicit worker count for your container CPU and memory limits. Each worker owns its database pool; keep it at least as large as the thread count. Use local disk for SQLite/WAL. The reverse proxy must forward WebSocket upgrades and overwrite forwarded headers. Production cookies are secure; `DISABLE_SSL=true` is for deliberate local HTTP tests.

Cluster mode preloads the application and runs migrations once, then stops checkpoint threads and disconnects Sequel before forking. Workers open independent SQLite connections. Production enables YJIT; set `RUBY_YJIT_ENABLE=0` to disable it. `CAMPFIRE_RESPONSE_CACHE_MB` and `CAMPFIRE_FRAGMENT_CACHE_MB` each default to 64 MiB per worker; set either to `0` to disable that store. These bound cached payloads, not total process memory. Restart workers after changing templates or assets.

For Docker, set `SESSION_SECRET` and run `docker compose up --build`. The compose file binds port 9292 to loopback, persists data and starts the delivery worker. Production images were built and exercised in the shared benchmark; the Compose deployment itself was not separately tested. Keep the worker running for outbound delivery and asynchronous room deletion.

For Web Push, configure `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT` for both web and worker processes, then enable notifications in a supported HTTPS browser. The included tests use fake delivery transports; actual push-provider delivery and OS-level PWA installation require a configured device.

Webhook URLs are administrator-controlled and may target internal services, as in Campfire. Push subscriptions are restricted to the original provider allowlist and public IPs. Link previews reject private addresses, validate redirects and have a ten-second deadline. Outbound connections pin the checked IP while retaining TLS hostname validation; push connections are reused only for the same hostname, port and freshly approved IP.

Uploads are limited to 25 MB, message HTML to 100 KB, and passwords to 12–72 bytes. Sessions expire after 30 days. Jobs retry with backoff up to eight attempts; inspect `jobs` for exhausted attempts. Delivery is at-least-once, with deterministic bot reply IDs to avoid duplicates.

Back up SQLite through its backup API, alongside files and secrets. SQLite uses `synchronous=NORMAL`, so power failure can lose recent commits. Events and unattached files are retained; provide a retention policy for a long-lived installation.

## License

[MIT](MIT-LICENSE). Original Campfire code/assets and the reused benchmark client are copyright 37signals, LLC. See [third-party notices](THIRD_PARTY_NOTICES.md).
