# Renderer optimization evidence

`baseline-*.json` and `roda-*.json` measure the previous and optimized **Roda** applications respectively; neither side is Rails. All rounds are retained. `http-summary.json` aggregates those rounds.

`rack-before-*.json` and `rack-after-*.json` record 300 requests per path per process, with 20 warmups, Ruby 4.0.2 and YJIT. `rack-summary.json` checks normalized response equality and summarizes allocations, query counts, time and GC.

`components-before.json` is a separate, instrumented baseline run. Component timers overlap: rich text is part of template time, and template helpers can run SQL. Use it to locate work, not to predict throughput.

The three Ruby files archive the temporary drivers actually used. To reproduce their paths, copy them into `tmp/profiling/` as `probe.rb`, `components.rb`, and `http.rb`. Extract baseline commit `34b0b1c518275e5b625cb331a9c3599a8d7198e3` with `git archive` into `tmp/optimization-baseline/`, and make its bundle available. Use the same benchmark seed at `tmp/bench-seed/`.

Run the Rack probe with `ruby --yjit tmp/profiling/probe.rb --iterations 300 --output tmp/profiling/<side>-<round>/summary.json`, setting `PROFILE_ROOT` to the desired checkout and the same fixture-only `SESSION_SECRET` for both sides. Create each output directory first. Alternate before/after order across four rounds. The component driver accepts the same options; run it against the baseline separately from timed runs.

`ruby --yjit tmp/profiling/http.rb` starts both production Puma servers on loopback, prewarms each endpoint and invokes the unchanged HTTP client through `bench/compare_http.rb`. It removes the disposable databases and stops both servers on exit. The driver expects Ruby and bundle on PATH.

The drivers consume local fixture labels; published JSON removes fixture credentials, temporary URLs and local paths. Normalized rendered HTML and profiler gem files remain local. No profiler gem is added to the application bundle.
