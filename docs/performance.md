# Recorded performance

## Live Rails and Roda comparison

**Rails (Active Record + Action View) versus Roda (Sequel + Erubi), with the original Campfire frontend and matching data.** Measured on 2026-10-06 after the full frontend port and native template refactor.

All **83,659 measured requests returned HTTP 200**, with zero transport errors. The table uses medians of four alternating rounds; ratios use unrounded medians. Latency columns are medians of per-round percentiles, not pooled percentiles.

| Workload | Clients | Rails req/s | Roda req/s | Roda / Rails | p50 ms, Rails / Roda | p95 ms, Rails / Roda |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | 1 | 203 | 203 | 1.00× | 4.77 / 4.69 | 6.13 / 6.32 |
| Room (40 messages) | 16 | 179 | 217 | 1.21× | 86.92 / 71.68 | 111.92 / 88.01 |
| Earlier messages (40) | 1 | 366 | 235 | 0.64× | 2.63 / 4.03 | 3.41 / 5.84 |
| Earlier messages (40) | 16 | 283 | 275 | 0.97× | 52.61 / 57.29 | 83.84 / 66.05 |
| Sidebar | 1 | 282 | 614 | 2.17× | 3.40 / 1.54 | 4.45 / 2.35 |
| Sidebar | 16 | 294 | 644 | 2.19× | 53.29 / 24.67 | 64.83 / 27.25 |
| Search (100 matches) | 1 | 154 | 110 | 0.71× | 6.42 / 8.86 | 7.58 / 10.50 |
| Search (100 matches) | 16 | 122 | 114 | 0.93× | 128.07 / 138.85 | 150.36 / 155.62 |

| Workload | Rails response bytes | Roda response bytes | Rails req/s range, 16 clients | Roda req/s range, 16 clients |
| --- | ---: | ---: | ---: | ---: |
| Room (40 messages) | 457,915 | 442,317 | 92–203 | 160–235 |
| Earlier messages (40) | 424,623 | 417,039 | 265–313 | 236–288 |
| Sidebar | 41,441 | 33,354 | 233–312 | 592–708 |
| Search (100 matches) | 1,084,451 | 1,057,763 | 104–131 | 103–117 |

The full frontend has changed the comparison substantially. The previous 8–10× figures came from a much smaller, minimal renderer. They are retained only in the [historical report](performance-partial-port.md). The current table includes all workloads and every round, including cases where Rails is faster.

## Matched workload and verification

Both apps serve 40 room messages, 40 earlier messages, the same sidebar records and 100 search matches from equivalent fixtures: 2,000 messages, 100 users, 20 rooms, 1,216 memberships and 400 boosts. The timed fixture has no attachments. Each message includes the original actions, eight reaction forms, avatars, boost controls and Turbo frames. Roda renders these independently with Erubi. Whitespace, signed URLs, generated attributes and asset-loading tags account for remaining byte differences.

Before timing, a separate disposable run passed **83 differential HTTP checks**. These compare content, message element counts, frontend actions, reaction values, Turbo frame IDs, form fields, autocomplete, PWA endpoints, writes, search updates, ownership, CSRF and private-room isolation. The audit and benchmark have identical recorded runtime digests. See [coverage](compatibility.md) and the [individual checks](../bench/recorded/2026-10-06-erubi/parity.json).

The Ruby suite passed **68 tests / 511 assertions**. Additional validation includes **136 live asset/WebSocket checks** and desktop/mobile Chrome interaction checks. Real push-provider delivery, OS-level PWA installation and other browser engines were not exercised.

## Method

- Apple M4, 10 physical cores, 16 GiB RAM; macOS arm64. Servers and HTTP client use Ruby 4.0.2 with YJIT.
- Puma 7.2.1, one process, five threads, five database connections; Rack 3.2.7 and sqlite3 2.9.6 for both apps.
- Rails 8.2.0.alpha at `1a02651ac37f`; Campfire source `d2155e85a01b8439c32a3604ebb7f39fea1ace0f`. Roda 3.108.0, Sequel 5.109.0 and Erubi 1.13.1.
- Rails retains its normal production Redis cache (Redis 8.6.2). Roda compiles templates once but uses no response or fragment cache. No benchmark-specific application behavior or authentication bypass.
- Five seconds of initial warmup per endpoint/app. Four rounds alternate Roda/Rails, Rails/Roda, Roda/Rails, Rails/Roda. Each endpoint gets another three-second warmup before five-second measurements at one and sixteen clients.
- Persistent loopback HTTP connections, uncompressed responses, full body consumption, normal login and CSRF. Any transport error or non-200 result fails the measurement.
- The supplied Rails HTTP client is unchanged: SHA-256 `951d2be90a06b0f124e70e1d5abaad15a70c04427cc6389d281769bfe4f6c0bb`.

The harness copies the clean Rails checkout into a disposable directory, including vendor JavaScript, and precompiles assets. It loads libvips before the reference initializer that requires it, retaining the image-security restrictions. SSL and telemetry are disabled only in the loopback benchmark. Rails data is imported into Roda and all rows in eight fixture tables are compared. The original checkout and normal application storage remain unchanged. Whole-second timestamps use Active Record’s serialization without a synthetic `.000000` suffix.

No application code changed during timed rounds. Browser tests and the preview server were stopped before measurement. Every round is published, so startup/JIT effects and local timing variation are visible.

## Resource samples

One-second process samples report the following maxima. CPU percentages use 100% for one core; these are coarse peaks, not sustained utilization or allocation profiles.

| Process | Peak CPU | Peak RSS |
| --- | ---: | ---: |
| Rails | 123.2% | 443.3 MiB |
| Roda | 101.5% | 254.5 MiB |
| Redis | 1.8% | 6.1 MiB |
| Client | 9.7% | 415.8 MiB |

## Reproduce and interpret

[Reproduction commands](../bench/README.md#reproduce-the-recorded-rails-comparison) run `bench/rails/run.rb` and `bench/rails/summarize.rb`. [Published evidence](../bench/recorded/2026-10-06-erubi/) includes all eight round files, p99 values, counts, verification, runtime metadata and the live audit. Local paths, temporary server URLs and fixture credentials are removed from published copies; measurements are unchanged. Full logs/process samples remain locally in `bench/results/rails-vs-roda-20261006-024502/`.

Runtime metadata lists the files used for the SHA-256 digest. The hidden asset manifest has a separate recorded SHA-256. To reproduce the runtime digest, append each listed relative filename, a NUL, its file bytes and a NUL, in the recorded order.

These results compare the two framework stacks in this Campfire application and configuration. They include routing, authentication, queries, rich-text processing and template rendering. They do not separately attribute time to each library. Browser rendering, asset downloads, TLS/compression, write throughput, media processing, WebSockets and delivery jobs are outside the timed read workloads. Five-second samples, shared hardware and the absence of CPU affinity on macOS limit precision; the ranges should be read alongside the medians.

The independent in-process probe records query counts and allocations for profiling. It is not a substitute for HTTP throughput, and the transport-free unread-fanout probe is not a network-delivery benchmark.
