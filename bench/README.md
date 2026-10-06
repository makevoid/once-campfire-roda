# Benchmarks

These exercise the same four HTTP paths as `tmp/once-campfire/bench`, plus the unread fanout computation. `http_client.rb` is copied unchanged from that source. The original Docker comparison scripts are Rails-specific (Rails runner, compiled assets, Action Cable, Redis); the drivers here adapt the workload to Roda.

```sh
bundle exec ruby bench/seed.rb --output tmp/bench-seed --messages 2000 --users 100
bundle exec ruby bench/message_hot_paths.rb --seed tmp/bench-seed --iterations 100
ruby bench/compare_http.rb --seed tmp/bench-seed --duration 10 --warmup 5 --rounds 2
```

The seed command refuses to overwrite an existing database. The two runners snapshot SQLite, including committed WAL data, into temporary directories. Seed credentials are fixture-only and listed in `labels.json`; never expose the fixture server publicly.

## In-process probe

`message_hot_paths.rb` runs the actual Rack application with login and CSRF enabled. It records individual wall times, SQL counts, allocations, response bytes, and response SHA-256 fingerprints. Only randomized CSRF token and CSP nonce values are normalized for fingerprint stability. It performs 20 warmup requests per path. There is no application cache to distinguish a cold/warm mode; these results describe warm Ruby and SQLite operation.

The fanout probe encodes `{roomId: id}` once and emits it to 1,000 private stream names through a capturing adapter. It measures **fanout computation only**, not Web Push, polling, Redis, or network delivery. The production implementation uses authenticated WebSockets backed by SQLite events, plus a background delivery queue.

The [renderer optimization report](../docs/renderer-optimization.md) includes component timings, before/after allocations, identical-output checks and a separate HTTP comparison against the previous Roda revision. Its recorded evidence also includes the temporary profiling drivers used.

## HTTP load

By default `compare_http.rb` starts an isolated production Puma process on a random loopback port, with five threads, no cluster workers, a five-connection pool, and normal session/CSRF checks. It stops only the child server it started. Each client uses a persistent connection, disables compression, and consumes the response body. Warmup and measured requests must all be HTTP 200 without transport errors.

Server options include `--workers`, `--threads`, and `--db-pool`. `--warmup-concurrency` warms multiple workers, and `--client-processes` divides the total client concurrency across Ruby processes while using the unchanged request client. It pools raw latency samples before calculating percentiles; startup is synchronized and elapsed time includes result transfer to the parent.

Options include `--paths room,messages,sidebar,search`, `--concurrencies 1,16`, `--duration`, `--warmup`, `--rounds` (positive/even), and `--output`. Use `--url` to measure a server you already started instead; the supplied fixture credentials must work on that server.

For a live comparison with a separately running Rails baseline:

```sh
bundle exec ruby bench/import_rails_seed.rb \
  --database /path/to/rails-fixture/db/production.sqlite3 \
  --labels /path/to/rails-fixture/labels.json \
  --storage /path/to/rails-fixture/storage \
  --output tmp/bench-matching-rails
ruby bench/compare_http.rb --seed tmp/bench-matching-rails \
  --baseline-url http://127.0.0.1:3000 \
  --baseline-labels /path/to/rails-fixture/labels.json \
  --duration 10 --warmup 5 --rounds 4
```

This alternates baseline/Roda order each round and records response size, requests/sec, p50/p95/p99, errors, and statuses. It does not provision/reset a Rails server. For a fair comparison, prepare equivalent data, run both on the same machine with matching server/client CPU allocations and Ruby/JIT settings, and keep other traffic off both servers. The request client can become CPU-bound; report that alongside results.

The original frontend is ported to native Erubi templates. The HTML is not byte-identical: independent helpers, signed URLs, whitespace and CSRF values differ. The live audit compares message element counts, frontend actions, reaction forms and frame IDs as well as content and authorization. Compare response sizes as well as raw throughput. Do not compare local numbers to the upstream README's different hardware as if they were a controlled experiment. Neither a Rack timing nor its reciprocal is a measured HTTP throughput result.

JSON files default to ignored `bench/results/`. The implementation's SQL/index/concurrency invariants also run under `bundle exec rake test`.

## Reproduce the recorded Rails comparison

The checked-in [`rails/run.rb`](rails/run.rb) provisions disposable Rails/Roda databases, production Puma servers, and a dedicated Redis process. Install Ruby 4.0, Redis (`redis-server` on `PATH`), libvips, FFmpeg, Poppler, and both locked bundles first. Run from this repository with the desired Ruby on `PATH`; use plain `ruby` for the orchestrator so it can select each app's bundle independently.

