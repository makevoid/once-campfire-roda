# Puma tuning

Production now defaults to two threads per worker and `WEB_CONCURRENCY=auto`. Auto uses the available CPU count minus two, falling back to single-process mode on machines with three or fewer CPUs. On this 10-core Apple M4, that means eight worker processes. Development stays in single-process mode. Explicit environment settings override these defaults.

Puma’s [cluster mode](https://puma.io/puma/file.README.html#cluster-mode) provides independent Ruby processes, allowing CPU-heavy rendering to run concurrently across cores. Additional threads inside one MRI process primarily help while other requests wait for I/O. [Puma’s deployment guidance](https://github.com/puma/puma/blob/v7.2.1/docs/deployment.md) recommends choosing worker counts around the available CPUs and measuring thread-count tradeoffs.

## Why eight workers and two threads

Exploratory runs used the same four read workloads and 64 total clients, with two three-second rounds per setting. These short runs selected a configuration; the final comparison uses fresh fixtures and four longer alternating Rails/Roda rounds.

| Workers | Threads/worker | Client processes | Room req/s | History req/s | Sidebar req/s | Search req/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 2 | 1 | 1,257 | 1,555 | 3,209 | 672 |
| 8 | 5 | 1 | 1,180 | 1,303 | 2,522 | 527 |
| 9 | 2 | 1 | 1,186 | 1,477 | 3,079 | 613 |
| 8 | 2 | 2 | 1,236 | 1,522 | 3,041 | 687 |
| 9 | 2 | 2 | 1,255 | 1,536 | 3,093 | 683 |

Five threads per worker added contention on these rendering workloads. The one-process load generator also reached a full core, so the 8/9-worker comparison was repeated with two client processes. In that repeat, throughput was within about 2%; eight workers had lower p95 latency across all four paths and lower summed RSS. Eight workers leave more capacity for the client, OS and background jobs. No CPU affinity is applied. [All exploratory rounds](../bench/recorded/2026-10-06-puma-tuning/) are retained, including their limitations.

## Fork safety and verification

The Roda app preloads and migrates once in the master, then closes Sequel connections in `before_fork`. Workers open their own SQLite connections on demand. The matching Rails benchmark preloads too and clears Active Record connections before forking. The source Rails checkout is unchanged.

A regression test loads the actual Puma configuration, invokes its fork hook, and verifies two child processes can write through independent SQLite connections. Additional tests verify load-generator aggregation and HTTP failures, and ensure resource accounting never counts a child server as part of its parent client process. The eight-worker audit passed 83 Rails/Roda checks and 136 frontend/HTTP/WebSocket checks.

The combined audit also found an existing profile-page error after hiding a direct chat. Its notification control now returns to the first valid setting instead of failing on an absent cycle index; a dedicated regression test covers restoring notifications. This fix was completed before the final audit and timed comparison.

## Load generation and resources

`bench/http_client.rb` remains byte-for-byte unchanged. `ParallelHTTPClient` divides total concurrency across two forked Ruby processes, starts them together, and uses the original login/request/connection/error logic. It collects their raw latency samples and calculates pooled percentiles. Aggregate requests per second uses a shared elapsed time that includes result transfer to the parent. It does not add per-process throughput rates or average per-process percentiles.

Warmup uses 64 clients so all workers get traffic. Final measurements cover 16 and 64 total clients, split equally across the two generators. Rails and Roda use identical worker, thread, pool, Ruby/YJIT and client settings. Normal authentication, CSRF, full bodies and frontend controls remain enabled; Rails retains its production Redis cache.

Resource samples include every server worker and the load-generator children. CPU uses 100% per core. Summed RSS includes shared copy-on-write pages in each process, so it exceeds unique physical memory use. An explicit `WEB_CONCURRENCY` is available for deployments with tighter CPU or memory limits; every worker owns its database pool.

The final four-round comparison completed **390,008 requests with zero errors**. Peak aggregate Roda CPU was **780.7%**, approximately 7.8 cores, with **1,360.1 MiB summed RSS** across its master and workers. Rails peaked at 805.3% and 2,556.3 MiB summed RSS. The two-process load generator peaked at 86.7% aggregate CPU. See [full throughput, latency and ranges](performance.md).

The full suite passed **74 tests / 557 assertions**. The final audit and timed run share the same recorded application runtime digest.

## Run it

```sh
# Production: auto selects eight workers on this ten-core machine.
RACK_ENV=production WEB_CONCURRENCY=auto MAX_THREADS=2 bundle exec puma -C config/puma.rb

# Matched framework benchmark, assuming the documented dependencies and seed.
BENCH_WORKERS=8 BENCH_THREADS=2 BENCH_CLIENT_PROCESSES=2 BENCH_PARITY=1 ruby bench/rails/run.rb
BENCH_WORKERS=8 BENCH_THREADS=2 BENCH_CLIENT_PROCESSES=2 ruby bench/rails/run.rb
```

Set the normal production `SESSION_SECRET`, database and upload paths as described in the [README](../README.md#production). Benchmark drivers use separate disposable databases and loopback listeners. [Benchmark options](../bench/README.md#reproduce-the-recorded-rails-comparison) document concurrency, duration and warmup overrides.
