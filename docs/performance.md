# Recorded performance

Measured locally on 2026-10-06 using Ruby 4.0.2 (`arm64-darwin25`), Roda 3.108.0, Sequel 5.109.0, and SQLite through sqlite3 2.9.6. Each endpoint received 20 warmups and 100 measured Rack requests. These are warm in-process measurements with normal authentication/CSRF and no application response cache. SQL instrumentation is included in timings and allocations.

| Workload | 2,000 messages, 100 users: median | 20,000 messages, 1,000 users: median | SQL queries/request |
| --- | ---: | ---: | ---: |
| Room (40 messages) | 1.097 ms | 1.295 ms | 9 |
| Earlier messages (40) | 0.658 ms | 0.646 ms | 6 |
| Sidebar | 0.426 ms | 0.720 ms | 4 |
| Search (100 matches) | 1.304 ms | 1.583 ms | 8 |
| Unread fanout to 1,000 synthetic recipients | 0.100 ms | 0.101 ms | 0 |

The small fixture allocated approximately 4,318 objects for room, 3,183 objects for messages, 1,567 objects for sidebar, 6,829 objects for search. Both fixtures have 12 open rooms, 8 direct conversations, and a boost on every fifth message. Half the messages contain “coffee.” The read benchmarks do not include downloading image/file assets, Web Push delivery, or background worker processing. The fanout row is a transport-free computation probe, not real-time delivery throughput.

Both probes were rerun after the final refactor and fixes, with YJIT disabled. [Small-fixture samples](../bench/recorded/2026-10-06/hot-paths.json) and [scale samples](../bench/recorded/2026-10-06/hot-paths-scale.json) include SQL counts, allocations, normalized body hashes, and response sizes.

## What improved

Profiling separated SQLite execution, row conversion, and HTML rendering. General timestamp parsing was the largest cost in this environment. `Database.connect` now converts the app's fixed UTC timestamp format directly, retaining the generic parser for explicit offsets and other legacy values. A regression test verifies microsecond precision and offset conversion.

Message loading uses one indexed, joined query for records/creators and two bulk queries for boosts/attachments. Tests assert the three-query presentation count is unchanged between one message and a full page, and that pagination uses the compound cursor index without a temporary sort. FTS queries walk newest matching row IDs and enforce membership before LIMIT. No benchmark-only response shortcut or authentication bypass is used.

Concurrent-write tests run five threads against file-backed SQLite, verifying a single direct room, all 50 committed messages, matching FTS records, and change-feed events. The full suite additionally checks permissions, cookie/CSRF behavior, imports, uploads, delivery retries, and public-address restrictions for push endpoints.

## Live Rails and Roda comparison

The final run followed the route refactor, sidebar/boost fixes, and timestamp-fixture correction. All **276,946 measured requests returned HTTP 200**, with **zero transport errors** across 64 measurement cases. The Roda suite passed **37 tests, 241 assertions**, and a separate live audit passed **54 checks**. Both temporary Puma servers and the temporary Redis instance shut down after the run.

The following are medians of four rounds. Latency columns are medians of each round's percentiles, not pooled percentiles. Throughput ratios use unrounded medians.

| Workload | Clients | Rails req/s | Roda req/s | Roda / Rails | p50 ms, Rails / Roda | p95 ms, Rails / Roda |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | 1 | 164 | 1,192 | 7.26× | 5.71 / 0.76 | 9.08 / 1.30 |
| Room (40 messages) | 16 | 128 | 1,333 | 10.38× | 127.74 / 11.55 | 190.42 / 14.26 |
| Earlier messages (40) | 1 | 227 | 1,716 | 7.57× | 3.64 / 0.51 | 7.76 / 1.05 |
| Earlier messages (40) | 16 | 247 | 2,061 | 8.35× | 60.69 / 7.47 | 97.89 / 9.74 |
| Sidebar | 1 | 247 | 2,308 | 9.33× | 3.86 / 0.38 | 5.41 / 0.70 |
| Sidebar | 16 | 265 | 2,600 | 9.81× | 57.88 / 5.67 | 76.29 / 8.68 |
| Search (100 matches) | 1 | 145 | 883 | 6.08× | 6.73 / 1.05 | 8.12 / 1.71 |
| Search (100 matches) | 16 | 108 | 932 | 8.65× | 140.87 / 16.46 | 197.04 / 21.85 |

| Workload | Rails response bytes | Roda response bytes |
| --- | ---: | ---: |
| Room (40 messages) | 456,091 | 31,131 |
| Earlier messages (40) | 424,623 | 26,575 |
| Sidebar | 39,617 | 2,542 |
| Search (100 matches) | 1,082,627 | 70,051 |

Roda sends 14.7–16.0× less HTML for these endpoints. This difference is part of the measured application behavior and contributes to the throughput comparison.