```sh
bundle config set --local path vendor/bundle
bundle install
git clone https://github.com/basecamp/once-campfire.git tmp/once-campfire
git -C tmp/once-campfire checkout d2155e85a01b8439c32a3604ebb7f39fea1ace0f
(cd tmp/once-campfire && BUNDLE_PATH=vendor/bundle BUNDLE_FROZEN=true BUNDLE_WITHOUT=development:test bundle install)
bundle exec ruby bench/seed.rb --output tmp/bench-seed

# Mutating semantic audit on its own disposable fixture:
BENCH_WORKERS=8 BENCH_THREADS=2 BENCH_CLIENT_PROCESSES=2 BENCH_PARITY=1 ruby bench/rails/run.rb

# Fresh fixtures; 4 rounds, 5 seconds/case, 3 seconds/path warmup:
BENCH_WORKERS=8 BENCH_THREADS=2 BENCH_CLIENT_PROCESSES=2 ruby bench/rails/run.rb
ruby bench/rails/summarize.rb bench/results/rails-vs-roda-<timestamp>
```

If the seed or checkout already exists, reuse it instead of recreating it. `RAILS_SOURCE` and `BENCH_SEED` override their paths; `REDIS_SERVER` overrides the Redis executable. `BENCH_ROUNDS` (positive/even), `BENCH_DURATION`, `BENCH_WARMUP`, and `BENCH_PREWARM` override timing defaults. Install the Rails bundle in its source checkout's `vendor/bundle` and the Roda bundle in this repository's `vendor/bundle`.

`BENCH_WORKERS` accepts an integer or `auto` (available CPUs minus two, falling back to single mode). `BENCH_THREADS` sets both apps’ per-worker thread and database-pool sizes. `BENCH_CONCURRENCIES` defaults to `16,64` in cluster mode and `1,16` in single mode. `BENCH_WARMUP_CONCURRENCY` defaults to the largest measured concurrency for clusters; this warms all workers rather than only one persistent connection. `BENCH_CLIENT_PROCESSES=2` avoids a single Ruby load-generator process becoming the limit. The original one-process benchmark remains reproducible with `BENCH_WORKERS=0 BENCH_THREADS=5 BENCH_CLIENT_PROCESSES=1`.

The harness leaves the source checkout untouched, precompiles assets in a temporary copy, and preloads `ruby-vips` before the source image-security initializer. It uses native Active Record timestamp serialization, imports the Rails data through the Roda importer, compares all rows in eight fixture tables, and checks expected rendered message IDs before timing. The separate semantic audit also runs the Roda frontend/HTTP/WebSocket audit against the configured Puma cluster. It compares text, formatting, authors, times, boosts, DOM structure and controls, forms, sidebars, autocomplete, PWA endpoints, writes, search updates, and access controls. Audit mutations never enter the timing fixture. All processes bind to loopback and are stopped on completion or failure.

Results include runtime/source metadata, a digest of Roda's runtime files, all round measurements, verification, server logs, and one-second resource samples including each server’s master and worker descendants. Summed RSS counts shared copy-on-write pages in each process and is not unique physical memory usage. The local Rails source is required only for this comparison, not for running the Roda app or its unit tests. The full audit is not included in ordinary CI because it requires both applications, libvips, and Redis.

The current comparison is documented in [recorded performance](../docs/performance.md#live-rails-and-roda-comparison). The earlier partial-port results remain in `recorded/2026-10-06/` as historical evidence and are not the current frontend's results.

## Browser and WebSocket audits

Start a Puma server against a disposable seed (never the normal application database):

```sh
DATABASE_PATH=tmp/bench-seed/campfire.sqlite3 UPLOAD_ROOT=tmp/bench-seed/files PORT=9396 bundle exec puma -C config/puma.rb
```

In another terminal:

```sh
bundle exec ruby bench/verify_frontend.rb tmp/bench-seed/labels.json
npm install --prefix tmp/browser-audit --no-audit --no-fund playwright-core
node bench/verify_browser.mjs tmp/bench-seed/labels.json
```

The browser audit uses an installed Chrome executable. `CHROME_PATH`, `BASE_URL`, `PLAYWRIGHT_PATH` and `BROWSER_OUTPUT` override its paths. Browser tooling stays under `tmp`; it is not an application dependency. Both scripts require the disposable fixture marker and loopback HTTP. Browser reports and desktop/mobile screenshots are saved under `tmp/browser-audit/results`.
