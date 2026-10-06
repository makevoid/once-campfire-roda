<h1 align="center">Campfire — Roda + Sequel + Erubi</h1>

<h2 align="center">Rails vs. Roda benchmarks</h2>

<p align="center">
  <strong>16 concurrent clients · Median of 4 rounds · Requests per second</strong><br>
  Ruby 4.0.2 + YJIT · Five-thread Puma · Matching 2,000-message fixtures
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
      <td align="right">179</td>
      <td align="right"><strong>217</strong></td>
      <td align="right"><strong>1.21×</strong></td>
    </tr>
    <tr>
      <td>Earlier messages (40)</td>
      <td align="right">283</td>
      <td align="right"><strong>275</strong></td>
      <td align="right"><strong>0.97×</strong></td>
    </tr>
    <tr>
      <td>Sidebar</td>
      <td align="right">294</td>
      <td align="right"><strong>644</strong></td>
      <td align="right"><strong>2.19×</strong></td>
    </tr>
    <tr>
      <td>Search (100 matches)</td>
      <td align="right">122</td>
      <td align="right"><strong>114</strong></td>
      <td align="right"><strong>0.93×</strong></td>
    </tr>
  </tbody>
</table>

<p align="center">
  <strong>83,659 successful requests · Zero errors</strong><br>
  Measured 2026-10-06 ·
  <a href="docs/performance.md#live-rails-and-roda-comparison">Detailed results &amp; methodology</a> ·
  <a href="bench/recorded/2026-10-06-erubi/">Recorded measurements</a>
</p>

---

