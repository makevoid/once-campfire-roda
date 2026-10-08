# Shared Rails/Roda comparison, 2026-10-08 (UTC)

Four alternating rounds, eight seconds each, sixteen clients. All results passed response contracts and persisted-write audits. See [method, latency tables and limits](../../../docs/performance.md) and [reproduction commands](../../verification/README.md). Throughput is requests per second; all rounds are included. Raw results and fixtures stay ignored.

## Production routes

10,304,242 valid timed responses, including 23,285 timed posts. All 27,757 acknowledged writes including warmups verified. Zero invalid responses or transport errors.

| Workload | App | Round 1 | Round 2 | Round 3 | Round 4 | Median | Range |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | Rails | 3,906.6 | 4,031.4 | 3,866.8 | 3,763.5 | 3,886.7 | 3,763.5–4,031.4 |
| Room (40 messages) | Roda | 14,436.2 | 14,269.9 | 14,313.6 | 14,393.3 | 14,353.5 | 14,269.9–14,436.2 |
| Earlier messages (40) | Rails | 3,718.6 | 3,759.0 | 3,890.2 | 3,635.8 | 3,738.8 | 3,635.8–3,890.2 |
| Earlier messages (40) | Roda | 16,662.4 | 16,664.0 | 16,672.9 | 15,979.8 | 16,663.2 | 15,979.8–16,672.9 |
| Sidebar | Rails | 3,987.4 | 3,780.6 | 4,024.6 | 3,827.5 | 3,907.4 | 3,780.6–4,024.6 |
| Sidebar | Roda | 19,163.3 | 19,644.5 | 19,353.7 | 19,159.8 | 19,258.5 | 19,159.8–19,644.5 |
| Search (13 matches) | Rails | 3,883.8 | 4,085.3 | 4,214.8 | 4,209.0 | 4,147.1 | 3,883.8–4,214.8 |
| Search (13 matches) | Roda | 19,127.5 | 19,378.3 | 18,848.8 | 19,032.6 | 19,080.0 | 18,848.8–19,378.3 |
| Post message | Rails | 221.6 | 223.9 | 228.0 | 217.7 | 222.8 | 217.7–228.0 |
| Post message | Roda | 505.8 | 521.8 | 476.4 | 499.0 | 502.4 | 476.4–521.8 |
| Avatar | Rails | 52,045.8 | 52,693.0 | 52,805.2 | 53,071.5 | 52,749.1 | 52,045.8–53,071.5 |
| Avatar | Roda | 5,136.7 | 4,999.6 | 5,070.6 | 4,964.8 | 5,035.1 | 4,964.8–5,136.7 |
| Static CSS | Rails | 82,505.4 | 82,013.8 | 82,251.1 | 80,864.9 | 82,132.5 | 80,864.9–82,505.4 |
| Static CSS | Roda | 35,693.6 | 36,641.9 | 36,196.9 | 35,545.8 | 35,945.2 | 35,545.8–36,641.9 |
| Health check | Rails | 5,611.0 | 5,566.0 | 5,682.3 | 5,337.6 | 5,588.5 | 5,337.6–5,682.3 |
| Health check | Roda | 55,286.1 | 54,774.0 | 55,185.8 | 55,285.0 | 55,235.4 | 54,774.0–55,286.1 |

## Reads with a paced writer

2,054,276 valid timed reads and 2,543 valid timed writer responses. All 3,173 acknowledged writes including warmups verified. One writer posts to another room at up to 10/s while sixteen clients read; observed writer sample rates were 9.5–10.0/s. Zero invalid responses or transport errors.

| Workload | App | Round 1 | Round 2 | Round 3 | Round 4 | Median | Range |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | Rails | 1,836.5 | 1,634.0 | 1,822.2 | 1,637.2 | 1,729.7 | 1,634.0–1,836.5 |
| Room (40 messages) | Roda | 11,155.9 | 11,035.2 | 11,341.9 | 11,189.0 | 11,172.5 | 11,035.2–11,341.9 |
| Earlier messages (40) | Rails | 2,219.4 | 2,262.8 | 2,426.4 | 2,277.5 | 2,270.2 | 2,219.4–2,426.4 |
| Earlier messages (40) | Roda | 13,631.1 | 13,504.0 | 12,255.8 | 12,980.4 | 13,242.2 | 12,255.8–13,631.1 |
| Sidebar | Rails | 3,299.4 | 3,159.3 | 3,049.0 | 2,938.9 | 3,104.2 | 2,938.9–3,299.4 |
| Sidebar | Roda | 15,569.3 | 15,967.3 | 14,872.7 | 15,287.3 | 15,428.3 | 14,872.7–15,967.3 |
| Search (13 matches) | Rails | 2,844.8 | 2,936.0 | 2,920.8 | 2,687.8 | 2,882.8 | 2,687.8–2,936.0 |
| Search (13 matches) | Roda | 14,532.3 | 14,664.8 | 14,172.9 | 14,399.7 | 14,466.0 | 14,172.9–14,664.8 |

