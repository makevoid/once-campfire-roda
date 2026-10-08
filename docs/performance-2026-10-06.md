# Historical performance, 2026-10-06

This report describes the earlier application, fixture and Ruby load generator. Its cache, runtime and coverage statements apply to that revision. See [the current shared-harness comparison](performance.md) for the updated application and measured writes.

## Live Rails and Roda comparison

**Rails (Active Record + Action View) versus Roda (Sequel + Erubi), with the original Campfire frontend and matching data.** Measured on 2026-10-06 with matching eight-worker Puma clusters after [Puma tuning](puma-tuning.md).

All **390,008 measured requests returned HTTP 200**, with zero transport errors. The table uses medians of four alternating rounds; ratios use unrounded medians. Latency columns are medians of per-round percentiles, not pooled percentiles.

| Workload | Clients | Rails req/s | Roda req/s | Roda / Rails | p50 ms, Rails / Roda | p95 ms, Rails / Roda |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | 16 | 738 | 1,235 | 1.67× | 21.09 / 12.14 | 28.90 / 23.46 |
| Room (40 messages) | 64 | 725 | 1,221 | 1.69× | 85.11 / 50.74 | 118.85 / 82.12 |
| Earlier messages (40) | 16 | 1,075 | 1,492 | 1.39× | 14.72 / 9.99 | 24.10 / 19.24 |
| Earlier messages (40) | 64 | 1,014 | 1,538 | 1.52× | 61.07 / 41.05 | 87.68 / 60.02 |
| Sidebar | 16 | 969 | 3,081 | 3.18× | 16.02 / 4.86 | 24.69 / 8.97 |
| Sidebar | 64 | 969 | 3,174 | 3.28× | 66.76 / 19.76 | 92.38 / 28.23 |
| Search (100 matches) | 16 | 505 | 683 | 1.35× | 30.84 / 22.22 | 48.66 / 35.27 |
| Search (100 matches) | 64 | 476 | 701 | 1.47× | 131.57 / 89.58 | 180.92 / 136.09 |

| Workload | Rails response bytes | Roda response bytes | Rails req/s range, 64 clients | Roda req/s range, 64 clients |
| --- | ---: | ---: | ---: | ---: |
| Room (40 messages) | 457,915 | 442,317 | 691–736 | 920–1302 |
| Earlier messages (40) | 424,623 | 417,039 | 1004–1041 | 1464–1577 |
| Sidebar | 41,441 | 33,354 | 791–986 | 2914–3225 |
| Search (100 matches) | 1,084,451 | 1,057,763 | 410–492 | 637–708 |

The [previous single-process comparison](performance-single-process.md) and [renderer profiling](renderer-optimization.md) remain available. The current table uses eight Puma workers per app and two load-generator processes.

The full frontend has changed the comparison substantially. The previous 8–10× figures came from a much smaller, minimal renderer. They are retained only in the [historical report](performance-partial-port.md). The current table includes all workloads and every round, without excluding slower or noisy rounds.

## Matched workload and verification

Both apps serve 40 room messages, 40 earlier messages, the same sidebar records and 100 search matches from equivalent fixtures: 2,000 messages, 100 users, 20 rooms, 1,216 memberships and 400 boosts. The timed fixture has no attachments. Each message includes the original actions, eight reaction forms, avatars, boost controls and Turbo frames. Roda renders these independently with Erubi. Whitespace, signed URLs, generated attributes and asset-loading tags account for remaining byte differences.

Before timing, a separate disposable run passed **83 differential HTTP checks**. These compare content, message element counts, frontend actions, reaction values, Turbo frame IDs, form fields, autocomplete, PWA endpoints, writes, search updates, ownership, CSRF and private-room isolation. The audit and benchmark have identical recorded runtime digests. See [coverage](compatibility.md) and the [individual checks](../bench/recorded/2026-10-06-puma-cluster/parity.json).

The Ruby suite passed **74 tests / 557 assertions**. The same eight-worker Roda setup passed **136 live asset/WebSocket checks**. The preceding frontend port also passed desktop/mobile Chrome interaction checks. The new tests cover database disconnection before forking, two child processes writing through independent connections, multi-process load-generator aggregation/error propagation, and disjoint process resource accounting. Real push-provider delivery, OS-level PWA installation and other browser engines were not exercised.

