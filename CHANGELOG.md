# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0.rc1] - 2026-08-25

First release candidate. No API changes are planned before 1.0.0 — this is here
so the surface can be used in anger before it is frozen.

### Added
- **Drain forecast.** Every queue answers the question a backlog actually
  raises: `clears in ~35m`, `stalled`, or `growing 12/s — will not drain`. Net
  velocity rather than throughput, because "how long if arrivals stopped" is a
  different and less useful question. Smoothed across polls, so the label
  reflects a trend rather than one noisy sample. (#35)
- **Capacity.** On Metrics, with a 15m/1h/4h deadline: how many worker threads it
  takes to clear the backlog in time. Arrivals are part of the arithmetic —
  sizing to the backlog alone under-provisions exactly when it matters. Reads
  total configured threads, not threads busy this instant, which would go to
  zero on an idle fleet and claim infinite headroom. Whole-fleet only: Sidekiq
  counts processed jobs globally, so a per-queue figure would be inventing the
  split. (#36)
- **Dry run on bulk actions.** Retry and delete on a filter now list the matched
  jobs, with arguments and errors, before touching anything. The toolbar count
  says how many match; only this says which. (#37)
- **Runbooks.** Point Roundhouse at a constant, a Hash or a callable and a
  Runbook link appears on the job page and each grouped error row. Resolved at
  read time, so it covers jobs already in the queues. Only `http(s)` URLs render
  — the value lands in an `href`, where no escaping makes `javascript:` safe.
  (#39)
- **Settings**, per person and stored in their own browser: light or dark,
  palette, content width, refresh interval. Nothing server-side, so one
  operator's choices never change what anyone else sees.
- **Ten palettes**, each carrying the light *and* dark variant its own authors
  designed — Catppuccin (three flavours), Rosé Pine (two), Nord, Gruvbox,
  Everforest, Kanagawa, Solarized — plus the existing `cyberpunk`, which is
  dark-only and labelled as such. Every value comes from the project's own
  palette file, and tests hold each one to contrast floors and to structural
  rules, so a palette cannot ship with invisible card borders.
- **Queue detail page**: the jobs waiting on one queue, with arguments, paged
  and searchable through the shared browse path.
- **Filter queues by state** — All / Active / Paused — and **sort any column**,
  including Forecast, which has no server-side value at all.
- **A refresh countdown** in the header, since the poll interval is now
  configurable from 2 to 300 seconds and a stale number looked identical to a
  fresh one.
- `job_class_namespaces`, bounding which namespaces a job payload can cause the
  UI to resolve. Off by default. See the README's Security section for what this
  does and does not protect against.
- `RoundhouseUi::Runbooks`, `RoundhouseUi.duration`, `RoundhouseUi.duration_ms`,
  `RoundhouseUi.job_class`, and `concurrency` on both backends.

### Fixed
- **Datadog deep-links matched nothing.** The span tags were invented —
  dd-trace records `sidekiq.job.id` and `sidekiq.job.queue`, and there is no
  `sidekiq.jid` facet anywhere in its Sidekiq integration. Values are quoted
  now, which is the difference between an empty result and a parse error, since
  `:` is a query operator and practically every worker is namespaced. (#29)
- **ActiveJob-wrapped jobs were invisible by their real name.** Every ActiveJob
  failure shared one error-group fingerprint, searching for the real class found
  nothing, and job rows displayed the adapter's wrapper. One shared unwrap now
  serves display, search, grouping and APM links. Re-enqueue deliberately does
  *not* unwrap — pushing the inner class with the ActiveJob envelope re-creates
  the job as a raw worker that fails every attempt. (#30)
- **Durations rendered as raw seconds** in five places, five different ways —
  the health signal reported an hour-old queue as `3616s`. One formatter now
  serves views and `lib/`, which is why it moved out of the view helper. (#31)
- **The Queues page cost a Redis round-trip per queue per column.** Sixty queues
  meant roughly 180 round-trips to render one page. Now two, at any queue count,
  and ordered worst-first rather than alphabetically.
- **A read endpoint was writing to Redis.** `Sidekiq::ProcessSet.new` runs
  dead-process cleanup by default — a `SET`, and an `SREM` when it finds
  anything — on the poll every open tab makes every few seconds, including on
  `read_only` installs.
- **Runbook resolution could return another job's runbook**, because the payload
  reached the resolver while the result was cached per class.
- **Sidekiq 8 compatibility**: `enqueued_at` is integer milliseconds there and
  float seconds on 6.5 and 7. Read as seconds, a Sidekiq 8 timestamp yields a
  negative latency in the billions.
- Queue names were sent twice in every poll response — 40KB became 21KB on a
  500-queue app.
- Pause is enforced natively on Sidekiq Pro/Enterprise, so `RoundhouseUi::Fetch`
  is no longer needed there and `pause_enabled = false` is no longer advice.

### Changed
- The **Queues badge counts enqueued jobs**, not the number of queues.
- **Bulk actions go through the dry run**, so the buttons open a preview instead
  of acting immediately.
- The **Metrics burn-down ETA** uses net velocity. It was backlog divided by
  throughput, a number that stays reassuring while the backlog grows.
- README rewritten as a landing page; the reference manual below it is unchanged
  apart from a pass for redundancy. Gemspec now mentions Solid Queue and no
  longer claims to replace `Sidekiq::Web` — it mounts alongside or instead of it.

### Notes
- Snapshots ship only a Redis store. The README previously suggested a file or
  S3 store as though one existed; the four-method contract for writing your own
  is now documented instead.
- The audit log is a capped Redis list of 1,000 entries with no TTL, evictable
  under `allkeys-lru`. It answers "who did that"; it is not evidence. (#51)
- There is still no RBAC — the model is read-only or not. (#44)

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
