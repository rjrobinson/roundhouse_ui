# Roundhouse
<img width="4460" height="3152" alt="CleanShot 2026-07-01 at 09 42 17@2x" src="https://github.com/user-attachments/assets/3484709b-9c4f-449e-8776-53ad2de4781f" />
**A modern, real-time web UI for Sidekiq and Solid Queue.**

[![CI](https://github.com/rjrobinson/roundhouse_ui/actions/workflows/ci.yml/badge.svg)](https://github.com/rjrobinson/roundhouse_ui/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/roundhouse_ui)](https://rubygems.org/gems/roundhouse_ui)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)
[![Rails](https://img.shields.io/badge/rails-%3E%3D%207.0-D30001?logo=rubyonrails&logoColor=white)](https://rubyonrails.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](MIT-LICENSE)

Roundhouse is a mountable Rails engine — a control plane built for the way you
actually operate background jobs: a high-signal dashboard, searchable sets, grouped
errors, smart bulk actions, safe queue management, and job inspection/editing. It
reads through a **backend port**, so the same UI drives **Sidekiq** or **Solid
Queue** (see [Backends](#backends)). All server-rendered with Turbo — **no build
step, no frontend dependency** — and **no Sidekiq Pro required**.

> Gem name is `roundhouse_ui`; the brand and mount path are **Roundhouse**.

## Features

- **High-signal dashboard** — a composite health verdict (error rate + queue latency + utilization, with a "why"), *top failing job classes* and *problem queues* panels, and a live throughput chart with a configurable interval — all refreshing in place (polling pauses when the tab is hidden).
- **Grouped errors** — failures fingerprinted by `class + error`, so one bad deploy is a single issue with a count, not thousands of rows.
- **Smart bulk actions** — retry/delete every job matching a filter (not just the visible page), plus select-and-act on Dead.
- **Search** — across the dead/retry/scheduled sets by class, JID, error, or argument value.
- **Queue management** — pause/resume, purge with an impact count, and **snapshot → restore**.
- **Job inspection & editing** — full args (with redaction), error, and collapsible backtrace; edit & re-enqueue, or enqueue a new job (opt-in).
- **Per-class durations** (opt-in) — the slowest job classes, which Sidekiq doesn't track.
- **Audit log** — every state-changing action recorded and attributable.
- **⌘K command palette**, light/dark themes, compact/full-width toggle, read-only mode, and a strict self-contained CSP.

Sidekiq-specific extras: **Workers** (quiet/stop, threads, heartbeat), **Redis pressure** (eviction-policy check for silent job loss), and **Capsules**.

There's **no database of its own** — Roundhouse reads your job backend directly (Sidekiq via its API, Solid Queue via its tables).

## Requirements

- Ruby >= 3.1 · Rails >= 7.0 · Sidekiq >= 6.5 (or Solid Queue — see Backends)

## Installation

```ruby
# Gemfile
gem "roundhouse_ui"
```

## Backends

Roundhouse reads through a **backend port**, so the same UI can drive different
job systems. It defaults to **Sidekiq**; point it at **Solid Queue** in an
initializer:

```ruby
# config/initializers/roundhouse.rb
RoundhouseUi.backend = RoundhouseUi::Backends::SolidQueue.new
```

The UI adapts to each backend's capabilities — on Solid Queue, queue **pause is
native** (no fetcher, no warning), and the **Retries / Redis / Capsules / Workers**
sections hide (Solid Queue has no distinct retry set, isn't Redis-backed, and
processes are a follow-up). Dashboard, Queues, Scheduled, Dead, Busy, and the
grouped Errors view all work on both. See
[docs/adr/0001](docs/adr/0001-backend-port-multi-queue.md).

> Running **both** Sidekiq and Solid Queue in one app (e.g. mid-migration)? That's
> [#17](https://github.com/rjrobinson/roundhouse_ui/issues/17) — for now, one
> backend per Roundhouse instance.

## Mounting

Roundhouse is auth-agnostic — wrap the mount in whatever your app already uses.

```ruby
# config/routes.rb
authenticate :user, ->(u) { u.admin? } do        # Devise example
  mount RoundhouseUi::Engine => "/roundhouse"
end
```

It ships **no authentication** — always mount it behind yours; it exposes operational
controls over your job system.

## Configuration

```ruby
# config/initializers/roundhouse.rb
RoundhouseUi.configure do |c|
  # Disable every destructive action (purge/retry/delete/edit) server-side.
  c.read_only = !Rails.env.development?

  # Enqueue new jobs and edit/re-enqueue existing ones from the UI (sharp tool — off by default).
  c.allow_job_editing = Rails.env.development?

  # Mask sensitive argument keys (case-insensitive substring) wherever args are displayed.
  c.redact_args = %w[password token secret api_key authorization]

  # Attribute audit entries to the signed-in user instead of "anonymous".
  c.actor_resolver = ->(controller) { controller.current_user&.email }

  # Deep-link jobs out to your APM (see Observability).
  c.observability = RoundhouseUi::Observability::DatadogAdapter.new(service: "my-app")

  # Where queue snapshots are stored (default: Redis). Swap for a file/S3 store.
  # c.snapshot_store = MyS3SnapshotStore.new

  # Fold sidekiq-failures' `failed` set into the Errors view (see below).
  # No-op unless the sidekiq-failures gem is loaded. Default: off.
  c.show_sidekiq_failures = true

  # Set false to hide queue pause/resume controls entirely. Rarely needed — on
  # Sidekiq Pro and Solid Queue pause is enforced natively, and on OSS Sidekiq
  # installing RoundhouseUi::Fetch enforces it. Default: true.
  # c.pause_enabled = false

  # Seconds between dashboard stat polls (default 5). Raise it if polling shows
  # up in your traces — each poll re-runs the host's auth/routing on the mount.
  # c.poll_interval = 10

  # Show the "slowest job classes" table on the Metrics page. The flag alone shows
  # nothing — it also needs the DurationCollector middleware (see below).
  # Default: false.
  # c.collect_durations = true
end
```

Every option is independent and has a safe default — **set only what you need**. Nothing
here is required to mount Roundhouse.

### When to turn each one on

| Option | Default | Turn it on when | Leave it alone when |
|---|---|---|---|
| `read_only` | `false` | **Production, almost always.** Blocks purge/retry/delete/edit *server-side*, not just in the UI — so it holds even if someone hand-crafts a request. The usual shape is `!Rails.env.development?`. | You need operators to actually fix things from the UI, and you trust everyone behind the mount. |
| `redact_args` | `[]` | **Any app whose job args carry secrets or PII** — args render in full on the job page. Matches keys case-insensitively as substrings, and walks nested hashes/arrays. | Args are all IDs and enum values. |
| `actor_resolver` | `"anonymous"` | You want the audit log to name *who* did something. One line: `->(c) { c.current_user&.email }`. | Single-operator app, or you already audit at another layer. |
| `allow_job_editing` | `false` | Development and debugging. **Sharp tool** — a bad edit creates an unrunnable job, and it lets the UI enqueue arbitrary classes. | Production, unless you specifically want that power and have `read_only` off anyway. |
| `observability` | no-op | You run an APM and want per-job deep links out to it. Ships a Datadog adapter; duck-type `job_url`/`queue_url`/`error_url` for anything else. | No APM, or you'd rather not add links that only some people can open. |
| `snapshot_store` | Redis | Your snapshots are large or need to outlive Redis (S3/disk). Duck-type `write`/`read`/`delete`/`ids`. | Redis is fine — which it usually is for occasional queue snapshots. |
| `show_sidekiq_failures` | `false` | You use the `sidekiq-failures` gem **and** run jobs with `retry: false` — those never enter Sidekiq's retry/dead sets, so this is the only way to see them. | You don't have the gem (it's a no-op then anyway). |
| `poll_interval` | `5` | **Raise it** if dashboard polling shows up in your traces — every poll re-runs your app's auth and routing on the mount, so a busy console adds real load. Lower it only for a livelier demo. | Default is fine for most apps. |
| `collect_durations` | `false` | You want "slowest job classes" on Metrics, which Sidekiq doesn't track. **Also requires installing the `DurationCollector` middleware** — the flag alone shows nothing. Costs one pipelined Redis round-trip per job. | You already get per-job timing from your APM. |
| `pause_enabled` | `true` | Leave it on. | **Rarely set this to `false`.** Pause is enforced natively on Sidekiq Pro and Solid Queue, and on OSS Sidekiq by installing `RoundhouseUi::Fetch` — so turning it off usually just hides a working feature. Only useful if you want the controls gone entirely. |

Two that pair with a middleware rather than working alone: `collect_durations`
(`DurationCollector`) and job cancellation (`CancelMiddleware`) — see
[Cancelling jobs](#cancelling-jobs) and [Slowest job classes](#slowest-job-classes).

## Pausing queues

> Pause is **native** — enforced with nothing to install and no warning — on both
> **Solid Queue** and **Sidekiq Pro/Enterprise** (see below). The fetch strategy
> below is only needed on **OSS Sidekiq**.

On OSS Sidekiq, pause/resume is pure OSS. To make a pause actually stop a queue from
being worked, install Roundhouse's fetch strategy in your Sidekiq **server** config:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config[:fetch_class] = RoundhouseUi::Fetch
end
```

`RoundhouseUi::Fetch` subclasses `Sidekiq::BasicFetch` and skips paused queues, inheriting
all of Sidekiq's weighting/ordering. Until it's installed, the Queues page records pauses
but **warns that they aren't enforced** (worker and web are separate processes, so
Roundhouse detects whether a fetcher has reported in).

### Sidekiq Pro / Enterprise — nothing to install

Pro ships its own enforced pause, and Roundhouse uses it automatically. Pro reopens
`Sidekiq::Queue` with `pause!`/`unpause!` and *prepends* pause support onto
`Sidekiq::BasicFetch` (`super_fetch` honors it too), so **any Pro worker enforces
pauses** whether or not a fetch strategy is configured.

When Roundhouse detects Pro it delegates pause/resume to `Sidekiq::Queue#pause!`,
reads paused state from Pro's registry, advertises `native_pause`, and drops the
"not enforced" warning. So on Pro:

- **Don't** install `RoundhouseUi::Fetch` — it isn't needed, and on `super_fetch`
  installs it would displace reliable fetch and lose its crash-recovery guarantees.
- **Don't** set `pause_enabled = false` — pause genuinely works; disabling it only
  hides a feature you already have.

Roundhouse always goes through `Sidekiq::Queue#pause!` rather than writing Pro's
Redis key directly: Pro's fetchers read that set once at startup and afterwards
only update on the `pro:config` pubsub message `pause!` publishes, so a raw write
would leave running workers pulling the queue until they restarted.

## Surfacing sidekiq-failures

If you use [`sidekiq-failures`](https://github.com/mhfs/sidekiq-failures), failures it
records live in their own Redis set — which Roundhouse doesn't read by default. Jobs with
`retry: false` are the common case: they fail, get recorded there, but never enter the
retry or dead sets, so they're invisible in Roundhouse. Opt in to fold them into the
grouped **Errors** view:

```ruby
# config/initializers/roundhouse.rb
RoundhouseUi.configure { |c| c.show_sidekiq_failures = true }
```

It's a no-op unless `sidekiq-failures` is loaded. Failures appear in **Errors** grouped by
job class + error (not yet as an individual-job list with per-row actions).

## Cancelling jobs

Cancellation is cooperative — Ruby can't safely kill a running thread. Install the
middleware so a cancelled job is dropped before it runs:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.server_middleware { |chain| chain.add RoundhouseUi::CancelMiddleware }
end
```

The **Busy** page's Cancel button flags a job's JID. A queued/scheduled/retrying job
is then skipped when it would next run; a *currently running* job stops only if it
checks in — e.g. a long loop can `break if RoundhouseUi.cancelled?(jid)`.

**Timing and cost.** The middleware is close to free when nothing is cancelled: rather
than checking each job's JID against Redis, it asks "is *anything* cancelled?" from a
process-local gate refreshed at most every 2s, and only does the exact per-job lookup
while cancellations are pending. The tradeoff is that a cancellation takes **up to ~2s
to reach a worker process** — the UI and your workers are separate processes, so expect
a brief lag after clicking Cancel. Jobs already in flight are unaffected either way
(cancellation is cooperative), and `RoundhouseUi.cancelled?(jid)` — what a long-running
job polls — is never gated, so it always reads current state.

## Slowest job classes

Sidekiq doesn't track per-class durations, so Roundhouse can record them itself.
Install the opt-in server middleware and set `collect_durations = true`; the
Metrics page then lists the slowest classes by total time (count + average).

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.server_middleware { |chain| chain.add RoundhouseUi::DurationCollector }
end
```

It's two cheap Redis writes per job (a counter + a summed-ms float) into a single hash,
pipelined into **one round-trip**, and a job failure never propagates from the collector.

## Bulk actions on a filter

On **Retries** and **Dead**, searching narrows the set; with a filter active you
can retry or delete **every** matching job in one action (not just the visible
page), capped at 1,000 per run. Gated to when a filter is present so it can't
become "retry everything", `read_only`-aware, and audit-logged.

## Observability deep-links

The core depends on nothing — it asks the configured adapter for a URL and renders a link
only if one comes back. A Datadog adapter ships in the box; write your own by duck-typing
`job_url` / `queue_url` / `label`:

```ruby
RoundhouseUi.observability = RoundhouseUi::Observability::DatadogAdapter.new(site: "datadoghq.com", service: "my-app")
```

## Snapshots

Back up a queue before purging it (the safety net for clearing a stuck queue), then restore.
Storage is pluggable via `RoundhouseUi.snapshot_store` (default: Redis). For large/stuck
queues use a file or S3 store so the backup doesn't sit in the Redis you're trying to relieve.

## Security

- All destructive actions are CSRF-protected `POST`s — never GET — and gated by `read_only`.
- Roundhouse sets its own strict, self-contained Content-Security-Policy on its responses
  (nonce'd inline script, same-origin only), so it's safe even if the host sets no policy.
- Configure `redact_args` to keep tokens/PII out of the UI; the audit log records who did what.

## Keyboard

`⌘K` (or `Ctrl+K`) opens the command palette — jump to any view or action.

## Development

```bash
bin/rails test      # full suite, ~1s, no Redis required (Sidekiq's API is stubbed)
bundle exec rubocop # lint
```

The dummy app under `test/dummy` mounts the engine at `/roundhouse`; point it at a local
Redis and run `bin/rails server` to click around.

## Roadmap

- Solid Queue: Workers view + enqueue, and the multi-DB (separate queue database) case.
- Watch Sidekiq **and** Solid Queue from one install ([#17](https://github.com/rjrobinson/roundhouse_ui/issues/17)).
- Multi-Redis / multi-cluster view (one pane across shards).
- Cron/periodic (recurring) views.

## Contributing

Bug reports and pull requests welcome at https://github.com/rjrobinson/roundhouse_ui.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