## Method

- Apple M4, 10 physical cores, 16 GiB RAM; macOS arm64. Servers and HTTP client use Ruby 4.0.2 with YJIT.
- Puma 7.2.1, eight worker processes plus a master per app, two threads and two database connections per worker; Rack 3.2.7 and sqlite3 2.9.6 for both apps.
- Rails 8.2.0.alpha at `1a02651ac37f`; Campfire source `d2155e85a01b8439c32a3604ebb7f39fea1ace0f`. Roda 3.108.0, Sequel 5.109.0 and Erubi 1.13.1.
- Rails retains its normal production Redis cache (Redis 8.6.2). Roda compiles templates once but uses no response or fragment cache. No benchmark-specific application behavior or authentication bypass.
- Five seconds of initial warmup per endpoint/app at 64 clients, split across two client processes. Both apps preload, then disconnect database connections before forking. Four rounds alternate Roda/Rails, Rails/Roda, Roda/Rails, Rails/Roda. Each endpoint gets another three-second warmup before five-second measurements at sixteen and sixty-four total clients. Per-path warmup also uses 64 clients.
- Two Ruby load-generator processes split the total client concurrency, start together and pool raw request latencies for percentiles. Aggregate throughput counts all completed requests over shared elapsed time, including result transfer. Persistent loopback HTTP connections, uncompressed responses, full body consumption, normal login and CSRF. Any transport error or non-200 result fails the measurement.
- The supplied Rails HTTP client is unchanged: SHA-256 `951d2be90a06b0f124e70e1d5abaad15a70c04427cc6389d281769bfe4f6c0bb`.

The harness copies the clean Rails checkout into a disposable directory, including vendor JavaScript, and precompiles assets. It loads libvips before the reference initializer that requires it, retaining the image-security restrictions. SSL and telemetry are disabled only in the loopback benchmark. Rails data is imported into Roda and all rows in eight fixture tables are compared. The original checkout and normal application storage remain unchanged. Whole-second timestamps use Active Record’s serialization without a synthetic `.000000` suffix.

No application code changed during timed rounds. Browser tests and the preview server were stopped before measurement. Every round is published, so startup/JIT effects and local timing variation are visible.

## Resource samples

One-second samples sum each server’s master and worker processes, and all load-generator processes. CPU percentages use 100% for one core. Summed RSS counts shared copy-on-write pages in each process, so it is not unique physical memory use. These are coarse peaks, not sustained utilization or allocation profiles.

| Process group | Peak aggregate CPU | Peak summed RSS |
| --- | ---: | ---: |
| Rails | 805.3% | 2556.3 MiB |
| Roda | 780.7% | 1360.1 MiB |
| Redis | 8.5% | 7.4 MiB |
| Client | 86.7% | 638.7 MiB |

## Reproduce and interpret

[Reproduction commands](../bench/README.md#reproduce-the-recorded-rails-comparison) run `bench/rails/run.rb` and `bench/rails/summarize.rb`. [Published evidence](../bench/recorded/2026-10-06-puma-cluster/) includes all eight round files, p99 values, counts, verification, runtime metadata and the live audit. Local paths, temporary server URLs and fixture credentials are removed from published copies; measurements are unchanged. Full logs/process samples remain locally in `bench/results/rails-vs-roda-20261006-064133/`.

Runtime metadata lists the files used for the SHA-256 digest. The hidden asset manifest has a separate recorded SHA-256. To reproduce the runtime digest, append each listed relative filename, a NUL, its file bytes and a NUL, in the recorded order.

These results compare the two framework stacks in this Campfire application and configuration. They include routing, authentication, queries, rich-text processing and template rendering. They do not separately attribute time to each library. Browser rendering, asset downloads, TLS/compression, write throughput, media processing, WebSockets and delivery jobs are outside the timed read workloads. Five-second samples, shared hardware and the absence of CPU affinity on macOS limit precision; the ranges should be read alongside the medians.

The independent in-process probe records query counts and allocations for profiling. It is not a substitute for HTTP throughput, and the transport-free unread-fanout probe is not a network-delivery benchmark.