A port of [37signals’ Campfire](https://github.com/basecamp/once-campfire) using **Roda + Sequel + Erubi**, with the original frontend and an independent Ruby renderer. **No ActiveSupport, Action View, Active Record or other Rails Ruby dependencies.**

The table compares the Rails and Roda framework stacks serving matching Campfire data and frontend controls. The benchmark includes the full message UI, editor page, reaction forms, avatars and menus. [Coverage and verification](docs/compatibility.md) describe the application behavior tested.

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

- Setup, invitations, authentication, CSRF, sign-in throttling, profile/avatar management, account logos, custom CSS and session-transfer QR codes.
- Open/private rooms, participant management, direct conversations, unread state, presence, typing indicators and live Turbo updates over WebSockets.
- Lexxy rich text, signed mentions/autocomplete, Open Graph previews, sound messages, replies, reactions, editing, deletion, search and history.
- File uploads/downloads, image thumbnails, video/PDF previews, media seeking and room authorization.
- Administration, bans/deactivation, bot keys and APIs, webhook text/file replies, durable delivery jobs, Web Push and PWA controls.
- Read-only import of Rails data, including attachments, avatars/logos and user mention tokens.

[Detailed compatibility](docs/compatibility.md) includes verification coverage, migration requirements and implementation differences. [Frontend provenance and licenses](THIRD_PARTY_NOTICES.md) identify the reused browser libraries.

## Architecture

`App` owns middleware and the route tree. Modules in `lib/campfire/routes/` handle request concerns and call `Service` for authorization and transactional writes. `Repository` owns Sequel datasets, pagination, search and bulk loading.

`UI::Engine` compiles Erubi templates into reusable Ruby methods. Frequently rendered messages and reactions use direct HTML with interpolated URLs. Small, independent helper modules handle forms, escaped attributes, rich content and other presentation needs. Presentation adapters wrap database rows; they do not persist or authorize. No Rails compatibility layer or standard-library monkey patches are used.

`Media`, `Tokens`, `API`, `Authentication`, `Delivery` and `Importer` have separate responsibilities. The realtime server implements the browser’s wire protocol with `websocket-driver`; SQLite events carry changes across Puma processes. Durable jobs keep outbound requests out of message writes.

Performance choices include indexed cursor pagination, bulk message/boost/file queries, FTS5 permission filtering before LIMIT, SQLite WAL and short write transactions. Templates compile once, while each response is rendered afresh. There are no benchmark-only routes, authentication shortcuts or response caches.

## Tests and benchmarks

```sh
bundle exec rake test
bundle exec ruby bench/seed.rb --output tmp/bench-seed
bundle exec ruby bench/message_hot_paths.rb --seed tmp/bench-seed
ruby bench/compare_http.rb --seed tmp/bench-seed --duration 10 --rounds 2
```

Validation: **68 tests / 511 assertions**, **83 live Rails/Roda checks**, **136 live frontend/WebSocket checks**, plus a successful desktop/mobile Chrome interaction audit. Checks cover full message structure and controls, named forms, writes/search updates, CSRF, ownership and private-room isolation. The Ruby suite also asserts that no Rails gems or ActiveSupport/Action View constants are loaded.

The final comparison uses 2,000 messages, 100 users, 20 rooms, 1,216 memberships and 400 boosts. Both apps use Ruby 4.0.2 with YJIT, one five-thread Puma and matching imported data. Rails keeps its production Redis cache; Roda renders without fragment caching. Four alternating rounds are retained, including timing variation. The supplied Rails HTTP client is unchanged.

See [measurements and methodology](docs/performance.md#live-rails-and-roda-comparison), [raw results](bench/recorded/2026-10-06-erubi/), and [reproduction instructions](bench/README.md#reproduce-the-recorded-rails-comparison). Earlier minimal-frontend measurements are preserved as [historical results](docs/performance-partial-port.md).

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

The importer opens the source read-only, preserves IDs/password hashes/memberships, sanitizes rich text, re-signs known user mentions, rebuilds FTS and copies original files. Existing Rails sessions and signed URLs do not carry over. Import rolls back on incompatible duplicates or missing files. Retain the original backup; unknown embedded object types render as missing attachments. See [migration details](docs/compatibility.md#migration-details).

## Production

Set a stable `SESSION_SECRET` of at least 64 random bytes and put Puma behind an HTTPS reverse proxy:

```sh
export SESSION_SECRET="$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')"
RACK_ENV=production HOST=127.0.0.1 PORT=9292 bundle exec puma -C config/puma.rb
```

Configuration: `DATABASE_PATH`, `UPLOAD_ROOT`, `HOST`, `PORT`, `MAX_THREADS` (5), `DB_POOL` (5), and `WEB_CONCURRENCY` (0). Use a pool at least as large as the thread count and local disk for SQLite/WAL. The reverse proxy must forward WebSocket upgrades and overwrite forwarded headers. Production cookies are secure; `DISABLE_SSL=true` is for deliberate local HTTP tests.

For Docker, set `SESSION_SECRET` and run `docker compose up --build`. The compose file binds port 9292 to loopback, persists data and starts the delivery worker. Docker deployment was not exercised in this workspace.

For Web Push, configure `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT` for both web and worker processes, then enable notifications in a supported HTTPS browser. The included tests use fake delivery transports; actual push-provider delivery and OS-level PWA installation require a configured device.

Webhook URLs are administrator-controlled and may target internal services, as in Campfire. Push subscriptions are restricted to the original provider allowlist and public IPs. Link previews reject private addresses and validate redirects. Outbound connections pin the checked IP while retaining TLS hostname validation.

Uploads are limited to 25 MB, message HTML to 100 KB, and passwords to 12–72 bytes. Sessions expire after 30 days. Jobs retry with backoff up to eight attempts; inspect `jobs` for exhausted attempts. Delivery is at-least-once, with deterministic bot reply IDs to avoid duplicates.

Back up SQLite through its backup API, alongside files and secrets. SQLite uses `synchronous=NORMAL`, so power failure can lose recent commits. Events and unattached files are retained; provide a retention policy for a long-lived installation.

## License

[MIT](MIT-LICENSE). Original Campfire code/assets and the reused benchmark client are copyright 37signals, LLC. See [third-party notices](THIRD_PARTY_NOTICES.md).
