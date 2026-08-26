# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Demo workers and a capped load generator**, so the console can be seen doing
  something. `require "roundhouse_ui/demo"` in a development initializer, then
  `rake roundhouse_ui:demo:load[15]`. Six classes across six queues with different
  durations and failure rates — one long enough to always be mid-flight on Busy,
  one flaky enough to dominate Errors — and a rate that rises and falls so the
  dashboard's trend and drain forecast have something to say.

  Deliberately not loaded by `require "roundhouse_ui"`. Each worker refuses to run
  outside development, the task refuses any other environment, and it refuses Redis
  database 0 — by asking the connection where it is rather than reading
  configuration. `rake roundhouse_ui:demo:clean` removes what it left.

- **Find more like this.** Every row on Retries, Dead and Scheduled carries a 🔍
  that narrows the set to that job's class and, where the set records one, that
  job's error — the same pair the Errors page treats as one issue, so a row here
  and a row there mean the same thing. One click turns "this row looks wrong" into
  "here are all of them, and here are the bulk controls".

  `?class=` and `?error=` are exact rather than substring. The button exists to
  reveal `Delete all matching`, and a substring filter would also select jobs whose
  *arguments* merely mention the class you clicked, invisibly. Same reasoning as
  `?tag=` and `?queue=`.

- **The per-row job actions are tested.** `find_job(jid)` opens `retries#destroy`,
  `retries#requeue`, `dead#destroy`, `dead#requeue`, every scheduled action and
  `jobs#show/edit/update`, and none of it had ever run: it issues `ZSCAN`, which the
  in-memory stand-in cannot answer at all. Covered now against a real Redis,
  including that a delete removes exactly one job and that the page says which.

- **The destructive paths are tested against a real Redis.** Enforced pause,
  snapshot → restore, and bulk-on-a-filter are made of Redis semantics — sorted-set
  ordering, sets that vanish with their last member, real key expiry — and the whole
  suite ran against an in-memory stand-in where `HGET` returns nil, `ZADD` discards
  the score and `SSCAN` returns everything in one pass. That is fine for exercising
  our logic and cannot tell you whether Redis does what the code assumes. CI now runs
  these on every Sidekiq version in the matrix, and fails rather than skips if Redis
  is missing. They found a real bug immediately (see Fixed).

- **A stability contract**, ahead of 1.0. The README now states which surfaces are
  covered by semantic versioning — the configuration surface, `cancelled?`, the
  fetcher and middlewares, the mounted paths, the theme token names, and the
  `roundhouse:*` Redis keys — and which are not. The backend port is deliberately in
  the second list: writing your own backend works today, but the contract is still
  being settled against #17 and #41, and pinning it now would freeze it before it is
  right.

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

