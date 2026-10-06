# Exploratory Puma settings

Two three-second rounds per configuration, two-second warmup at 64 clients per path, same Roda fixture. Initial exploration used one load-generator process. Its CPU reached one core, so the final two configurations repeat the 8/9-worker choice with two load-generator processes and pooled latency samples.

These are short tuning runs, not the final Rails/Roda comparison. The first 8-worker/2-thread run overlapped a short test-suite run during startup; it is retained as exploratory evidence and was repeated with two clients before selecting the final configuration. The profile hidden-direct-chat edge case was fixed after these pilots and before the final audit/timed comparison; the pilots do not establish the final runtime digest.

Eight workers with two threads was selected: the two-process-client repeat found little throughput difference from nine workers, with lower tail latency and lower summed RSS at eight. Raw output for every round is retained. Temporary paths, URLs and fixture credentials are removed.
