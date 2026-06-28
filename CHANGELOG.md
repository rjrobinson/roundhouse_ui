# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/rjrobinson/roundhouse_ui/commits/main
