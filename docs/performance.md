# Recorded performance, 2026-10-08 (UTC)

## Live Rails and Roda comparison

Roda exceeded the 2× target on the five main application paths: **3.69–4.93× Rails for reads and 2.26× for posting**. Rails was faster on avatars and static CSS. These are complete production applications on the shared verification fixture, with production caching enabled and one logged-in user issuing repeated requests.

All **10,304,242 timed responses** across eight routes passed their contracts, with zero transport errors or invalid responses. This includes **23,285 timed message posts**; **27,757 acknowledged writes including warmups** were verified against persisted IDs, exact request tokens in stored bodies, room and FTS entries. Every round passed its database integrity and write audits.

Each number is the median of four alternating eight-second rounds at sixteen clients. Ratios use unrounded medians. Latencies are medians of per-round percentiles, not pooled percentiles. [Every round and range](../bench/recorded/2026-10-08-shared/README.md) is retained in a concise table.

| Workload | Rails req/s | Roda req/s | Roda / Rails | p50 ms, Rails / Roda | p99 ms, Rails / Roda |
| --- | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | 3,886.7 | 14,353.5 | 3.69× | 3.78 / 0.94 | 10.50 / 3.63 |
| Earlier messages (40) | 3,738.8 | 16,663.2 | 4.46× | 3.87 / 0.83 | 11.42 / 2.99 |
| Sidebar | 3,907.4 | 19,258.5 | 4.93× | 3.65 / 0.72 | 11.93 / 2.53 |
| Search (13 matches) | 4,147.1 | 19,080.0 | 4.60× | 3.55 / 0.72 | 9.59 / 2.56 |
| Post message | 222.8 | 502.4 | 2.26× | 56.40 / 17.32 | 243.65 / 204.22 |
| Avatar | 52,749.1 | 5,035.1 | 0.10× | 0.20 / 3.04 | 1.24 / 6.39 |
| Static CSS | 82,132.5 | 35,945.2 | 0.44× | 0.14 / 0.40 | 0.92 / 1.23 |
| Health check | 5,588.5 | 55,235.4 | 9.88× | 2.60 / 0.27 | 7.53 / 0.74 |

## Reads with concurrent writes

The same images also ran four rounds of each read route with sixteen read clients and one separate writer paced at a maximum of ten messages per second. The writer posts to another room: this exercises database-wide response invalidation and ongoing background work, while keeping the expected read windows stable. It does not measure a room being posted to and read concurrently.

All **2,054,276 timed reads** and **2,543 timed writer responses** passed. Including warmups, all **3,173 acknowledged writes** passed persistence audits. The timed writer completed 1,267 posts on Rails and 1,276 on Roda; individual sample rates were 9.5–10.0/s. The pacing limit is a ceiling with no catch-up bursts.

| Workload | Rails req/s | Roda req/s | Roda / Rails | p50 ms, Rails / Roda | p99 ms, Rails / Roda |
| --- | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | 1,729.7 | 11,172.5 | 6.46× | 4.34 / 0.97 | 103.97 / 11.45 |
| Earlier messages (40) | 2,270.2 | 13,242.2 | 5.83× | 4.19 / 0.84 | 66.30 / 9.97 |
| Sidebar | 3,104.2 | 15,428.3 | 4.97× | 3.94 / 0.74 | 25.69 / 8.07 |
| Search (13 matches) | 2,882.8 | 14,466.0 | 5.02× | 4.01 / 0.75 | 38.50 / 9.68 |

## Matched workload and validation

The shared fixture starts with 169 messages, 10 users, 11 rooms, 39 memberships, 12 boosts and 14 Active Storage attachments. It serves 40 room messages, 40 earlier messages and 13 search matches, with the original editor, actions, reactions, avatars, menus and Turbo controls. It was generated from pinned Rails revision `90b330024dec3e757c79b6a7e6568f93da8e3148`; the servers themselves use the latest pinned application source below.

Read expectations come from SQL against the common Rails fixture **before Roda imports it**, independently of either server's responses. The unchanged Rust client validates every measured response, consumes/decompresses full bodies and checks ordered message windows and seeded content. Preflight decodes actual avatar pixels. The harness also checks every acknowledged write and database integrity after each app/round; invalid results abort the comparison.

