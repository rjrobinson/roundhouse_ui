# Roundhouse
<img width="4460" height="3152" alt="CleanShot 2026-07-01 at 09 42 17@2x" src="https://github.com/user-attachments/assets/3484709b-9c4f-449e-8776-53ad2de4781f" />

<!-- TODO: demo GIF -->

[![CI](https://github.com/rjrobinson/roundhouse_ui/actions/workflows/ci.yml/badge.svg)](https://github.com/rjrobinson/roundhouse_ui/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/roundhouse_ui)](https://rubygems.org/gems/roundhouse_ui)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)
[![Rails](https://img.shields.io/badge/rails-%3E%3D%207.0-D30001?logo=rubyonrails&logoColor=white)](https://rubyonrails.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](MIT-LICENSE)
[![Buy Me A Coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-ffdd00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/rjrobinson)

Roundhouse is a real-time ops UI for Sidekiq and Solid Queue — grouped errors,
argument search, bulk actions on a filter, enforced pause, snapshots, and an
audit log — in one mountable engine with no build step.

It works on OSS Sidekiq, and it works better on [Sidekiq Pro and
Enterprise](#buy-sidekiq-pro-and-enterprise) — which you should buy.

## Buy Sidekiq Pro and Enterprise

[**Sidekiq Pro and Enterprise**](https://sidekiq.org/products/pro.html) are worth the
money. Buy them.

Sidekiq is the reason any of this exists, and the commercial tiers are what keep it
maintained. Pro gives you reliable fetch (jobs survive a hard crash), batches, expiring
jobs and native queue pause; Enterprise adds rate limiting, unique jobs, periodic jobs,
multi-process and historical metrics. Roundhouse detects all of it and gets better when
it is there — native pause with no fetch strategy to install, Enterprise periodic jobs
on the Recurring page.

Roundhouse is not a way to avoid paying for Sidekiq. It is a UI. If you are running
Sidekiq seriously enough to want this, you are running it seriously enough to buy Pro.

> Roundhouse is not affiliated with or endorsed by Contributed Systems LLC. Sidekiq,
> Sidekiq Pro and Sidekiq Enterprise are their trademarks.

## Support this project

If Roundhouse saved you an incident, [buy me a coffee](https://buymeacoffee.com/rjrobinson).
Buy Sidekiq Pro first.

## Why

I wrote this during an incident where I needed to know which jobs for one
customer had failed, and whether I could retry only those. Sidekiq::Web gave me
a retry set of forty thousand rows, twenty-five at a time, with no search. So I
opened a Rails console at 2am and started writing `Sidekiq::RetrySet.new.select`
against production — which is not where anyone should be deciding what to retry.

Roundhouse answers that question in the browser, and records who answered it.

## Install

```ruby
# Gemfile
gem "roundhouse_ui"

# config/routes.rb — mount behind your own auth; Roundhouse ships none
authenticate :user, ->(u) { u.admin? } do
  mount RoundhouseUi::Engine => "/roundhouse"
end

# config/initializers/roundhouse.rb — only if you're on Solid Queue
RoundhouseUi.backend = RoundhouseUi::Backends::SolidQueue.new
```

## What you get

- **Grouped errors** — failures fingerprinted by class + error, so one bad deploy is one row with a count, not thousands.
- **One filter bar** — `class=BillingWorker error=Timeout::Error stripe` in a single box. Facets match exactly, `%` wildcards, free text searches class, JID, error and redacted arguments. The whole filter is one `?q=` parameter, so a filtered view is a URL you can bookmark and share.
- **Bulk retry or delete scoped to a filter** — every job matching your search, not just the page you can see.
- **Enforced pause** — a paused queue actually stops being worked, on OSS Sidekiq too.
- **Snapshot → restore** — back a queue up before you purge it, and put it back if you were wrong.
- **Audit log** — every state-changing action, with who did it.

The same UI drives **Sidekiq** or **Solid Queue** — see [Backends](#backends);
running both at once is [#17](https://github.com/rjrobinson/roundhouse_ui/issues/17).

Roundhouse ships no authentication, so mount it behind yours. `read_only`
disables every mutating action, `redact_args` masks sensitive arguments, and
`job_class_namespaces` limits which classes the UI will touch —
see [Security](#security).

> Gem name is `roundhouse_ui`; the brand and mount path are **Roundhouse**.

## Contents

**Setting up** ·
[Requirements](#requirements) ·
[Installation](#installation) ·
[Backends](#backends) ·
[Mounting](#mounting) ·
[Configuration](#configuration) ·
[Security](#security)

**Operating** ·
[Pausing queues](#pausing-queues) ·
[Snapshots](#snapshots) ·
[Cancelling jobs](#cancelling-jobs) ·
[Search](#search) ·
[Bulk actions on a filter](#bulk-actions-on-a-filter) ·
[Slowest job classes](#slowest-job-classes)

**Labelling and links** ·
[Job tags](#job-tags) ·
[Runbooks](#runbooks) ·
[Observability deep-links](#observability-deep-links) ·
[Surfacing sidekiq-failures](#surfacing-sidekiq-failures)

**Appearance** ·
[Theming](#theming) ·
[Settings](#settings) ·
[Keyboard](#keyboard)

**Project** ·
[Stability](#stability) ·
[Development](#development) ·
[Roadmap](#roadmap) ·
[Contributing](#contributing) ·
[License](#license)

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

  # Show the Busy page's Cancel button. Off by default because cancellation only
  # does something once you install CancelMiddleware, or have long jobs poll
  # RoundhouseUi.cancelled?(jid) themselves. See "Cancelling jobs".
  # c.cancel_enabled = true

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
| `history` | — | Not a setting. Sidekiq records daily processed and failed counts itself, so the Dashboard shows a History chart with no configuration and no storage. Hidden on Solid Queue, which has no equivalent. |  |
| `theme` | `nil` | You want Roundhouse to match your own admin's palette, or you just want it to look different. Partial themes are fine — unset tokens keep their shipped values. See [Theming](#theming). | The shipped light/dark pair is fine. |
| `icons` | `:svg` | You already ship FontAwesome and would rather Roundhouse used it — `:font_awesome`, or a Hash of `{ name => "class names" }`. Roundhouse never loads a font itself either way. | You want the shipped inline SVG, which needs nothing installed. |
| `themes` | shipped presets | You want people to pick their own palette on the Settings page. | Everyone should see the same thing — set `theme` instead, or `allow_theme_selection = false`. |
| `allow_theme_selection` | `true` | Leave it on. | Recolouring a production console isn't something you want an operator doing. |
| `pause_enabled` | `true` | Leave it on. | **Rarely set this to `false`.** Pause is enforced natively on Sidekiq Pro and Solid Queue, and on OSS Sidekiq by installing `RoundhouseUi::Fetch` — so turning it off usually just hides a working feature. Only useful if you want the controls gone entirely. |
| `cancel_enabled` | `false` | You installed `CancelMiddleware`, or your long-running jobs poll `RoundhouseUi.cancelled?(jid)`. **The flag alone cancels nothing** — without one of those, `cancel!` writes a JID nothing reads, which is why the button is hidden by default. Sidekiq only; Solid Queue has no cancellation path. | You haven't wired either check up yet. |

Two that pair with a middleware rather than working alone: `collect_durations`
(`DurationCollector`) and `cancel_enabled` (`CancelMiddleware`) — see
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

Pro ships its own enforced pause, and Roundhouse uses it automatically — **any Pro
worker enforces pauses** whether or not a fetch strategy is configured.

When Roundhouse detects Pro it delegates pause/resume to `Sidekiq::Queue#pause!`,
reads paused state from Pro's registry, advertises `native_pause`, and drops the
"not enforced" warning. So on Pro:

- **Don't** install `RoundhouseUi::Fetch` — it isn't needed, and on `super_fetch`
  installs it would displace reliable fetch and lose its crash-recovery guarantees.
- **Don't** set `pause_enabled = false` — pause works; disabling it only hides a
  feature you already have.

Roundhouse always goes through `Sidekiq::Queue#pause!` rather than writing Pro's
Redis key directly — a raw write does not reach already-running workers.

Pro's own behaviour here is described from its public API, and Roundhouse has no Pro
dependency and runs no Pro in CI. Treat it as our integration contract, not as Pro
documentation; [Sidekiq's own docs](https://github.com/sidekiq/sidekiq/wiki) are
authoritative.

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

The eleventh is `cyberpunk` — loud, and dark-only, which Settings labels, since
a dark-only palette is inert in light mode.

Catppuccin and Rosé Pine each ship one light flavour and several dark ones, so
their entries share a light half. That's upstream's own design rather than a
shortcut here, which is why the preset name says which dark flavour you get.

```ruby
RoundhouseUi.theme = RoundhouseUi::Theme::PRESETS[:kanagawa]
```

> All 280 values come from each project's own palette file — `palette.json`,
> `gruvbox.vim`, `nord.css`, `colors.lua` — rather than transcribed by eye. The
> mapping onto our tokens is what can be wrong while every colour is right:
> `panel` must lift off `bg`, `panel_2` must carry `muted` text, and `line` must
> be soft — the shipped theme draws borders at 1.20:1 against their own panel.
> One surface step too far doesn't read as a colour bug, it reads as a broken
> theme: it put Nord's light border at 6.4:1 and Rosé Pine's dark at 3.2:1, a
> hard outline around every button and input. Tests hold every palette to
> contrast floors and to those structural rules, so a new one can't regress it.

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
1.5 KB gzipped.

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

Every refresh tick runs your app's own authentication and routing, so a faster
interval isn't free. Whatever you set for
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

A **Runbook** link appears on the job page and on each grouped error row — the
two places someone lands during an incident. Resolution happens at read time
like tags, so it covers jobs already in the sets, with no middleware and nothing
stored. Inherited constants count, so one base class carries a runbook for a
whole family, and ActiveJob-wrapped jobs resolve by their real class.

> Only `http`/`https` URLs render. The value lands in an `href`, where no
> escaping makes `javascript:` safe, so the scheme is checked instead — a
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

Type `tag=squad:growth` into the search box on Retries, Dead, Scheduled, a queue's job
list, or Errors. It combines with every other filter, survives pagination, and **applies
to bulk actions too**, so "delete all matching" acts on exactly the rows shown and never
more. `?tag=squad:growth` still works as a URL — see [Search](#search).

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

Cancellation is cooperative — Ruby can't safely kill a running thread, so something
has to check. Nothing checks by default, which is why the Cancel button is hidden until
you set `cancel_enabled = true`. Install the middleware so a cancelled job is dropped
before it runs:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.server_middleware { |chain| chain.add RoundhouseUi::CancelMiddleware }
end
```

…then turn the button on with `c.cancel_enabled = true`.

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

## Search

One box per page, and everything in it travels as a single `?q=` parameter:

```
/roundhouse/dead?q=class%3DBillingWorker+error%3DTimeout%3A%3AError+stripe
```

| | |
|---|---|
| `class=` | exact job class (the real class, not the ActiveJob wrapper) |
| `error=` | exact error class |
| `queue=` | exact queue name |
| `tag=` | a declared tag, as `key:value` |
| `%` | wildcard — `class=Roundhouse%`, `class=%Worker`, `class=%oundhouse%` |
| anything else | substring across class, JID, error message and **redacted** arguments |

Facets match exactly unless you use `%`, so `queue=default` never also selects
`default_low`. `_` is a literal, not a wildcard. Quote values with spaces
(`error="Net::ReadTimeout with body"`), and use `text="account_id=1234"` for free text
that looks like a filter.

Anything the parser does not understand is **refused whole**, with the offending token
named — never dropped and never silently widened, because this box sits directly above
"delete all matching". `class=%` is refused for the same reason: a pattern with no
literal characters matches everything.

Each active facet shows as a pill in the bar with its own ×. Tab completes a key or
value; Enter applies. The `?` beside the box lists the vocabulary for that page — Errors
has no `queue=` (a class+error group spans every queue) and the Queues index has no
`class=`.

Arguments are searched **as they are displayed**, i.e. redacted. Searching the raw values
would turn the box into an oracle for the secrets `redact_args` exists to hide.

## Bulk actions on a filter

On **Retries** and **Dead**, searching narrows the set; with a filter active you
can retry or delete **every** matching job in one action (not just the visible
page), capped at 1,000 per run. Gated to when a filter is present so it can't
become "retry everything", `read_only`-aware, and audit-logged.

Both go through a **dry run** first: the matched jobs are listed, with their
arguments and errors, and nothing is touched until you confirm. The count in the
toolbar tells you how many jobs match; only the dry run tells you which.

### Find more like this

Every row on **Retries**, **Dead** and **Scheduled** carries a 🔍 that narrows the
set to that job's class and, where the set records one, that job's error — the
same pair the Errors page treats as a single issue. One click turns "this one row
looks wrong" into "here are all 7,546 of them, and here are the bulk controls".

The filters it sets (`?class=` and `?error=`) are **exact**, not substring
searches. That matters because the button's whole purpose is to reveal
`Delete all matching`: a substring filter would also select jobs whose *arguments*
merely mention the class you clicked, and you would never see the difference.
Same reason `?tag=` and `?queue=` are structured rather than folded into the
search box.

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

Back up a queue before purging it, then restore if you were wrong. Both actions are
audit-logged.

Only a Redis store ships, and it is the default. A snapshot of a stuck queue then lives in
the Redis you are trying to relieve — and under `allkeys-lru` it is itself evictable, so a
large backup can disappear. Point `RoundhouseUi.snapshot_store` at your own store to put it
somewhere else; the contract is four methods:

```ruby
class S3SnapshotStore
  def write(id, blob) = # persist it
  def read(id)        = # → the blob, or nil
  def delete(id)      = # remove it
  def ids             = # → array of snapshot ids
end

RoundhouseUi.snapshot_store = S3SnapshotStore.new
```

Restore is not idempotent — restoring twice enqueues everything twice — and it issues one
push per job, so a very large snapshot is slow to put back.

## Recurring jobs

Periodic work, whichever scheduler defines it. Nothing to configure — Roundhouse
detects what is loaded:

| Source | Read via |
|---|---|
| [sidekiq-cron](https://github.com/sidekiq-cron/sidekiq-cron) | `Sidekiq::Cron::Job.all` |
| [sidekiq-scheduler](https://github.com/sidekiq-scheduler/sidekiq-scheduler) | `Sidekiq.schedule` |
| Sidekiq Enterprise periodic | `Sidekiq::Periodic::LoopSet` |
| Solid Queue | `SolidQueue::RecurringTask` |

More than one can be active at once — an app mid-migration genuinely runs two —
and all of them show. The nav item hides when none is present.

The useful part is not the crontab. It is **"this says hourly and has not run in
three days"**, which needs the schedule's interval, which needs a cron parser.
`fugit` ships with both sidekiq-cron and sidekiq-scheduler, so it is there
wherever this feature is; without it, staleness reads as unknown rather than
being guessed. A task is flagged overdue only after missing **two** intervals — a
job due at :00 that runs at :00:07 is not late, and a page that says otherwise
gets ignored.

**Read-only.** Schedules belong in the code that declares them, and a UI that
silently changes a production schedule is a different risk conversation.

## History

The Dashboard carries a **History** chart — daily processed counts and the daily
**failure rate**, over 1 week to 6 months.

This needs no configuration and stores nothing. Sidekiq already keeps a counter
per day; Roundhouse just reads it. The rate is the line worth watching: counts
move with traffic, so a busy Monday looks worse than a quiet Sunday even when
nothing changed.

A dashed baseline marks the **typical** failure rate — the median across days
that had traffic, so one incident cannot become the new normal and quiet
weekends cannot drag it to zero.

Sidekiq only. Solid Queue has no equivalent counter, so the section hides rather
than drawing an empty chart.

## Security

**Constant resolution from job payloads.** `Tags.from_constant` and
`Runbooks.from_constant` read a constant off the job class, which means turning
`item["class"]` — a string out of Redis — into a Class:

- Malformed names never reach a lookup. Ruby rejects `"../../etc/passwd"` as a
  constant path before attempting to resolve anything, so no autoload occurs.
- A **well-formed name of a class that really exists** does resolve, and
  resolving a class loads it. Production Rails sets `eager_load = true`, so every
  app constant is already loaded and no new file is executed.
- Writing a crafted payload requires Redis write access — which, on a Sidekiq
  install, already permits enqueuing a real job, a more serious compromise than
  this.

Two ways to tighten it if your payloads aren't fully trusted:

```ruby
# Bound which constants may be resolved at all
c.job_class_namespaces = %w[Workers Jobs Billing]

# Or resolve nothing: a Hash never constantizes
c.job_tags = ->(klass:, item:) { { squad: OWNER_MAP[klass] } }
c.job_runbooks = { "Billing::SyncWorker" => "https://wiki/billing" }
```


- All destructive actions are CSRF-protected `POST`s — never GET — and gated by `read_only`.
  The engine asks for forgery protection itself rather than relying on your
  `config.load_defaults`, so this holds on an app whose defaults predate Rails 5.2.
- Roundhouse sets its own strict, self-contained Content-Security-Policy on its responses
  (nonce'd inline script, same-origin only), so it's safe even if the host sets no policy.
- Configure `redact_args` to keep tokens and PII out of the UI, and set `actor_resolver` so
  the audit log records who did what. Redaction is key-based, so a secret nested under an
  unlisted key is not redacted — audit what your payloads actually carry.

## Keyboard

`⌘K` (or `Ctrl+K`) opens the command palette — jump to any view or action.

## Stability

Roundhouse follows [Semantic Versioning](https://semver.org). From 1.0 the surfaces
below are the ones you can build against; a breaking change to any of them needs a
major version, and anything scheduled for removal is deprecated for at least one
minor release first.

**Public — covered by semver:**

| Surface | Why it's here |
|---|---|
| Everything set in `RoundhouseUi.configure` | The whole configuration surface, documented above |
| `RoundhouseUi.cancelled?(jid)` | Your own jobs call it, so breaking it breaks your code |
| `RoundhouseUi::Fetch` | Named in your Sidekiq server config |
| `RoundhouseUi::CancelMiddleware`, `RoundhouseUi::DurationCollector` | Installed into your middleware chain |
| `Tags.from_constant`, `Runbooks.from_constant` | Documented resolver shorthands |
| The mounted paths (`/queues`, `/retries`, …) | People bookmark and link to them |
| Theme token names | You override them by name |
| The `roundhouse:*` Redis keys | Renaming one silently loses pause state or snapshots on upgrade |

**Not public — may change in any release:**

- **The backend port.** `RoundhouseUi::Backends::*`, `supports?`, and the shapes a
  "set" and an "entry" must answer to. Writing your own backend is possible today
  and genuinely useful, but the contract is still being worked out against
  [#17](https://github.com/rjrobinson/roundhouse_ui/issues/17) and
  [#41](https://github.com/rjrobinson/roundhouse_ui/issues/41) — pinning it now
  would freeze it before it is right. It will be promoted when those land.
- Anything under `lib/` not listed above: `Health`, `Metrics`, `ErrorGroups`,
  `History`, `QueueSummary`, and the internals of `Snapshots` and `Audit`.
- The rendered HTML and its `rh-` class names. Theme tokens are the supported way
  to change how Roundhouse looks; CSS written against our markup will break.
- The JSON from `/stats`. It exists for our own poller and is shaped for it.

If you depend on something in the second list, open an issue — that is how things
move to the first.

## Development

```bash
bin/rails test      # full suite, ~1s, no Redis required (Sidekiq's API is stubbed)
bundle exec rubocop # lint
```

Most of the suite runs against an in-memory stand-in for Redis, which is why it
finishes in about a second. The destructive paths — enforced pause, snapshot →
restore, and bulk-on-a-filter — also have tests that run against a **real** Redis,
because those features are made of Redis semantics and a fake can only confirm the
fake. They are opt-in and have no default target, since they `FLUSHDB` whatever they
are pointed at and your local Redis probably belongs to something else:

```bash
ROUNDHOUSE_TEST_REDIS_URL=redis://localhost:6379/10 bin/rails test
```

Pick an empty database. They refuse to run against database 0, and they verify which
database the connection is actually on before deleting anything. CI additionally sets
`ROUNDHOUSE_REQUIRE_REAL_REDIS=1`, which turns a skip into a failure — without it an
unreachable Redis would skip them silently and the coverage would be imaginary.

The dummy app under `test/dummy` mounts the engine at `/roundhouse`; point it at a local
Redis and run `bin/rails server` to click around.

## Seeing it work

The gem ships workers that do real work and really fail, so a console has
something to show. They are not loaded by `require "roundhouse_ui"` — ask for them
explicitly, in an initializer you would not ship:

```ruby
# config/initializers/roundhouse.rb
require "roundhouse_ui/demo" if Rails.env.development?
```

```bash
bin/rails roundhouse_ui:demo:load[15]   # enqueue for 15 minutes, hard cap 20
bin/rails roundhouse_ui:demo:clean      # remove everything it left behind
```

Six classes across six queues with different durations and failure rates — one
long enough to always be mid-flight on **Busy**, one flaky enough to dominate
**Errors** — so throughput moves, retries accumulate, and jobs reach the dead set
on their own. The rate rises and falls, so the dashboard's trend and drain
forecast have something to say.

Each worker refuses to run outside development, the task refuses any environment
but development, and it refuses Redis database 0 — checked by asking the
connection where it is, not by reading configuration.

## Roadmap

- Solid Queue: Workers view + enqueue, and the multi-DB (separate queue database) case.
- Watch Sidekiq **and** Solid Queue from one install ([#17](https://github.com/rjrobinson/roundhouse_ui/issues/17)).
- Multi-Redis / multi-cluster view (one pane across shards).
- Cron/periodic (recurring) views.

## Contributing

Bug reports and pull requests welcome at https://github.com/rjrobinson/roundhouse_ui.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