- **Every control is one box on one scale** ([#65](https://github.com/rjrobinson/roundhouse_ui/issues/65)).
  Eight controls had four font sizes, seven paddings and four radii between them,
  sharing nothing — so `.rh-trace-btn` rendered 2px taller than the `.rh-runbook`
  pill beside it, and `⌘K` sat 9px shorter than the icon buttons next to it. There
  are now `--ctl-*` dimension tokens and a single rule every control draws from.

  Controls are sized by **height**, never by line-height plus padding. That is what
  makes an icon-only control and a text control the same height by construction
  instead of by coincidence; matching paddings cannot do it across different
  content, which is why fixing pairs by hand kept not holding.

  Icons are also sized on the glyph rather than on a wrapper. Every shipped mark
  carries its own `width` attribute and nothing overrode it, so a 15px SVG sat in a
  12px slot and read as oversized — no padding change could have fixed that.

  `control_scale_test.rb` fails on a hand-typed length in any control rule, and
  fails again if a control stops getting a height from the scale. The tokens are
  not the fix; that test is.

### Fixed
- **Search no longer confirms values the UI redacts.** `redact_args` masked
  `api_token` everywhere it was displayed, but the search box matched the **raw**
  argument — so `q=sk_live_S` found the row and `q=sk_live_X` did not, and a secret
  could be read out one character at a time. A sixteen-character token falls in a
  couple of hundred queries, to someone who can see the console and not the secrets,
  which is the whole population `redact_args` exists for. The same needle scoped a
  dry run, so the oracle worked through the confirm screen too.

  Arguments are now searched exactly as they are displayed — redacted. With nothing
  configured for redaction, behaviour is unchanged.

- **A query is bounded, and an over-long one is refused rather than truncated.** A
  megabyte of `q` against twenty thousand entries took five seconds; the substring
  scan is linear in both, so the needle was a free multiplier on the server's CPU.
  Queries over 500 characters now select nothing and cannot authorise a bulk action.
  Refused, not truncated: a shorter needle matches *more*, and this predicate drives
  Delete.

  Argument matching also moved behind the cheap fields, so an entry only pays to
  stringify its arguments when nothing else has already matched.

- **A dry run of two jobs could confirm the deletion of five.** The bulk-preview
  confirm form carried `op`, `q`, `tag` and `queue` — and not `class` or `error`. So
  previewing `?op=delete&q=stripe&class=BillingWorker` listed 2 jobs, and the POST it
  produced deleted all 5 matching `q` alone, reporting "Deleted 5 matching job(s)"
  as though that had been approved. The preview *links*, the pager, the queue pills,
  the tag chips and every search form had the same hole in different places.

  `bulk_matches`'s own comment promises the dry run and the action "cannot disagree
  about what matching means". They could, because they were handed different filters.

  Filter state now has exactly one serialization point (`active_filters`), and every
  URL and form starts from all of it and names only what it changes
  (`filter_url` / `filter_params`) — so omitting a filter is not expressible. Nine
  hand-enumerating sites removed.

  The test that was supposed to catch this was named
  `test_the_confirm_form_carries_every_filter` and asserted **four** filters by hand,
  so adding a fifth left it green. It is driven by `FILTER_KEYS` now, and a new
  structural test fails if anything anywhere enumerates filter params by hand.

- **An unfiltered `bulk_all` deleted the whole set.** `POST /dead/bulk_all` with
  nothing but `op=delete` — no query, tag, class, error or queue — emptied the dead
  set up to the 1,000 cap and reported "Deleted 50 matching job(s)" as though that
  were the request. Same for retries. With no filter every entry matches:
  `entry_selected?` finds nothing to fail, `"".present?` is false, and
  `return true if tag.nil?` does the rest.

  The action's own comment claimed it was "only offered when a filter is active" —
  and it was only *offered* that way. The view hid the button; the route had no gate
  at all. The refusal now lives inside `bulk_matches`, the one place both the dry run
  and the action pass through, rather than in a `before_action` the next destructive
  action can forget. `any_filter?` delegates to the same predicate, so the button the
  view offers and the scope the route enforces cannot drift apart again.

  The checkbox `bulk` action is deliberately unaffected: an explicit list of jids
  *is* a scope.

- **The Processed and Failed cards plotted a line that could only go up.** Both are
  lifetime counters, so their sparkline was a monotonic ramp whose slope carried the
  whole signal and whose level is what the eye reads — and on Failed, auto-scaled
  around 131,000, a few hundred new failures rendered as a flat line with a step.
  They now plot the rate: what arrived since the last poll. Busy threads and Backlog
  are levels and keep plotting themselves, because differencing them would discard
  the thing worth seeing.
- **The Processed card's "/min" never updated.** The poll used
  `querySelector('[data-stat="rate"]')`, and the header carries the same attribute —
  so only the header was ever written and the card read `— / min` forever.

- **The Actions column stopped wrapping.** Five controls in one right-aligned cell
  and `text-align:right` does not stop a cell breaking between inline-blocks, so
  Delete dropped onto a second line as soon as the "find more like this" glass and
  Edit both appeared. The cell is marked and told not to wrap; auto table layout
  gives the width back to the error-message column, which has it to spare.
- **The dashboard's top-failing panel drew a vendor lockup on every row** — five
  stacked wordmarks. One legend above the list and a compact icon in the row, the
  same treatment the Errors page already uses. Its dividers also moved from
  `--line-soft`, which is for separating cells inside a table and disappears
  between list entries, so five rows read as one block of text.

- **Every bulk action on the Dead set was impossible.** Retry and Delete on the
  selected rows failed with `ActionController::InvalidAuthenticityToken` while
  submitting a token that looked entirely valid.

  The bulk form wrapped the table, so each row's `button_to` form was nested inside
  it. Nested forms are invalid HTML — the parser closes the outer form at the first
  `</form>` — so the bulk form ended up carrying a row action's CSRF token as well
  as its own. Rails keeps the last of a duplicated parameter, which meant verifying
  a per-form token minted for `/dead/:jid/retry` against a POST to `/dead/bulk`.

  The form is now empty and sits beside the table; the checkboxes join it with
  `form="rh-bulk-dead"`, the same HTML association the toolbar buttons already
  used. A new test asserts no index view nests a form at all.

- **The Errors page said "1 issues".** The only hardcoded plural left in the app;
  every other count already went through `pluralize`.
- **A capped occurrence count now reads as a floor.** Past the scan limit the count
  is a lower bound, not a total, and the note under the table could not fix a
  number printed as though it were exact. Truncated counts render as `1,000+`.
- **A restored snapshot is now a queue Sidekiq and Roundhouse can both see.**
  `Sidekiq::Queue#clear` removes the queue's name from the `queues` set as well as
  deleting the list, and that set is what `Sidekiq::Queue.all` reads. Restore pushed
  the payloads back but never re-registered the name — so purge → restore returned
  the jobs to a queue the Queues page did not list and no summary counted. The
  operator purged production, restored, and every page said nothing came back.

  Found by the new real-Redis tests, on their first run. Nothing in the existing
  suite could have caught it.

- **`warn_once` warns once.** It was named for what it was meant to do and logged
  every time. A `job_tags` or `job_runbooks` resolver that raises raises for every
  entry in a scan, so one broken lambda wrote a line per job — a thousand identical
  lines for a single page render, which is how a warning stops being read. It now
  deduplicates per message, per process, with a bounded memo so a resolver whose
  message varies cannot grow it without limit. Both copies (Tags and Runbooks) now
  call one implementation on `RoundhouseUi`, alongside `duration`.

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