Both disposable runtimes receive the same two fixture normalizations: outbound URLs point to a loopback discard endpoint, and orphaned message creators receive disabled placeholder users. All original messages are preserved, and Roda's foreign keys remain enabled. The original seed checksum is verified again after each comparison. No fixture credentials or raw receipts are published.

The current application passes 134 native tests on macOS Ruby 4.0.2 (844 assertions) and Linux Ruby 4.0.7 (842 assertions), with zero failures/errors and respectively one/two unavailable libvips-loader skips. Shared harness checks and Chromium flows pass, plus 136 native HTTP/WebSocket checks and 11 desktop/mobile Chrome checks. [Coverage](compatibility.md) and [the upstream update audit](upstream-update.md) describe the regression checks and limits. The older 83-check differential audit is dated 2026-10-06; it is not claimed as a new run against this revision.

## Method and interpretation

- Apple M4 host, 10 CPU cores and 16 GiB RAM; macOS arm64 with Docker Desktop allocated 10 virtual CPUs and about 8 GiB. Linux production containers use Ruby 4.0.7, Puma 8.0.2 and YJIT, with three Puma workers and five threads each.
- Servers are pinned to virtual CPUs 0–3; the unchanged Rust client runs in a separate container on 4–7, sharing the server's network namespace. The orchestrator runs on the host. No Docker socket or entire workspace is mounted in a container.
- Rails uses its upstream production image, Thruster and Redis/Resque. Roda uses its production Puma, native WebSocket implementation and SQLite delivery worker. These are application-stack results, including their different HTTP/asset-serving arrangements.
- Roda's response/row cache and fragment cache each have a 64 MiB payload budget per worker. Responses invalidate on committed database changes, while content fragments depend on actual rendered values. Session expiry and room access are checked before reuse. Rails retains its upstream caches. Cache limits are not total process-memory limits.
- Each app/round starts from a fresh fixture copy and normal login. After readiness, the harness waits three seconds; every endpoint then receives a two-second warmup with four clients before the eight-second timed sample at sixteen clients. The order is Rails/Roda, Roda/Rails, Rails/Roda, Roda/Rails. All four rounds are included.
- Every client requests gzip. Actual response encodings are preserved: both apps compress HTML reads; Rails' proxy also compresses the sampled assets/health response, while Roda serves those directly. Bodies and variant sizes can differ without failing the shared content contract. Representative byte counts are in the recorded table.
- Application code and image IDs remained fixed across both final comparisons. Browser/test servers and other test work were stopped during timing. The previous confirmation run is retained locally; an earlier incomplete run stopped after unequal YJIT defaults were discovered is excluded. Both final apps explicitly enable YJIT.

This is a small, hot fixture and a repeated-user workload. It does not establish cold-cache or large multi-user throughput. Docker Desktop bind-mounted SQLite I/O affects absolute write performance; the CPU sets share one host. Load-generator CPU was not measured in this container layout, so client limits cannot be ruled out at the highest rates. No CPU-efficiency or memory-saving claim is made. Eight-second samples and four rounds show local variation, not a statistical confidence interval.

Browser rendering, upload/preview throughput, live WebSocket fanout, real push-provider delivery and OS-level PWA installation are outside these timed workloads. The shared browser flow and native regression suite provide useful coverage, not an exhaustive proof of equivalence for every possible input.

## Reproduce and provenance

```sh
ruby bin/benchmark --prepare --rounds 4 --duration 8
ruby bin/benchmark --rounds 4 --duration 8 --mixed-write-rate 10
```

The default comparison is Rails versus Roda only. See [requirements and options](../bench/verification/README.md). Source pins, runtime fingerprints, image IDs, client/fixture/adapter hashes and every round are in [the recorded comparison](../bench/recorded/2026-10-08-shared/README.md). Raw receipts remain under ignored `tmp/once-campfire-verification/tmp/bench/results/roda-production-fingerprinted-20261008/` and `roda-mixed-fingerprinted-20261008/`.

The [2026-10-06 cluster comparison](performance-2026-10-06.md), [single-process comparison](performance-single-process.md) and [minimal-frontend report](performance-partial-port.md) use different fixtures and clients and are historical. Their ratios should not be read as a controlled before/after measurement of this update.
