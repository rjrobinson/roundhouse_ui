# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-06-30

### Added
- Compact/full-width layout toggle. A header button (and `⌘K` → "Toggle full
  width") flips the content area between the default 1180px column and full
  viewport width. Saved per-browser in `localStorage` and applied before first
  paint (no flicker), reusing the theme-toggle machinery.

## [0.3.0] - 2026-06-29

### Added
- `RoundhouseUi.show_sidekiq_failures` (opt-in, default off): when the
  [`sidekiq-failures`](https://github.com/mhfs/sidekiq-failures) gem is loaded,
  its `failed` set is folded into the grouped Errors view. Surfaces failures from
  `retry: false` jobs, which never enter Sidekiq's retry/dead sets. No-op unless
  the gem is present. Closes #5.

## [0.2.0] - 2026-06-29

### Changed
- Lowered the Sidekiq floor to `>= 6.5` (was `>= 7.0`). The gem now runs on
  Sidekiq 6.5, 7, and 8 with no code changes — all Redis access goes through the
  low-level `conn.call(...)` API, whose splat signature is identical on redis-rb
  (Sidekiq 6.x) and redis-client (Sidekiq 7+). CI now tests the full matrix.

### Note
- On Sidekiq 6.x, redis-rb **>= 4.6** is required (that's where `Redis#call` landed).
  Sidekiq 6.5 resolves to redis 4.8 by default, so this only affects setups pinned
  to redis 4.5.x. See [#5](https://github.com/rjrobinson/roundhouse_ui/issues/5).

## [0.1.0] - 2026-06-29

### Added
- Mountable Rails engine (`RoundhouseUi::Engine`) — reads Sidekiq's API, no database.
- Live dashboard: throughput chart + stat cards poll a JSON endpoint and update in place
  (Turbo Drive for navigation); polling pauses while the browser tab is hidden.
- Queues: pause/resume (via the opt-in `RoundhouseUi::Fetch` strategy), purge with an
  impact count, and snapshot.
- Dead set: search (class / JID / error / arg value), bulk retry/delete, and pagination.
- Retries & Scheduled views with per-job actions, search, and pagination.
- Grouped Errors view: failures across retry + dead fingerprinted by class + error.
- Workers view: process fleet with quiet/stop, threads, queues, heartbeat, and a
  fetch-strategy indicator (detects whether the pause-aware `RoundhouseUi::Fetch` is active).
- Busy view: currently-running jobs with cooperative cancellation via
  `RoundhouseUi::CancelMiddleware` and `RoundhouseUi.cancelled?(jid)`.
- Redis pressure view from `INFO`, including the eviction-policy / silent-job-loss warning.
- Job inspection (args with redaction, error, backtrace, APM link) and, opt-in via
  `allow_job_editing`, editing/re-enqueue and enqueuing new jobs.
- Snapshots: back up a queue and restore it; pluggable `snapshot_store` (default Redis).
- Audit log of all state-changing actions, with a configurable `actor_resolver`.
- Pluggable observability deep-links (`RoundhouseUi.observability`, Datadog adapter shipped).
- Argument redaction (`RoundhouseUi.redact_args`).
- `⌘K` command palette, light/dark themes, `read_only` mode, and a self-contained CSP.

[0.4.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.4.0
[0.3.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.3.0
[0.2.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.2.0
[0.1.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.1.0
