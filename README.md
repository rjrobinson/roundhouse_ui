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
- **⌘K command palette**, read-only mode, and a strict self-contained CSP.
- **Per-person settings** — light/dark, palette, content width and refresh interval, stored in the browser; nothing server-side to share or migrate. Hosts can set the palette for everyone, or withdraw the choice.

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
  c.observability = RoundhouseUi::Observability::DatadogAdapter.new(service: "sidekiq")

  # Where queue snapshots are stored (default: Redis). Swap for a file/S3 store.
  # c.snapshot_store = MyS3SnapshotStore.new

  # Fold sidekiq-failures' `failed` set into the Errors view (see below).
  # No-op unless the sidekiq-failures gem is loaded. Default: off.
  c.show_sidekiq_failures = true

  # Set false to hide queue pause/resume controls entirely. Rarely needed — on
  # Sidekiq Pro and Solid Queue pause is enforced natively, and on OSS Sidekiq
  # installing RoundhouseUi::Fetch enforces it. Default: true.
  # c.pause_enabled = false

  # Surface your own labels (owning team, tenant, …) on job rows, the job page,
  # and grouped errors — and filter by them. See "Job tags" below.
  # c.job_tags = RoundhouseUi::Tags.from_constant(:OWNER, as: :squad)
  # c.job_runbooks = RoundhouseUi::Runbooks.from_constant(:RUNBOOK)

  # Recolour the UI — pure CSS custom properties, no build step. See "Theming".
  # c.theme = { accent: "#FF2BD1", accent_2: "#00E5FF" }
  # c.themes = RoundhouseUi::Theme::PRESETS.slice(:catppuccin, :nord, :gruvbox)
  # c.allow_theme_selection = false

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
| `job_tags` | `nil` | You already know which team, tenant or product area owns a job — usually as a constant on the class — and want that visible and filterable in the UI. See [Job tags](#job-tags). | Every job belongs to the same team. |
| `job_tags_per_job` | `false` | **Only** when `job_tags` reads the payload (tagging by tenant, account, …). Costs one resolver call per row rather than one per class. | Tags derive from the job class, which is the common case. |
| `tag_filters` | `nil` | You want stable filter dropdowns instead of ones that only list what happens to be on screen — and want filtering on an unknown key to match nothing. | The `?tag=` URL is enough. |
| `job_runbooks` | `nil` | Your jobs have runbooks and you'd rather not make someone find them at 3am. | There's nothing to link to yet. |
| `job_class_namespaces` | `nil` | You want to bound which constants a job payload can cause Roundhouse to resolve. See [Security](#security). | Your job payloads come only from your own app, which is the normal case. |
| `theme` | `nil` | You want Roundhouse to match your own admin's palette, or you just want it to look different. Partial themes are fine — unset tokens keep their shipped values. See [Theming](#theming). | The shipped light/dark pair is fine. |
| `icons` | `:svg` | You already ship FontAwesome and would rather Roundhouse used it — `:font_awesome`, or a Hash of `{ name => "class names" }`. Roundhouse never loads a font itself either way. | You want the shipped inline SVG, which needs nothing installed. |
| `themes` | shipped presets | You want people to pick their own palette on the Settings page. | Everyone should see the same thing — set `theme` instead, or `allow_theme_selection = false`. |
| `allow_theme_selection` | `true` | Leave it on. | Recolouring a production console isn't something you want an operator doing. |
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

## Icons and motion

Icons are inline SVG — no font, no request, no CSP change, and the same shape on
every platform. If you already ship an icon font, use it instead:

```ruby
RoundhouseUi.icons = :font_awesome
RoundhouseUi.icons = { dashboard: "fa-solid fa-gauge-high", queues: "my-icon" }
```

Roundhouse never loads a font itself in either mode — it emits class names and
your pipeline supplies the glyphs, which is what keeps the self-contained CSP
intact. An unknown name renders nothing rather than raising.

Motion is limited to effects that carry information: a polled value flashes when
it actually changes, a queue that will not drain pulses slowly, rows settle in on
navigation, and the refresh arc depletes. All of it is dropped under
`prefers-reduced-motion`.

## Theming

The UI's colours are CSS custom properties. Override any of them from an
initializer — pure CSS, no build step, no stylesheet to fork:

```ruby
RoundhouseUi.theme = { accent: "#FF2BD1", accent_2: "#00E5FF" }
```

A colour that reads well on near-black rarely reads well on near-white, so you
can speak to each mode separately:

```ruby
RoundhouseUi.theme = {
  dark:  { bg: "#0A0511", panel: "#140A24", accent: "#FF2BD1" },
  light: { bg: "#FFF7FB", panel: "#FFFFFF", accent: "#B3009E" }
}
```

Anything you leave unset keeps its shipped value, so partial themes are fine.
Keys are token names with underscores for dashes — `accent_2` sets `--accent-2`.

Available tokens: `bg`, `panel`, `panel_2`, `panel_3`, `line`, `line_soft`,
`text`, `muted`, `faint`, `accent`, `accent_2`, `good`, `warn`, `crit`, `mono`,
`sans`.

### What's in the box

Eleven presets. Ten of them ship the light **and** dark variant their own
authors designed, so choosing a palette is never a choice to give up light mode:

| Preset | Dark | Light |
|---|---|---|
| `catppuccin` | [Catppuccin](https://github.com/catppuccin/catppuccin) Mocha | Latte |
| `catppuccin_macchiato` | Catppuccin Macchiato | Latte |
| `catppuccin_frappe` | Catppuccin Frappé | Latte |
| `rose_pine` | [Rosé Pine](https://github.com/rose-pine/rose-pine-theme) Main | Dawn |
| `rose_pine_moon` | Rosé Pine Moon | Dawn |
| `nord` | [Nord](https://github.com/nordtheme/nord) Polar Night | Snow Storm |
| `gruvbox` | [Gruvbox](https://github.com/morhetz/gruvbox) Dark | Light |
| `everforest` | [Everforest](https://github.com/sainnhe/everforest) Dark | Light |
| `kanagawa` | [Kanagawa](https://github.com/rebelot/kanagawa.nvim) Wave | Lotus |
| `solarized` | [Solarized](https://github.com/altercation/solarized) Dark | Light |

The eleventh is `cyberpunk` — deliberately loud, and dark-only, which Settings
labels so, because a dark-only palette is simply inert in light mode.

Catppuccin and Rosé Pine each ship one light flavour and several dark ones, so
their entries share a light half. That's upstream's own design rather than a
shortcut here, which is why the preset name says which dark flavour you get.

```ruby
RoundhouseUi.theme = RoundhouseUi::Theme::PRESETS[:kanagawa]
```

> **Role mapping is where the judgement is.** Every project names its swatches
> differently and none of them has our token set, so the mapping is the part
> that can be wrong while every colour is right. Two rules do most of the work:
> `panel` must lift off `bg`, and `line` must be *soft* — the shipped theme
> draws borders at 1.20:1 against their own panel. Reaching one surface step too
> far is the easy mistake and it does not look like a colour bug, it looks like
> the theme is broken: it put Nord's light border at 6.4:1 and Rosé Pine's dark
> border at 3.2:1, a hard outline around every button and input. Tests hold each
> palette to that band, so a new palette cannot regress it.
>
> Every one of the 280 values is lifted from the project's own palette file —
> `palette.json`, `gruvbox.vim`, `nord.css`, `colors.lua` — not transcribed by
> eye, and the test suite asserts each one still renders. Because every project
> names its swatches differently, the role mapping is the part with judgement in
> it: `panel` has to read as distinct from `bg`, `panel_2` has to be dark (or
> light) enough for `muted` text to sit on, and `line_soft` has to differ from
> `panel` or card borders vanish. Tests hold each palette to contrast floors as
> well as to those structural rules — Nord's own comment grey lands at 1.36:1 on
> its own panel, and that is exactly the kind of thing a list of hex values
> cannot show you.

### Letting people pick

`theme` is what everyone sees. If you'd rather offer a menu, name the palettes
and each person picks one on the Settings page:

```ruby
RoundhouseUi.themes = {
  cyberpunk: RoundhouseUi::Theme::PRESETS[:cyberpunk],
  midnight:  { dark: { bg: "#000000", panel: "#0A0A0A" } }
}
```

All eleven shipped presets are on offer by default — trim the list if that's
more choice than you want in a production console. A palette beats `theme`, and
"Default" on that page means whatever `theme` you configured, so a host palette
is the floor rather than something a viewer can be stranded away from.

Every offered palette is emitted as CSS on every page: all eleven cost about
1.5 KB gzipped, so this is a taste question, not a performance one.

Withdraw the control entirely where recolouring a production console isn't
something an operator should be doing:

```ruby
RoundhouseUi.allow_theme_selection = false
```

The browser stores which palette by name, never the colours, so a tampered
`localStorage` value can only select a palette you already configured.

## Settings

`/settings` holds the per-person preferences: light or dark, palette, content
width, and how often pages refresh. Everything there lives in that browser's
local storage — nothing is written server-side, so one person's choices never
change what anyone else sees, and there's no state to migrate or clean up. A
private window starts fresh.

The refresh interval is worth a word: every tick runs your app's own
authentication and routing, so it isn't free. Whatever you set for
`poll_interval` is the default and is named on the page; a viewer can go faster
or slower within 2–300 seconds.

## Runbooks

Whoever wrote the job knows what to do when it fails. The person paged at 3am
usually does not. Point Roundhouse at whatever you already have:

```ruby
# a constant on the class, same convention as job tags
RoundhouseUi.job_runbooks = RoundhouseUi::Runbooks.from_constant(:RUNBOOK)

# or a plain map
RoundhouseUi.job_runbooks = { "Billing::SyncWorker" => "https://wiki/billing" }

# or any callable
RoundhouseUi.job_runbooks = ->(klass:, item:) { "https://wiki/jobs/#{klass}" }
```

A **Runbook** link then appears on the job page and on each grouped error row —
the two places someone lands during an incident. Resolved at read time like
tags, so it applies to jobs already in the sets, with no middleware and nothing
stored. Inherited constants count, so one base class can carry a runbook for a
whole family, and ActiveJob-wrapped jobs resolve by their real class.

> Only `http`/`https` URLs render. The value lands in an `href`, where no amount
> of escaping makes `javascript:` safe, so the scheme is checked instead — a
> misconfigured host gets no link rather than a link that runs. Links open in a
> new tab with `rel="noopener noreferrer"`.

## Job tags

Most apps already know who owns a job — commonly a constant on the class. Point
Roundhouse at it and that label shows up as a badge on Retries, Dead, Scheduled, the
job detail page and grouped Errors, and becomes a filter.

```ruby
# config/initializers/roundhouse.rb
RoundhouseUi.job_tags = RoundhouseUi::Tags.from_constant(:OWNER, as: :squad)
```

That's the whole setup for the `OWNER = :growth` convention — every class defining the
constant (including by inheritance) is tagged. Any callable works if your labels come
from somewhere else:

```ruby
RoundhouseUi.job_tags = ->(klass:, item:) {
  { squad: OwnershipMap.for(klass), tier: klass.end_with?("CriticalJob") ? "p1" : "p3" }
}
```

Tags are resolved **when a page renders** — no middleware, no enqueue changes, nothing
stored. They apply retroactively to jobs already sitting in the sets, and work the same
on Sidekiq and Solid Queue. `klass` is always the real job class: the ActiveJob adapter's
wrapper is unwrapped before your resolver sees it. See
[ADR 0002](docs/adr/0002-job-tagging.md).

### Filtering

`?tag=key:value` filters Retries, Dead and Scheduled — for example
`/roundhouse/retries?tag=squad:growth`. It combines with the search box, survives
pagination, and **applies to bulk actions too**, so "delete all matching" acts on exactly
the rows shown and never more.

Declare a vocabulary to get stable dropdowns instead of relying on the URL:

```ruby
RoundhouseUi.tag_filters = { squad: %w[core training growth platform ops ai] }
```

Values may be a callable if the list is dynamic. Once declared, filtering on a key you
didn't declare matches nothing rather than everything.

### Cost and safety

- By default the resolver is treated as a **pure function of the job class** and is called
  once per class per request — a 1,000-row page costs a handful of calls, not 1,000. If
  your resolver reads the payload, set `RoundhouseUi.job_tags_per_job = true`; it will
  then be called once per row, so keep it cheap.
- Tag values pass through `redact_args`, so a tag keyed `tenant_token` masks itself. This
  is key-based only — a tag *named* `squad` whose *value* is sensitive is not masked.
- A resolver that raises is caught and logged; the page renders without tags rather than
  failing.

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
RoundhouseUi.observability = RoundhouseUi::Observability::DatadogAdapter.new(site: "datadoghq.com", service: "sidekiq")
```

`service:` is the service your **Sidekiq spans** carry, which is frequently *not* your
app name — apps commonly set `c.tracing.instrument :sidekiq, service_name: "sidekiq"`,
and dd-trace has no default of its own. Passing your app name when the spans say
something else produces links that silently match nothing. Omit it if you're unsure:
the term is left out of the query entirely when nil.

## Snapshots

Back up a queue before purging it (the safety net for clearing a stuck queue), then restore.
Storage is pluggable via `RoundhouseUi.snapshot_store` (default: Redis). For large/stuck
queues use a file or S3 store so the backup doesn't sit in the Redis you're trying to relieve.

## Security

**Constant resolution from job payloads.** `Tags.from_constant` and
`Runbooks.from_constant` read a constant off the job class, which means turning
`item["class"]` — a string out of Redis — into a Class. Worth knowing precisely
what that does and does not expose:

- Malformed names never reach a lookup. Ruby rejects `"../../etc/passwd"` as a
  constant path before attempting to resolve anything, so no autoload occurs.
- A **well-formed name of a class that really exists** does resolve, and
  resolving a class loads it. In production this is close to inert: Rails sets
  `eager_load = true`, so every app constant is already loaded and no new file
  is executed.
- Writing a crafted payload requires Redis write access — which, on a Sidekiq
  install, already permits enqueuing a real job, a more serious compromise than
  this.

Two ways to tighten it if your payloads are not fully trusted:

```ruby
# Bound which constants may be resolved at all
c.job_class_namespaces = %w[Workers Jobs Billing]

# Or resolve nothing: a Hash never constantizes
c.job_tags = ->(klass:, item:) { { squad: OWNER_MAP[klass] } }
c.job_runbooks = { "Billing::SyncWorker" => "https://wiki/billing" }
```


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
