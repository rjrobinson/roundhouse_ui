# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **A stability contract**, ahead of 1.0. The README now states which surfaces are
  covered by semantic versioning — the configuration surface, `cancelled?`, the
  fetcher and middlewares, the mounted paths, the theme token names, and the
  `roundhouse:*` Redis keys — and which are not. The backend port is deliberately in
  the second list: writing your own backend works today, but the contract is still
  being settled against #17 and #41, and pinning it now would freeze it before it is
  right.

### Fixed
- **`warn_once` warns once.** It was named for what it was meant to do and logged
  every time. A `job_tags` or `job_runbooks` resolver that raises raises for every
  entry in a scan, so one broken lambda wrote a line per job — a thousand identical
  lines for a single page render, which is how a warning stops being read. It now
  deduplicates per message, per process, with a bounded memo so a resolver whose
  message varies cannot grow it without limit. Both copies (Tags and Runbooks) now
  call one implementation on `RoundhouseUi`, alongside `duration`.

### Changed
- **The Busy page's Cancel button is now off by default**, behind
  `cancel_enabled`. Cancellation only does anything once you install
  `CancelMiddleware` or have long-running jobs poll
  `RoundhouseUi.cancelled?(jid)`; with neither, `cancel!` wrote a JID nothing
  ever read, so the button was inert and said so nowhere. The route is gated
  too, not just the column. Set `cancel_enabled = true` to get it back
  ([#24](https://github.com/rjrobinson/roundhouse_ui/issues/24)).
- **Destructive buttons now read as destructive at rest**, not only on hover —
  `.rh-btn-danger` differed from `.rh-btn` by a single `:hover` rule, so Retry
  and Delete were the same button until the cursor was already on one
  ([#32](https://github.com/rjrobinson/roundhouse_ui/issues/32)).
- **Read-only mode is enforced fail-closed.** Every `POST` is treated as a write
  unless its controller explicitly says otherwise, so a destructive action added
  tomorrow is guarded the moment it exists. It was previously seven near-identical
  `require_writable!` methods, each wired to a hand-maintained `only:` list — all
  seven correct, and each one omission away from silently not being. Taking a queue
  snapshot remains the single deliberate exemption, now declared with
  `allow_in_read_only :snapshot` rather than expressed by absence from a list.

  The refusal message is now the same everywhere ("Roundhouse is in read-only mode
  — this action is disabled."); each section still redirects back to itself.

### Fixed
- **Deleting a Solid Queue entry no longer orphans its job row.** The adapter
  called `destroy` on the execution, which left the `solid_queue_jobs` row
  behind — invisible to every page and unreachable by every worker. It now
  calls `discard`, which takes both under a row lock
  ([#20](https://github.com/rjrobinson/roundhouse_ui/issues/20)).
- **Forgery protection is now shipped by the engine, not inherited from the host.**
  The README has always promised that every destructive action is a CSRF-protected
  `POST`; the engine never actually asked for protection, so it held only because a
  host on `config.load_defaults 5.2` or later puts the guard on
  `ActionController::Base` for everyone. Mounted in an app on older defaults, every
  purge, delete and bulk action was forgeable. Roundhouse now declares
  `protect_from_forgery with: :exception` on its own controller, for the same reason
  it sets its own Content-Security-Policy: the engine states its security posture
  instead of hoping the host set one. `AssetsController` still opts out, deliberately.

  No test had ever seen the guard run — every Rails test environment disables
  forgery protection — so the suite now re-enables it and asserts a token-less POST
  is refused.

## [0.10.0] - 2026-08-17

### Added
- **Job tags.** Surface your own label — owning team, tenant, product area — on
  the job rows, the job page and grouped errors, and filter by it. Point
  Roundhouse at a constant your jobs already carry and you're done:

  ```ruby
  RoundhouseUi.job_tags = RoundhouseUi::Tags.from_constant(:OWNER, as: :squad)
  RoundhouseUi.tag_filters = { squad: %w[core training growth platform] }
  ```

  Any callable works if your labels come from elsewhere. Tags resolve **when a
  page renders** — no middleware, no storage, no enqueue changes — so they apply
  retroactively to jobs already in the sets and behave identically on Sidekiq and
  Solid Queue. `klass` is always the real job class: the ActiveJob adapter's
  wrapper is unwrapped before your resolver sees it. Resolution is memoized per
  class per request; set `job_tags_per_job = true` if your tags read the payload.
  Tag values pass through `redact_args`, and a resolver that raises degrades to
  no tags rather than failing the page. See
  [ADR 0002](docs/adr/0002-job-tagging.md).
- **Filter by tag and by queue.** `?tag=key:value` and `?queue=name` narrow
  Retries, Dead and Scheduled; queue pills are the control, and Errors gains
  counted filter chips. Both combine with text search, and squad names are
  searchable from the box. Filters apply identically to bulk actions, so the rows
  you see are the rows "delete all matching" touches.
- **The ⌘K palette searches.** Paste a job ID, queue, squad, or class and it
  offers the searches that will find it, instead of only jumping between pages.
- **Per-job actions on the dead set.** Retry and delete a single dead job from
  its row; previously the routes existed but the only way in was a checkbox.
- **A queue filter on the Queues page**, which had no search at all.

### Changed
- **The job views share one structure** — identity, squad, queue, error, when,
  actions — rendered the same way everywhere. Job IDs move to a second line,
  observability deep-links become an icon in the Actions column, times show
  relative *and* absolute, and queues render as pills.
- **The two bulk scopes are visually separate.** "The rows you ticked" and "every
  job that matches" were stacked bars distinguished only by caption text.
- **Headings and empty states tell the truth under a filter** — the filtered
  count and the active filter, rather than the whole-set size above a narrowed
  table, or "the set is empty" when a filter simply matched nothing.

### Fixed
- **Select-all on the dead set stopped working after any Turbo navigation**
  ([#26](https://github.com/rjrobinson/roundhouse_ui/issues/26)) — most visibly
  after a search. The handler was an inline body script bound to the checkbox
  element; a Turbo visit replaces `<body>`, discarding both the element and its
  listener, and the re-inserted script carries a nonce the original page's CSP
  rejects. It is now delegated from `document` in the layout head.
- **The Errors page returned a 500 on a search that matched nothing** — including
  on a fresh install with no failing jobs and a declared tag vocabulary.
- **Errors search ignored tags** while advertising that it matched them.

## [0.9.1] - 2026-07-31

### Fixed
- **Queue pause now works on Sidekiq Pro / Enterprise.** Pro keeps its paused queues
  in its own Redis set, so Roundhouse's registry wrote a key nothing read: pausing
  silently did nothing and the UI (correctly) warned it wasn't enforced. Roundhouse
  now feature-detects Pro's pause API, delegates to `Sidekiq::Queue#pause!` — which
  also publishes the `pro:config` message Pro's fetchers need to pick a change up
  without a restart — reads paused state from Pro's registry, and advertises
  `native_pause` so the warning drops away.

  Pro enforces pause in *both* its fetchers (it prepends onto `Sidekiq::BasicFetch`,
  and `super_fetch` honors it too), so this needs no fetch strategy and no
  configuration. **If you set `RoundhouseUi.pause_enabled = false` on the previous
  advice, remove it** — pause works natively, and leaving it set only hides a working
  feature. No change for OSS Sidekiq (still needs `RoundhouseUi::Fetch`) or Solid
  Queue (already native).

### Changed
- **Lower per-job Redis cost for the opt-in server middleware.** Running both
  `CancelMiddleware` and `DurationCollector` cost three Redis round-trips per job.
  `DurationCollector` now pipelines its two writes into one round-trip, and
  `CancelMiddleware` answers "is anything cancelled at all?" from a process-local
  gate refreshed at most every 2s, so the per-job `SISMEMBER` only runs while
  cancellations are actually pending. Idle cost drops from three round-trips per job
  to one. A cancellation issued by another process is now honored within ~2s rather
  than immediately — cancellation is cooperative and already racy, and
  `RoundhouseUi.cancelled?` (which long-running jobs poll) stays exact.

## [0.9.0] - 2026-07-24

### Added
- **Solid Queue backend.** Roundhouse now reads through a pluggable backend port —
  set `RoundhouseUi.backend = RoundhouseUi::Backends::SolidQueue.new` to drive Solid
  Queue (ActiveRecord-backed) with the same UI, no build step, no new frontend
  dependency. Capability-driven: queue pause is native, and Retries / Redis /
  Capsules / Workers hide where Solid Queue has no equivalent. Sidekiq stays the
  default. See [docs/adr/0001](docs/adr/0001-backend-port-multi-queue.md).
- Dedicated Solid Queue CI matrix (`~> 1.0` / `~> 1.5`) alongside the Sidekiq matrix.

### Changed
- Internal: extracted the `RoundhouseUi.backend` port; controllers, `Metrics`, and
  `ErrorGroups` read through it, and Busy normalization moved into the backend. No
  behavior change for Sidekiq (delegates to the same API).

## [0.8.0] - 2026-07-01

### Added
- **Smart bulk match-set** on Retries + Dead: with a filter active, retry or
  delete *every* matching job in one action (not just the visible page), capped
  at 1,000 per run. Filter-gated (can't become "retry everything"), `read_only`-
  aware, and audit-logged.
- **Per-class duration tracking** (opt-in): `RoundhouseUi::DurationCollector`
  server middleware + `collect_durations` surface the slowest job classes (by
  total time, with count + average) on the Metrics page. Two cheap Redis writes
  per job; off by default; never lets collection break a job.

### Changed
- **On-call hardening:** responsive layout (sidebar collapses to a top nav and
  cards stack on phones), visible `:focus-visible` outlines on every control, and
  a poll-failure indicator ("reconnecting…") so a failed stat poll no longer reads
  as a silent live `0`.

## [0.7.0] - 2026-06-30

### Added
- High-signal dashboard overview: a **composite health banner** (rolls up error
  rate + queue latency + worker utilization into one verdict, with an expandable
  "why"), a **top failing job classes** panel (links to filtered Errors + Datadog),
  and a **problem queues** panel (worst latency first).
- **Interactive throughput chart**: a live "peak N/s" readout, a hover tooltip, and
  an emphasized endpoint.
- Richer metric cards (success rate, worker utilization) plus a new **Backlog** card.
- **Job detail**: large arguments collapse into a disclosure, and the full backtrace
  is now available (previously truncated to the first 20 frames).

### Changed
- Extracted the failing-job aggregation into `RoundhouseUi::ErrorGroups`, now shared
  by the Errors page and the dashboard's top-failing panel.

## [0.6.0] - 2026-06-30

### Added
- Datadog deep-links on grouped **Errors** rows (`error_url` on the observability
  adapter), searching by job class — so failures that surface only in the Errors
  view (e.g. `sidekiq-failures` entries) can still jump out to Datadog.
- `RoundhouseUi.poll_interval` (seconds, default `5`) — the dashboard stat-poll
  cadence is now configurable. Frequent polling re-runs the host's auth/routing on
  every request, so a slower interval reduces DB load on busy consoles.

### Changed
- Throughput chart now **buckets by a configurable interval** (per 10s / 30s / 1m /
  5m) instead of redrawing every poll. A new point lands once per interval, so the
  line reads as sustained load rather than a per-poll sawtooth. Replaces the
  previous "window" picker.
- Dashboard "Processed" rate no longer renders a hardcoded ▲ up-arrow (it implied an
  upward trend on every load); it now just shows the rate.

## [0.5.0] - 2026-06-30

### Fixed
- **Busy** page no longer 500s on Sidekiq 6.x. `WorkSet#each` yields a plain Hash
  there (not the `Sidekiq::Work` struct added in 7+), so `work.queue/.run_at/.job`
  raised `NoMethodError`. The yield is now normalized across versions.
- **Capsules** page no longer 500s on Sidekiq < 8.0.8 (incl. 6.x). `process.capsules`
  is guarded with `respond_to?`, and the Capsules nav/command entries are hidden
  entirely when `Sidekiq::Capsule` isn't defined (Sidekiq < 7).

### Added
- `RoundhouseUi.pause_enabled` (default `true`). Set to `false` to hide the queue
  pause/resume controls and the "pausing not enforced" warning — for deployments
  running reliable fetch (Sidekiq Pro/Enterprise super_fetch), where Roundhouse's
  pause-aware fetcher can't be installed.
- Throughput chart: a window picker (1m / 5m / 15m, persisted) plus moving-average
  smoothing, so sustained load reads as a sustained line instead of per-poll spikes.

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

[0.10.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.10.0
[0.9.1]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.9.1
[0.9.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.9.0
[0.8.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.8.0
[0.7.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.7.0
[0.6.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.6.0
[0.5.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.5.0
[0.4.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.4.0
[0.3.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.3.0
[0.2.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.2.0
[0.1.0]: https://github.com/rjrobinson/roundhouse_ui/releases/tag/v0.1.0
