# Rails / Roda / Erubi comparison evidence

These measurements use the complete Campfire frontend port and independent Erubi
renderer. See [results and methodology](../../../docs/performance.md) and
[reproduction commands](../../README.md#reproduce-the-recorded-rails-comparison).

- `baseline-1.json` … `baseline-4.json`: all Rails rounds.
- `roda-1.json` … `roda-4.json`: all Roda rounds.
- `summary.json`: medians, ranges, latency, totals and resource maxima.
- `verification.json`: fixture counts and HTTP message IDs.
- `metadata.json`: hardware, versions, configuration and source/runtime hashes.
- `parity.json`: 83 differential checks from a separate disposable run.
- `frontend.json`: 136 live asset and WebSocket checks.
- `browser.json`: successful local Chrome interaction checks.

All 83,659 measured requests returned HTTP 200, with no transport errors. All
rounds are retained. Published result copies omit local paths, temporary server
URLs and fixture credentials; measurements are unchanged. Full logs and process
samples remain in the local ignored result directory.

The audit and benchmark share the recorded runtime digest. It hashes each listed
relative path, a NUL, its file bytes and a NUL, in order. The hidden asset manifest
has a separate SHA-256 in metadata. Source assets were unchanged during the run.

The earlier minimal-frontend results remain in `../2026-10-06/` as historical
evidence. They describe a different renderer and should not be used for this port.
