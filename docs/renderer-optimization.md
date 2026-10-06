# Renderer bottlenecks and small optimizations

Profiling found that the message pages spend most of their time rendering. The changes keep the existing routes, services, queries, partial boundaries and frontend controls. They add no application dependencies or response/fragment cache.

## Where time was going

A separate instrumented run against the previous commit measured the following proportions of total Rack request time. Template time includes nested partials, helpers and rich text; **columns overlap and must not be added**. Instrumentation adds overhead, so these identify broad areas rather than exact CPU attribution.

| Workload | Template rendering | Rich text within rendering | SQL execution and row fetching |
| --- | ---: | ---: | ---: |
| Room (40 messages) | 82% | 19% | 12% |
| Earlier messages (40) | 77% | 24% | 12% |
| Sidebar | 55% | 0% | 26% |
| Search (100 matches) | 87% | 25% | 9% |

The uninstrumented request probe also measured garbage collection with `GC.total_time`. Before optimization, GC accounted for approximately 15–18% of message-page request time. Large responses amplify that allocation cost: a room returns about 442 KB of HTML and a 100-match search about 1.06 MB. The sidebar has a larger database share and benefits less from renderer changes.

## Small changes

- Define the current-user/account value class once. Include the compiled template module in the view class once, avoiding a new singleton class for each request.
- Cache template dispatch by name, partial flag and sorted local names. Resolve paths and validate names on compilation, while continuing to render request-specific locals and escape output every time.
- Keep HTML5 parsing and serialization for every rich-text body. Skip the attachment selector when its tag is absent; walk text nodes directly instead of constructing an XPath context; check for link candidates before traversing ancestors.
- Compute each message’s reaction frame ID once and reuse it across the eight existing forms.

No controls, security checks, rich-text features, queries or rendered fields were removed. Autolinking tests cover adjacent markup, decoded entities, existing links, code blocks, multiple links, punctuation and editing. Template tests cover shared methods, independent request locals, partial variants, escaping and invalid names.

## Before and after over HTTP

Four alternating rounds, 16 clients, five seconds per workload, two seconds of per-path warmup and three seconds of initial prewarming. Both servers use production Puma with five threads and five database connections, Ruby 4.0.2 with YJIT and separate copies of the same fixture. **All 47,362 measured requests returned HTTP 200, with zero errors.**

| Workload | Before req/s | After req/s | Change | Before range | After range | p95 ms, before / after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | 198 | 210 | +6% | 181–216 | 110–262 | 96.6 / 129.8 |
| Earlier messages (40) | 240 | 301 | +26% | 119–280 | 249–327 | 76.4 / 66.5 |
| Sidebar | 594 | 675 | +14% | 485–682 | 433–679 | 35.8 / 29.1 |
| Search (100 matches) | 94 | 142 | +51% | 60–108 | 113–154 | 227.1 / 124.2 |

These are Roda-before versus Roda-after measurements. **Run-to-run variation is substantial and the ranges overlap**, so the percentage changes are observations, not precise forecasts. Room p95 latency increased from 96.6 to 129.8 ms in this run, despite its small throughput increase. Allocation counts and normalized response equality are the more stable evidence of the work removed. The separate [Rails/Roda comparison](performance.md) uses fresh matched fixtures and its own runs.

## Allocation and output checks

Four fresh-process runs per version alternate before/after order, with 300 measured requests and 20 warmups per path in each run. Both use Ruby 4.0.2 with YJIT, the same fixture and session secret, normal login and CSRF. Times and object counts below are medians of per-run medians. This in-process probe is separate from HTTP throughput.

| Workload | Before ms | After ms | Objects before | Objects after | Fewer objects | SQL queries, both |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Room (40 messages) | 4.67 | 3.42 | 28,944 | 23,491 | 18.8% | 11 |
| Earlier messages (40) | 3.79 | 2.93 | 24,306 | 19,051 | 21.6% | 10 |
| Sidebar | 1.38 | 1.33 | 9,977 | 9,475 | 5.0% | 10 |
| Search (100 matches) | 9.04 | 6.65 | 58,224 | 44,776 | 23.1% | 11 |

All four response fingerprints match across both versions and all rounds after normalizing only CSRF masks and CSP nonces. Response byte counts and query counts also match. The probe checks every response is HTTP 200. GC’s measured share falls to approximately 11–13% of message-page request time.

## Evidence and reproduction

The baseline is commit `34b0b1c518275e5b625cb331a9c3599a8d7198e3`, extracted with `git archive` into an isolated directory. [Recorded data](../bench/recorded/2026-10-06-renderer-optimization/) contains every Rack and HTTP round, the component measurements, summaries and the optimized runtime digest. Published fixture credentials and machine-specific paths are removed; timings are unchanged.

Use [`bench/message_hot_paths.rb`](../bench/message_hot_paths.rb) at each revision with `ruby --yjit`, a fixed fixture-only `SESSION_SECRET`, `--iterations 300` and the same absolute `--seed` path. For throughput, start one isolated production Puma server per revision against separate snapshots of that seed, then run [`bench/compare_http.rb`](../bench/compare_http.rb) with `--url` for the new version and `--baseline-url` for the old version, `--concurrencies 16 --rounds 4 --duration 5 --warmup 2`. Prewarm each endpoint for three seconds first. Use five Puma threads, five database connections and YJIT for both servers and the client.

## Remaining opportunities

HTML generation and rich-text processing remain the main work on message-heavy pages. Fragment caching could reduce repeated work further, but needs correct invalidation for edits, reactions, users and authorization. Rails already uses its normal production cache in the framework comparison. Database tuning is more relevant to the sidebar than to the 100-message search. Neither is necessary for these small renderer improvements.