## Representative preflight body sizes

Round 1, before timed workloads. These are decoded/wire bytes, not allocations. HTML differences include independent rendering, signed URLs and generated attributes; the shared contract checks content and controls rather than byte equality. Avatars are real decoded images but use each app's generated variant.

| Route | Rails decoded / wire bytes | Roda decoded / wire bytes | Encoding, Rails / Roda |
| --- | ---: | ---: | --- |
| Room (40 messages) | 414,966 / 20,714 | 389,354 / 19,675 | gzip / gzip |
| Earlier messages (40) | 378,005 / 11,787 | 360,565 / 11,477 | gzip / gzip |
| Sidebar | 30,811 / 5,886 | 22,807 / 5,338 | gzip / gzip |
| Search (13 matches) | 147,706 / 9,388 | 134,163 / 8,766 | gzip / gzip |
| Avatar | 3,364 / 3,360 | 2,930 / 2,930 | gzip / identity |
| Static CSS | 1,218 / 653 | 1,218 / 1,218 | gzip / identity |
| Health check | 73 / 88 | 73 / 73 | gzip / identity |

## Provenance

Both final runs used identical images and runtime fingerprints. Rails builds from a clean Git archive. Roda was measured with this working-tree update on base commit `ba88ab17ff28047cd043440376d7b741eea7dccf`; its runtime fingerprint identifies the measured changes before commit. The Rails checkout's untracked `vendor/bundle` made its broad dirty flag true, but its tracked tree was clean and those files were excluded from the build.

| Input | Revision or SHA-256 |
| --- | --- |
| Rails source | `05c5a2c0d72f7fd74d7c2ace23cc123000f956b9` |
| Verification source | `c3a99fa3ecdd4d98d0fdd8d4abe87a0c38992efd` |
| Rails runtime fingerprint | `cf93f000412bea10ad196e26bb43fb92595074bd1d9448f2471523c92e5520f7` |
| Roda runtime fingerprint | `dc77341f0e2ca6c53e0b5bd1c3f9d18704be7e028153236ece0bf5fb89519399` |
| Adapter patch | `dd0b550e03432241f51df2e1705369972eef106aa940ad95f797d1bba7c31c5a` |
| Unchanged Rust load generator | `aedee834450d3ac320bc30a416e84977a9cdfdac673b87b933ff67f1cda21778` |
| Original seed database | `e5c065e56ec6549fb9a52668830afb1477be1cf2b4b0b28f7bc6f031215a946e` |
| Rails image | `sha256:3a50d079d006f54c77af99d825ea500d09b850815a10f3d6454f21c3c0bc2592` |
| Roda image | `sha256:1b2dc4c9c09be5f8452857505c7dac78acf94ce1163ba56f9ac4912e1cbc8a66` |
| Client image | `sha256:0c77038986f0974cafdd7b554ac8ffd04b97b84b6924f8c7567519adc73b75b4` |

Production receipt started `2026-10-08T21:43:26Z`; mixed receipt started `2026-10-08T21:55:35Z`. Both have `complete: true`. Host orchestration mounts only disposable fixture databases/files/logs; raw directories are `tmp/once-campfire-verification/tmp/bench/results/roda-production-fingerprinted-20261008/` and `roda-mixed-fingerprinted-20261008/` relative to the Roda checkout.

The fingerprint function in the checked-in harness adapter enumerates Git-known tracked/untracked runtime paths, including the top-level app.rb entry point, assets, vendor JavaScript, configuration, migrations and the Roda boot adapter. For each existing file in sorted order it hashes its relative path, NUL, file bytes, NUL. Docs, tests and measurements are excluded. Images with a mismatched runtime fingerprint are rejected before timing.