[Published evidence](../bench/recorded/2026-10-06/) includes all eight round result files, p99 latency, status counts, verification, runtime metadata, aggregate resource samples, and `summary.json`. Full logs and process samples remain locally in `bench/results/rails-vs-roda-20261006-011025/`. Local paths, ephemeral URLs, and fixture credentials are omitted from the published copies; measurements are unchanged. No round was discarded. Variability was substantial, especially the first Rails room case and the first Roda search case. Observed throughput ranges at 16 concurrent clients were:

| Workload | Rails req/s range | Roda req/s range |
| --- | ---: | ---: |
| Room (40 messages) | 46–184 | 1,204–1,385 |
| Earlier messages (40) | 149–260 | 1,855–2,136 |
| Sidebar | 251–288 | 2,174–2,752 |
| Search (100 matches) | 77–114 | 226–993 |

The comparison uses an Apple M4 with 10 physical cores and 16 GiB RAM, Ruby 4.0.2 with YJIT enabled for both servers and the HTTP client, and Puma 7.2.1 in single-process mode with five threads and five database connections. Both use Rack 3.2.7 and sqlite3 2.9.6. Rails 8.2.0.alpha retains its production Redis cache; Roda has no response cache. Redis 8.6.2 runs as a dedicated temporary instance. All servers bind only to `127.0.0.1`.

The Rails application is the supplied source at `d2155e85a01b8439c32a3604ebb7f39fea1ace0f`, with locked Rails revision `1a02651ac37f`. An isolated copy preloads `ruby-vips` before the source's image-security initializer, retaining its libvips operation restrictions. Assets are precompiled, SSL is disabled for loopback HTTP, and telemetry is disabled. The original reference source is not edited.

The fixture contains 2,000 messages, 100 users, 20 rooms, 1,216 memberships, and 400 boosts, with no message attachments. The synthetic fixture is represented in the Rails schema with Action Text bodies and an FTS index, then imported back through the Roda importer. Whole-second timestamps use Active Record's native representation without a `.000000` suffix; otherwise SQLite's text comparison would incorrectly include the anchor in Rails' after-pagination. Verification compares every row in eight imported application tables with the original fixture. HTTP checks additionally assert identical expected message IDs: 40 newest room messages, 40 earlier messages, and 100 search matches.

Before timing, a separate run passed [54 live behavior checks](../bench/recorded/2026-10-06/parity.json) for message content/formatting/authors/timestamps/boosts, both pagination directions, permalinks, sidebars, edits/deletes/search updates, CSRF, ownership, and private-room isolation. That run uses the same runtime file digest as the benchmark. Its mutations are isolated from the fresh timing fixture. See the [compatibility report](compatibility.md#what-was-checked-against-live-rails) for exact scope, fixes, and remaining differences.

Each application receives five seconds of initial warmup per endpoint, followed by four measurement rounds. Each endpoint receives another three-second warmup before five-second measurements at concurrency 1 and 16. Application order alternates Roda/Rails, Rails/Roda, Roda/Rails, Rails/Roda. Login and CSRF protection remain enabled. Clients use keep-alive, request uncompressed HTML, consume full response bodies, and reject any non-200 response or transport error. The servers remain running between rounds with warm caches; fixtures are isolated from normal application storage.

The preparation, verification, and process-cleanup harness is published at [`bench/rails/run.rb`](../bench/rails/run.rb). Run `ruby bench/rails/run.rb` with both locked bundles installed, libvips, Redis, and a benchmark seed. [Reproduction instructions](../bench/README.md#reproduce-the-recorded-rails-comparison) include the separate behavior audit. No application code changes during the timed rounds. The supplied Rails HTTP client is reused byte-for-byte, SHA-256 `951d2be90a06b0f124e70e1d5abaad15a70c04427cc6389d281769bfe4f6c0bb`.

One-second `ps` samples recorded peak RSS of 474.5 MiB for Rails, 105.8 MiB for Roda, 6.5 MiB for Redis, 293.0 MiB for the client. Sampled peak CPU was 113.6%, 99.9%, 1.7%, 13.7%, respectively, where 100% represents one core. These coarse samples do not show sustained client CPU saturation and are not allocation profiles.

## Measurement limits

These measurements compare shared text-reading workloads in two application implementations serving the same records. Roda is a partial port: the editor, media processing, Action Text objects, live-update transport, and UI differ from Rails. Its frontend markup and response sizes are substantially smaller. Throughput ratios therefore combine implementation efficiency with different rendering/features; they do not isolate framework overhead or establish full feature parity. Browser rendering, asset downloads, TLS, compression, write throughput, Web Push, and background jobs are excluded. The functional audit tests some writes but does not benchmark them. CPU affinity is not enforced on macOS, and servers and client share the machine; scheduling, other local activity, and client CPU can affect results. The five-second cases and observed variability limit precision. HTML routes also have Rack integration tests; this run does not establish browser UI equivalence.

Use `bench/import_rails_seed.rb` plus a separately running Rails baseline to compare equivalent fixture data. See [the benchmark instructions](../bench/README.md). Keep hardware, Ruby/JIT settings, CPU allocation, fixture contents, and concurrency consistent when comparing implementations.
