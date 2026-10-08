# Shared Rails/Roda verification

`bin/benchmark` runs the public [once-campfire-verification](https://github.com/makevoid/once-campfire-verification) harness, defaulting to **Rails and Roda only**. Its Rust load generator and response contracts are unchanged. The checked-in adapter patch adds Roda's native database audit and Docker Desktop support.

Prerequisites: Docker, Ruby 4.0, `gh` with GitHub SSH access, Git, SQLite CLI, and FFmpeg. On macOS use Homebrew's SQLite (`brew install sqlite ffmpeg` and put `$(brew --prefix sqlite)/bin` first on `PATH`); Apple's older SQLite could not read the fixture's WAL database reliably here.

```sh
# Clone pinned sources with gh over SSH, apply the adapter, build images and seed,
# then measure three alternating 8-second rounds at 16 clients:
ruby bin/benchmark --prepare

# Build only; existing generated fixtures are reused:
ruby bin/benchmark --prepare-only

# The recorded comparison:
ruby bin/benchmark --rounds 4 --duration 8

# Reads while a separate client posts up to ten messages per second:
ruby bin/benchmark --rounds 4 --duration 8 --mixed-write-rate 10

# Preflight without timing:
ruby bin/benchmark --preflight --rounds 2
```

Other shared options pass through unchanged (`--help`, `--apps`, `--routes`, `--concurrencies`, `--cpus`, `--client-cpus`, `--output`, `--keep-runtime`). Paths passed to the shared runner are relative to its checkout. The default CPU sets require at least eight Docker virtual CPUs; allocate ten CPUs and about 8 GiB to reproduce this machine. Each server gets CPUs 0–3 and the load client gets 4–7. Both Ruby servers use three Puma workers, five threads and YJIT. Rails runs its upstream production image, including Thruster and Redis. Roda runs its production Puma and durable-job worker through `boot`, which only imports/configures the shared fixture.

`VERIFICATION_SOURCE` and `RAILS_SOURCE` override checkout paths. `RAILS_IMAGE`, `RODA_IMAGE`, and `BENCH_CLIENT_IMAGE` override image names. Source revisions live in [sources.json](sources.json). Rails builds from a clean Git archive. Runtime SHA-256 labels include tracked and untracked source files; the benchmark rejects an image whose fingerprint differs from its checkout. Source revision, dirty state, adapter patch digest, image IDs, fixture hash and client binary hash are saved in each completed receipt.

The orchestrator runs on the host. Each load-client container shares only the server's network namespace and mounts its disposable fixture directory. No Docker socket or whole workspace is mounted in a container. On Docker Desktop the server's port is exposed only on host loopback. Raw results, credentials, generated fixtures and browser artifacts remain under ignored `tmp/` directories.

Read expectations come from SQL against the common Rails fixture, before any Roda import. Every measured response must satisfy its route contract. Real avatar pixels are decoded; full gzip bodies, message windows and seeded words are checked. POST acknowledgements must correspond to unique persisted message IDs, exact request tokens, the correct room, rich-text/native body and FTS entry. Any invalid response or failed write audit fails the run.

Two identical runtime normalizations are applied to both apps: outbound fixture URLs use a loopback discard endpoint, and deliberately orphaned message creators get disabled placeholder users. The latter preserves all message IDs and content while allowing Roda's foreign keys to remain enabled. The original seed is never modified and its checksum is checked again after the comparison.

The optional harness checks need Rust 1.94; browser checks need Node 22.18 or newer.

```sh
cd tmp/once-campfire-verification
ruby bin/check
npm ci
npx playwright install chromium
# Point this only at a fresh, disposable app installation:
node browser/smoke.mjs --base http://127.0.0.1:9292
```

The shared browser flow complements native authorization, cache, media, job and TLS tests. It is not exhaustive feature parity or a test of granted push delivery through a real provider. See [the update audit](../../docs/upstream-update.md) and [measured results](../../docs/performance.md).
