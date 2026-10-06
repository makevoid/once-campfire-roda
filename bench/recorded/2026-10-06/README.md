# Historical partial-port comparison evidence

Recorded after the route refactor and behavior fixes on 2026-10-06. These numbers describe the former minimal frontend. See [historical methodology and results](../../../docs/performance-partial-port.md#live-rails-and-roda-comparison) and [reproduction commands](../../README.md#reproduce-the-recorded-rails-comparison).

- `baseline-1.json` through `baseline-4.json`: all Rails round results.
- `roda-1.json` through `roda-4.json`: all Roda round results.
- `summary.json`: throughput/latency medians, ranges, request totals, and sampled resource maxima.
- `verification.json`: matching fixture counts and rendered message IDs.
- `metadata.json`: hardware, source revision, runtime file digest, and run configuration.
- `parity.json`: 54 live semantic checks from a separate disposable run of the same app code.
- `hot-paths.json` and `hot-paths-scale.json`: separate Roda Rack probes, including individual samples, SQL counts, allocations, and normalized body hashes.

The published HTTP result copies omit local absolute paths, ephemeral URLs, and fixture credentials. Per-round measurements are unchanged; no round is discarded. Logs and full one-second process samples remain in the local ignored result directory. The runtime SHA-256 in metadata hashes each listed relative filename, a NUL, its bytes, and another NUL, in order.

This is a shared text-workload comparison of two applications with different frontends and feature coverage. It does not establish full Rails parity or isolate framework overhead.
